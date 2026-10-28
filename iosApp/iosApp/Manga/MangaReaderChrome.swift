import UIKit
import shared

@MainActor
final class MangaReaderChrome: UIView {
    let topBar = UIView()
    let bottomBar = UIView()
    private let bookTitle = UILabel()
    private let chapterTitle = UILabel()
    private let pageLabel = UILabel()
    private let seek = UISlider()
    private let previous = UIButton(type: .system)
    private let contents = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private let download = UIButton(type: .system)
    private let settings = UIButton(type: .system)
    private let downloadToolTip = UIToolTipInteraction(defaultToolTip: "离线缓存")
    private let back = UIButton(type: .system)
    private let infoBar = MangaReaderInfoBar()
    private var canPrevious = false
    private var canNext = false
    private var imageCount = 0
    var onBack: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onContents: (() -> Void)?
    var menuProvider: (() async -> [UIMenuElement])?
    var onDownload: (() -> Void)?
    var onSettings: (() -> Void)?
    var onSeek: ((Int) -> Void)?

    var downloadAnchor: UIView { download }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        infoBar.alpha = 0
        addSubview(infoBar)
        NSLayoutConstraint.activate([
            infoBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for bar in [topBar, bottomBar] {
            bar.backgroundColor = UIColor(white: 0.07, alpha: 0.96)
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
        }
        bookTitle.font = .systemFont(ofSize: 16, weight: .medium)
        bookTitle.textColor = .white
        bookTitle.lineBreakMode = .byTruncatingMiddle
        chapterTitle.font = .systemFont(ofSize: 12)
        chapterTitle.textColor = .lightGray
        chapterTitle.lineBreakMode = .byTruncatingMiddle
        let titles = UIStackView(arrangedSubviews: [bookTitle, chapterTitle])
        titles.axis = .vertical
        titles.spacing = 3
        titles.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titles)
        configure(back, icon: "chevron.left", label: "返回", action: #selector(goBack))
        configure(more, icon: "ellipsis", label: "更多", action: nil)
        more.accessibilityIdentifier = "manga.reader.more"
        more.addInteraction(UIToolTipInteraction(defaultToolTip: "更多"))
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                Task { @MainActor in completion(await self?.menuProvider?() ?? []) }
            }
        ])
        configure(download, icon: "arrow.down.circle", label: "离线缓存", action: #selector(showDownloads))
        download.accessibilityIdentifier = "manga.reader.download"
        download.addInteraction(downloadToolTip)
        configure(settings, icon: "slider.horizontal.3", label: "漫画设置", action: #selector(showSettings))
        settings.accessibilityIdentifier = "manga.reader.settings"
        settings.addInteraction(UIToolTipInteraction(defaultToolTip: "漫画设置"))
        configure(previous, icon: "backward.end", label: "上一章", action: #selector(previousChapter))
        configure(contents, icon: "list.bullet", label: "目录", action: #selector(showContents))
        configure(nextButton, icon: "forward.end", label: "下一章", action: #selector(nextChapter))
        topBar.addSubview(back)
        topBar.addSubview(more)
        topBar.addSubview(download)
        topBar.addSubview(settings)
        back.widthAnchor.constraint(equalToConstant: 44).isActive = true
        more.widthAnchor.constraint(equalToConstant: 44).isActive = true
        download.widthAnchor.constraint(equalToConstant: 44).isActive = true
        settings.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let navigation = UIStackView(arrangedSubviews: [previous, contents, nextButton])
        navigation.distribution = .fillEqually
        navigation.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(navigation)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.textColor = .lightGray
        pageLabel.textAlignment = .right
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pageLabel.text = "0 / 0"
        seek.minimumTrackTintColor = .white
        seek.maximumTrackTintColor = .darkGray
        seek.thumbTintColor = .white
        seek.accessibilityLabel = "图片页码"
        seek.translatesAutoresizingMaskIntoConstraints = false
        seek.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        seek.addTarget(self, action: #selector(seekFinished), for: [.touchUpInside, .touchUpOutside])
        bottomBar.addSubview(seek)
        bottomBar.addSubview(pageLabel)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),
            back.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            back.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            settings.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            settings.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            more.trailingAnchor.constraint(equalTo: settings.leadingAnchor),
            more.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            download.trailingAnchor.constraint(equalTo: more.leadingAnchor),
            download.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titles.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 8),
            titles.trailingAnchor.constraint(equalTo: download.leadingAnchor, constant: -8),
            titles.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 100),
            seek.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 20),
            seek.trailingAnchor.constraint(equalTo: pageLabel.leadingAnchor, constant: -12),
            seek.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 4),
            seek.heightAnchor.constraint(equalToConstant: 40),
            pageLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -20),
            pageLabel.centerYAnchor.constraint(equalTo: seek.centerYAnchor),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            navigation.topAnchor.constraint(equalTo: seek.bottomAnchor),
            navigation.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            navigation.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            navigation.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -8),
        ])
        setNavigation(previous: false, next: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        [topBar, bottomBar].contains { !$0.isHidden && $0.alpha > 0.01 && $0.frame.contains(point) }
    }

    func setTitle(book: String, chapter: String) {
        bookTitle.text = book
        chapterTitle.text = chapter
        chapterTitle.accessibilityLabel = chapter
    }

    func setNavigation(previous: Bool, next: Bool) {
        canPrevious = previous
        canNext = next
        self.previous.isEnabled = previous
        nextButton.isEnabled = next
    }

    func setPage(_ position: Int, count: Int) {
        imageCount = count
        if !seek.isTracking {
            seek.minimumValue = 0
            seek.maximumValue = Float(max(1, count - 1))
            seek.value = Float(position)
        }
        seek.isEnabled = count > 1
        pageLabel.text = count > 0 ? "\(position + 1) / \(count)" : "0 / 0"
        seek.accessibilityValue = pageLabel.text
    }

    func setReadingInfo(_ chapter: MangaReaderChapter, position: Int, configuration: MangaFooterConfiguration) {
        infoBar.update(
            configuration: configuration, chapterName: chapter.chapterTitle,
            chapterIndex: Int(chapter.chapterIndex), chapterCount: chapter.chapters.count,
            pageIndex: position, imageCount: chapter.pages.count)
    }

    func setReaderVisible(_ visible: Bool) { infoBar.setReaderVisible(visible) }

    func setBusy(_ busy: Bool) {
        previous.isEnabled = !busy && canPrevious
        nextButton.isEnabled = !busy && canNext
        contents.isEnabled = !busy
        more.isEnabled = !busy
        download.isEnabled = !busy
        seek.isEnabled = !busy && imageCount > 1
    }

    func setDownloadStatus(_ status: MangaReaderDownloadCoordinator.Status?) {
        let icon =
            status?.failed == true
            ? "exclamationmark.circle" : (status?.isActive == true ? "arrow.down.circle.fill" : "arrow.down.circle")
        download.setImage(UIImage(systemName: icon), for: .normal)
        download.accessibilityValue = status?.message
        downloadToolTip.defaultToolTip = status?.message ?? "离线缓存"
    }

    func setControlsVisible(_ visible: Bool, animated: Bool) {
        let changes = {
            self.topBar.alpha = visible ? 1 : 0
            self.bottomBar.alpha = visible ? 1 : 0
            self.infoBar.alpha = visible ? 0 : 1
        }
        topBar.accessibilityElementsHidden = !visible
        bottomBar.accessibilityElementsHidden = !visible
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.18, animations: changes)
        } else {
            changes()
        }
    }

    private func configure(_ button: UIButton, icon: String, label: String, action: Selector?) {
        button.setImage(UIImage(systemName: icon), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
    }

    @objc private func goBack() { onBack?() }
    @objc private func previousChapter() { onPrevious?() }
    @objc private func nextChapter() { onNext?() }
    @objc private func showContents() { onContents?() }
    @objc private func showDownloads() { onDownload?() }
    @objc private func showSettings() { onSettings?() }
    @objc private func seekChanged() {
        let position = Int(seek.value.rounded())
        pageLabel.text = "\(position + 1) / \(imageCount)"
        if !seek.isTracking { onSeek?(position) }
    }
    @objc private func seekFinished() { onSeek?(Int(seek.value.rounded())) }
}
