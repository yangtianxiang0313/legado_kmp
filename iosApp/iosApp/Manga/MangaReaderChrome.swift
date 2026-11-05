import UIKit
import shared

@MainActor
final class MangaReaderChrome: UIView {
    let topBar = UIView()
    let bottomBar = UIView()
    private let bookTitle = UIButton(type: .system)
    private let back = UIButton(type: .system)
    private let changeSource = UIButton(type: .system)
    private let refresh = UIButton(type: .system)
    private let contents = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private let moreContainer = UIView()
    private let previous = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let seek = MangaReaderChromeSlider()
    private let seekFeedback = UILabel()
    private let outside = UIControl()
    private let infoBar = MangaReaderInfoBar()
    private let moreToolTip = UIToolTipInteraction(
        defaultToolTip: L10n.text("manga.ui.chrome.more", "更多"))
    private var canPrevious = false
    private var canNext = false
    private var isBusy = false
    private var controlsVisible = false
    private var readerVisible = false
    private var visibilityGeneration: UInt64 = 0
    private var contextGeneration: UInt64 = 0
    private var chapterTitle = ""
    private var chapterIdentity: ChapterIdentity?

    private struct ChapterIdentity: Equatable {
        let bookURL: String
        let origin: String
        let chapterIndex: Int
        let chapterURL: String

        init(_ chapter: MangaReaderChapter) {
            bookURL = chapter.book.bookUrl
            origin = chapter.book.origin
            chapterIndex = Int(chapter.chapterIndex)
            chapterURL = chapter.chapters.indices.contains(chapterIndex) ? chapter.chapters[chapterIndex].url : ""
        }
    }

    var onBack: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onContents: (() -> Void)?
    var onChangeSource: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onBookInfo: (() -> Void)?
    var onDismiss: (() -> Void)?
    var menuProvider: (() async -> [UIMenuElement])?
    // Overflow commands remain owned by the reader's menu provider.
    var onDownload: (() -> Void)?
    var onSettings: (() -> Void)?
    var onSeek: ((Int) -> Void)?

    var downloadAnchor: UIView { more }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        addSubview(infoBar)
        outside.translatesAutoresizingMaskIntoConstraints = false
        outside.isAccessibilityElement = true
        outside.accessibilityTraits = .button
        outside.accessibilityIdentifier = "mangaReader.dismiss"
        outside.accessibilityLabel = L10n.text("reader.menu_dismiss", "关闭菜单")
        outside.addTarget(self, action: #selector(dismissControls), for: .touchUpInside)
        addSubview(outside)
        for bar in [topBar, bottomBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
        }
        configureTopBar()
        configureBottomBar()
        configureFeedback()
        NSLayoutConstraint.activate([
            infoBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            outside.leadingAnchor.constraint(equalTo: leadingAnchor),
            outside.trailingAnchor.constraint(equalTo: trailingAnchor),
            outside.topAnchor.constraint(equalTo: topAnchor),
            outside.bottomAnchor.constraint(equalTo: bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 64),
        ])
        synchronizeInteraction()
        finishVisibility()
        applyAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHidden: Bool {
        didSet { synchronizeInteraction() }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { synchronizeInteraction() }
    }

    override var alpha: CGFloat {
        didSet { synchronizeInteraction() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { seek.cancelTracking(with: nil) }
        super.willMove(toWindow: newWindow)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        acceptsTouches && bounds.contains(point)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard acceptsTouches, !seek.hasActiveTracking else { return false }
        dismissControls()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !seekFeedback.isHidden else { return }
        let size = seekFeedback.sizeThatFits(CGSize(width: bounds.width, height: 28))
        let width = min(max(size.width + 16, 56), max(bounds.width - 16, 0))
        let track = seek.trackRect(forBounds: seek.bounds)
        let thumb = seek.thumbRect(forBounds: seek.bounds, trackRect: track, value: seek.value)
        let center = seek.convert(CGPoint(x: thumb.midX, y: thumb.midY), to: self)
        let x = min(max(center.x - width / 2, 8), max(8, bounds.width - width - 8))
        seekFeedback.frame = CGRect(x: x, y: bottomBar.frame.minY - 34, width: width, height: 28)
    }

    func setTitle(book: String, chapter: String) {
        if bookTitle.accessibilityLabel != book || chapterTitle != chapter {
            invalidateChapterInteraction()
        }
        let displayTitle = book.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        bookTitle.setTitle(displayTitle, for: .normal)
        bookTitle.accessibilityLabel = book
        chapterTitle = chapter
    }

    func setChapter(_ chapter: MangaReaderChapter) {
        updateChapterIdentity(chapter)
        setTitle(book: chapter.book.name, chapter: chapter.chapterTitle)
        setNavigation(previous: chapter.chapterIndex > 0, next: Int(chapter.chapterIndex) + 1 < chapter.chapters.count)
        setPage(Int(chapter.chapterPosition), count: chapter.pages.count)
    }

    func setNavigation(previous: Bool, next: Bool) {
        canPrevious = previous
        canNext = next
        synchronizeInteraction()
    }

    func setPage(_ position: Int, count: Int) {
        let boundedCount = max(0, count)
        if boundedCount != seek.pageCount { contextGeneration &+= 1 }
        seek.update(position: position, count: boundedCount)
        synchronizeInteraction()
    }

    func setReadingInfo(_ chapter: MangaReaderChapter, position: Int, configuration: MangaFooterConfiguration) {
        updateChapterIdentity(chapter)
        infoBar.update(
            configuration: configuration, chapterName: chapter.chapterTitle,
            chapterIndex: Int(chapter.chapterIndex), chapterCount: chapter.chapters.count,
            pageIndex: position, imageCount: chapter.pages.count)
    }

    func setReaderVisible(_ visible: Bool) {
        readerVisible = visible
        synchronizeInteraction()
    }

    func setBusy(_ busy: Bool) {
        if isBusy != busy { contextGeneration &+= 1 }
        isBusy = busy
        synchronizeInteraction()
    }

    func setDownloadStatus(_ status: MangaReaderDownloadCoordinator.Status?) {
        more.accessibilityValue = status?.message
        moreToolTip.defaultToolTip = [
            L10n.text("manga.ui.chrome.more", "更多"), status?.message,
        ].compactMap { $0 }.joined(separator: "\n")
    }

    func setControlsVisible(_ visible: Bool, animated: Bool) {
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        controlsVisible = visible
        if visible {
            topBar.isHidden = false
            bottomBar.isHidden = false
        }
        synchronizeInteraction()
        let changes = {
            self.topBar.alpha = visible ? 1 : 0
            self.bottomBar.alpha = visible ? 1 : 0
            self.infoBar.alpha = visible ? 0 : 1
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.18, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: changes
            ) { [weak self] _ in
                guard let self, self.visibilityGeneration == generation else { return }
                self.finishVisibility()
            }
        } else {
            for view in [topBar, bottomBar, infoBar] { view.layer.removeAllAnimations() }
            changes()
            finishVisibility()
        }
    }

    private var acceptsTouches: Bool {
        controlsVisible && !isHidden && alpha > 0.01 && isUserInteractionEnabled
    }

    private func synchronizeInteraction() {
        let interactive = acceptsTouches
        for bar in [topBar, bottomBar] {
            bar.isUserInteractionEnabled = interactive
            bar.accessibilityElementsHidden = !interactive
        }
        outside.isHidden = !interactive
        outside.accessibilityElementsHidden = !interactive
        accessibilityViewIsModal = interactive
        previous.isEnabled = !isBusy && canPrevious
        nextButton.isEnabled = !isBusy && canNext
        for button in [bookTitle, changeSource, refresh, contents, more] { button.isEnabled = !isBusy }
        seek.setAvailable(interactive && readerVisible && !isBusy)
        infoBar.setReaderVisible(readerVisible && !controlsVisible && !isHidden && alpha > 0.01)
    }

    private func finishVisibility() {
        topBar.isHidden = !controlsVisible
        bottomBar.isHidden = !controlsVisible
        topBar.alpha = controlsVisible ? 1 : 0
        bottomBar.alpha = controlsVisible ? 1 : 0
        infoBar.alpha = controlsVisible ? 0 : 1
    }

    private func updateChapterIdentity(_ chapter: MangaReaderChapter) {
        let identity = ChapterIdentity(chapter)
        guard chapterIdentity != identity else { return }
        chapterIdentity = identity
        invalidateChapterInteraction()
    }

    private func invalidateChapterInteraction() {
        contextGeneration &+= 1
        seek.cancelTracking(with: nil)
    }

    private func configureTopBar() {
        configure(back, icon: .back, label: L10n.text("manga.ui.chrome.back", "返回"), id: "back", action: #selector(goBack))
        configure(
            changeSource, icon: .changeSource, label: L10n.Reader.changeSource,
            id: "changeSource", action: #selector(showChangeSource))
        configure(refresh, icon: .refresh, label: L10n.Reader.menuRefresh, id: "refresh", action: #selector(refreshChapter))
        configure(
            contents, icon: .toc, label: L10n.text("manga.ui.contents.title", "目录"),
            id: "contents", action: #selector(showContents))
        configure(more, icon: .more, label: L10n.text("manga.ui.chrome.more", "更多"), id: "more", action: nil)
        // Keep the existing button identifier; its slot also exposes the new stable identifier.
        more.accessibilityIdentifier = "manga.reader.more"
        moreContainer.accessibilityIdentifier = "mangaReader.more"
        moreContainer.translatesAutoresizingMaskIntoConstraints = false
        moreContainer.addSubview(more)
        more.addInteraction(moreToolTip)
        more.addTarget(self, action: #selector(prepareMore), for: .touchDown)
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                Task { @MainActor in
                    guard let self, self.acceptsTouches, !self.isBusy else {
                        completion([])
                        return
                    }
                    self.seek.cancelTracking(with: nil)
                    let visibility = self.visibilityGeneration
                    let context = self.contextGeneration
                    let elements = await self.menuProvider?() ?? []
                    guard self.acceptsTouches, !self.isBusy,
                        visibility == self.visibilityGeneration, context == self.contextGeneration
                    else {
                        completion([])
                        return
                    }
                    completion(elements)
                }
            }
        ])
        bookTitle.translatesAutoresizingMaskIntoConstraints = false
        bookTitle.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        bookTitle.titleLabel?.numberOfLines = 1
        bookTitle.titleLabel?.lineBreakMode = .byTruncatingTail
        bookTitle.contentHorizontalAlignment = .leading
        bookTitle.accessibilityIdentifier = "mangaReader.title"
        bookTitle.accessibilityHint = L10n.Bookshelf.openInfoByTitle
        bookTitle.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.BookDetail.title))
        bookTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bookTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bookTitle.addTarget(self, action: #selector(showBookInfo), for: .touchUpInside)
        for view in [back, bookTitle, changeSource, refresh, contents, moreContainer] { topBar.addSubview(view) }
        for view in [back, changeSource, refresh, contents, moreContainer] {
            view.widthAnchor.constraint(equalToConstant: 44).isActive = true
            view.heightAnchor.constraint(equalToConstant: 44).isActive = true
            view.centerYAnchor.constraint(equalTo: topBar.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            bookTitle.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 4),
            bookTitle.trailingAnchor.constraint(equalTo: changeSource.leadingAnchor, constant: -4),
            bookTitle.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            bookTitle.heightAnchor.constraint(equalToConstant: 44),
            bookTitle.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refresh.leadingAnchor.constraint(equalTo: changeSource.trailingAnchor),
            contents.leadingAnchor.constraint(equalTo: refresh.trailingAnchor),
            moreContainer.leadingAnchor.constraint(equalTo: contents.trailingAnchor),
            moreContainer.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            more.leadingAnchor.constraint(equalTo: moreContainer.leadingAnchor),
            more.trailingAnchor.constraint(equalTo: moreContainer.trailingAnchor),
            more.topAnchor.constraint(equalTo: moreContainer.topAnchor),
            more.bottomAnchor.constraint(equalTo: moreContainer.bottomAnchor),
        ])
    }

    private func configureBottomBar() {
        for (button, label, identifier, action) in [
            (previous, L10n.text("manga.ui.chrome.previous_chapter", "上一章"), "previous", #selector(previousChapter)),
            (nextButton, L10n.text("manga.ui.chrome.next_chapter", "下一章"), "next", #selector(nextChapter)),
        ] {
            button.setTitle(label, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "mangaReader.\(identifier)"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addTarget(self, action: action, for: .touchUpInside)
            bottomBar.addSubview(button)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.widthAnchor.constraint(lessThanOrEqualTo: bottomBar.widthAnchor, multiplier: 0.3).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor).isActive = true
        }
        seek.translatesAutoresizingMaskIntoConstraints = false
        seek.accessibilityIdentifier = "mangaReader.seek"
        seek.accessibilityLabel = L10n.text("manga.ui.chrome.image_page_number", "图片页码")
        seek.onSeek = { [weak self] position in self?.onSeek?(position) }
        seek.onFeedback = { [weak self] page, count in
            self?.seekFeedback.text = "\(count > 0 ? page + 1 : 0) / \(count)"
            self?.setNeedsLayout()
        }
        seek.onTrackingChange = { [weak self] tracking in
            guard let self else { return }
            self.outside.isEnabled = !tracking
            self.seekFeedback.isHidden = !tracking || !self.acceptsTouches
            self.setNeedsLayout()
        }
        bottomBar.addSubview(seek)
        NSLayoutConstraint.activate([
            previous.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            seek.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 8),
            seek.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            seek.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            seek.heightAnchor.constraint(equalToConstant: 44),
            nextButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
        ])
    }

    private func configureFeedback() {
        seekFeedback.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        seekFeedback.textAlignment = .center
        seekFeedback.layer.cornerRadius = 4
        seekFeedback.clipsToBounds = true
        seekFeedback.isUserInteractionEnabled = false
        seekFeedback.isAccessibilityElement = false
        seekFeedback.isHidden = true
        addSubview(seekFeedback)
    }

    private func configure(_ button: UIButton, icon: ReaderMenuAndroidIcon, label: String, id: String, action: Selector?) {
        button.setImage(icon.image(), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "mangaReader.\(id)"
        button.translatesAutoresizingMaskIntoConstraints = false
        if button !== more { button.addInteraction(UIToolTipInteraction(defaultToolTip: label)) }
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
    }

    @objc private func applyAppearance() {
        let palette = AndroidReplicaThemePalette.shared
        let top =
            palette.color(for: "primaryColor", traits: traitCollection, followsTraits: true)
            ?? AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        let bottom =
            palette.color(for: "bottomBackground", traits: traitCollection, followsTraits: true)
            ?? AndroidReplicaTheme.bottomBackground.resolvedColor(with: traitCollection)
        let accent =
            palette.color(for: "accentColor", traits: traitCollection, followsTraits: true)
            ?? AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        let titleColor = ReaderPaletteColor.primaryText(on: top)
        let bodyColor = ReaderPaletteColor.primaryText(on: bottom)
        topBar.backgroundColor = top.withAlphaComponent(1)
        bottomBar.backgroundColor = bottom.withAlphaComponent(1)
        bookTitle.setTitleColor(titleColor, for: .normal)
        bookTitle.setTitleColor(titleColor.withAlphaComponent(0.38), for: .disabled)
        for button in [back, changeSource, refresh, contents, more] { button.tintColor = titleColor }
        for button in [previous, nextButton] {
            button.setTitleColor(bodyColor, for: .normal)
            button.setTitleColor(bodyColor.withAlphaComponent(0.38), for: .disabled)
        }
        seek.minimumTrackTintColor = accent
        seek.maximumTrackTintColor = bodyColor.withAlphaComponent(0.26)
        seek.thumbTintColor = accent
        seekFeedback.backgroundColor = bottom.withAlphaComponent(1)
        seekFeedback.textColor = bodyColor
    }

    @objc private func goBack() {
        guard acceptsTouches else { return }
        seek.cancelTracking(with: nil)
        onBack?()
    }

    @objc private func previousChapter() {
        guard acceptsTouches, previous.isEnabled else { return }
        invalidateChapterInteraction()
        onPrevious?()
    }

    @objc private func nextChapter() {
        guard acceptsTouches, nextButton.isEnabled else { return }
        invalidateChapterInteraction()
        onNext?()
    }

    @objc private func showContents() {
        guard acceptsTouches, !isBusy else { return }
        seek.cancelTracking(with: nil)
        onContents?()
    }

    @objc private func showChangeSource() {
        guard acceptsTouches, !isBusy else { return }
        invalidateChapterInteraction()
        onChangeSource?()
    }

    @objc private func refreshChapter() {
        guard acceptsTouches, !isBusy else { return }
        invalidateChapterInteraction()
        onRefresh?()
    }

    @objc private func showBookInfo() {
        guard acceptsTouches, !isBusy else { return }
        seek.cancelTracking(with: nil)
        onBookInfo?()
    }

    @objc private func prepareMore() { seek.cancelTracking(with: nil) }

    @objc private func dismissControls() {
        guard acceptsTouches, !seek.hasActiveTracking else { return }
        setControlsVisible(false, animated: true)
        onDismiss?()
    }
}

@MainActor
private final class MangaReaderChromeSlider: UISlider {
    var onSeek: ((Int) -> Void)?
    var onFeedback: ((Int, Int) -> Void)?
    var onTrackingChange: ((Bool) -> Void)?
    private(set) var pageCount = 0
    private var position = 0
    private var available = false
    private var generation: UInt64 = 0
    private var dragGeneration: UInt64?
    private var lastSentPosition = 0
    private var cancelling = false

    var hasActiveTracking: Bool { dragGeneration != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isContinuous = true
        isEnabled = false
        addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspendTracking), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled, oldValue { cancelTracking(with: nil) }
        }
    }

    func update(position: Int, count: Int) {
        let changedCount = pageCount != count
        pageCount = max(0, count)
        self.position = bounded(position)
        if changedCount {
            cancelTracking(with: nil)
        } else if !hasActiveTracking {
            restorePosition()
        } else {
            updateFeedback()
        }
        isEnabled = available && pageCount > 1
    }

    func setAvailable(_ available: Bool) {
        self.available = available
        if !available { cancelTracking(with: nil) }
        isEnabled = available && pageCount > 1
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard available, isEnabled, !hasActiveTracking else { return false }
        generation &+= 1
        let token = generation
        dragGeneration = token
        lastSentPosition = position
        onTrackingChange?(true)
        guard dragGeneration == token else { return false }
        let began = super.beginTracking(touch, with: event)
        guard began, dragGeneration == token, available, isEnabled else {
            cancelTracking(with: event)
            return false
        }
        emitChangedPosition()
        return dragGeneration == token
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let token = dragGeneration, available, isEnabled else { return false }
        let continues = super.continueTracking(touch, with: event)
        guard dragGeneration == token else { return false }
        guard continues, available, isEnabled else {
            cancelTracking(with: event)
            return false
        }
        emitChangedPosition()
        return dragGeneration == token
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard touch != nil, let token = dragGeneration, available, isEnabled else {
            cancelTracking(with: event)
            return
        }
        super.endTracking(touch, with: event)
        guard dragGeneration == token else { return }
        // Flush the final native value once, without seeking the same page again on release.
        emitChangedPosition()
        guard dragGeneration == token else { return }
        dragGeneration = nil
        restorePosition()
        onTrackingChange?(false)
    }

    override func cancelTracking(with event: UIEvent?) {
        let wasTracking = hasActiveTracking
        generation &+= 1
        dragGeneration = nil
        if !cancelling {
            cancelling = true
            super.cancelTracking(with: event)
            cancelling = false
        }
        restorePosition()
        if wasTracking { onTrackingChange?(false) }
    }

    override func accessibilityIncrement() { adjustAccessibility(by: 1) }
    override func accessibilityDecrement() { adjustAccessibility(by: -1) }

    private func adjustAccessibility(by offset: Int) {
        guard available, isEnabled, !hasActiveTracking else { return }
        let next = bounded(position + offset)
        guard next != position else { return }
        position = next
        restorePosition()
        onSeek?(next)
    }

    private func bounded(_ index: Int) -> Int {
        min(max(0, index), max(0, pageCount - 1))
    }

    private var draftPosition: Int {
        guard value.isFinite else { return position }
        let rounded = min(max(value, 0), Float(max(0, pageCount - 1))).rounded()
        return bounded(Int(exactly: rounded) ?? max(0, pageCount - 1))
    }

    private func emitChangedPosition() {
        guard hasActiveTracking, available, isEnabled else { return }
        let next = draftPosition
        updateFeedback()
        guard next != lastSentPosition else { return }
        lastSentPosition = next
        position = next
        onSeek?(next)
    }

    private func restorePosition() {
        minimumValue = 0
        maximumValue = Float(max(1, pageCount - 1))
        setValue(Float(position), animated: false)
        updateFeedback()
    }

    private func updateFeedback() {
        let page = hasActiveTracking ? draftPosition : position
        accessibilityValue = L10n.format(
            "manga.ui.footer.page_number_accessibility", "本章图片，第 %1$ld 张，共 %2$ld 张",
            pageCount > 0 ? page + 1 : 0, pageCount)
        onFeedback?(page, pageCount)
    }

    @objc private func valueChanged() {
        if hasActiveTracking {
            emitChangedPosition()
        } else {
            restorePosition()
        }
    }

    @objc private func suspendTracking() { cancelTracking(with: nil) }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        cancelTracking(with: nil)
    }
}
