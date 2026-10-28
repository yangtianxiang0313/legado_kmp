import UIKit
import shared

final class ChangeSourcePanelView: UIView {
    let tableView = UITableView(frame: .zero, style: .plain)
    let searchField: UITextField
    let moreButton: UIButton
    let currentSourceButton = UIButton(type: .custom)
    let emptyLabel = AndroidExploreTextLabel()
    var onBack: (() -> Void)?
    var onFilter: (() -> Void)?
    var onCollapseFilter: (() -> Void)?
    var onSearchToggle: (() -> Void)?
    var onMore: (() -> Void)?
    var onLocateCurrent: (() -> Void)?
    var onTop: (() -> Void)?
    var onBottom: (() -> Void)?
    var onFastScrollingChange: ((Bool) -> Void)?
    var onPaletteChange: (() -> Void)?

    private lazy var fastScroller = ReaderListFastScroller(tableView: tableView)
    private let toolbarBackground = UIView()
    private let toolbar: ChangeSourceToolbarView
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let loadingIndicator = UIView()
    private let bottomBackground = UIView()
    private let bottomBar = UIView()
    private let summaryLabel = ReaderTocSingleLineLabel()
    private let topButton = UIButton(type: .custom)
    private let bottomButton = UIButton(type: .custom)
    private var isSearching = false
    private var isChapterMode = false
    private var isChapterTocVisible = false
    private var isEmptyStateVisible = true
    private var isInWindow = false
    private var fastScrollInteractionEnabled = true
    private var currentSourceName = ""
    private var palette: ChangeSourcePalette { ChangeSourcePalette(traits: traitCollection) }

    override init(frame: CGRect) {
        let toolbar = ChangeSourceToolbarView()
        self.toolbar = toolbar
        searchField = toolbar.searchField
        moreButton = toolbar.moreButton
        super.init(frame: frame)
        configureToolbar()
        configureBottomBar()
        configureLayout()
        updateFonts()
        applyPalette()
        updateFastScrollAvailability()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteChanged), name: .androidReplicaThemeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(book: Book?, title: String, sourceName: String) {
        isChapterMode = false
        toolbar.configure(title: book?.name.nilIfEmpty ?? title, author: book?.author.nilIfEmpty)
        summaryLabel.lineBreakMode = .byTruncatingTail
        currentSourceName = sourceName
        currentSourceButton.accessibilityLabel = "当前书源：\(sourceName)"
        currentSourceButton.accessibilityHint = "定位当前书源"
        updateFonts()
        setSummary(sourceName)
    }

    func configureChapter(title: String, sourceName: String) {
        configure(book: nil, title: title, sourceName: sourceName)
        isChapterMode = true
        // Android relies on system Back here; iOS needs a visible dismiss control.
        summaryLabel.lineBreakMode = .byTruncatingMiddle
    }

    func installChapterToc(_ toc: UIView) {
        toc.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(toc, belowSubview: toolbarBackground)
        NSLayoutConstraint.activate([
            toc.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toc.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            toc.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            toc.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
    }

    func setChapterTocVisible(_ visible: Bool) {
        guard isChapterTocVisible != visible else { return }
        if visible { isEmptyStateVisible = !emptyLabel.isHidden }
        isChapterTocVisible = visible
        for view in [tableView, bottomBar, bottomBackground] {
            view.isHidden = visible
            view.isUserInteractionEnabled = !visible
            view.accessibilityElementsHidden = visible
        }
        updateEmptyStateVisibility()
        updateFastScrollAvailability()
        updateProgressAppearance()
    }

    /// Streaming updates retain the latest empty state without uncovering the chapter TOC.
    func setEmptyStateVisible(_ visible: Bool) {
        isEmptyStateVisible = visible
        updateEmptyStateVisibility()
    }

    func reloadFastScroller() {
        updateFastScrollAvailability()
        fastScroller.reload()
    }

    /// Independent of toolbar locks, which may remain disabled during a thumb drag.
    func setFastScrollInteractionEnabled(_ enabled: Bool) {
        fastScrollInteractionEnabled = enabled
        updateFastScrollAvailability()
    }

    func setSummary(_ text: String) {
        let changed = summaryLabel.text != text
        summaryLabel.attributedText = NSAttributedString(string: text, attributes: [.kern: 0])
        currentSourceButton.accessibilityValue = text
        if changed, !isSearching, !isChapterTocVisible, !isHidden, window != nil,
            text != currentSourceName, UIAccessibility.isVoiceOverRunning
        {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    func setSearching(_ searching: Bool) {
        isSearching = searching
        progressView.progress = 0
        progressView.accessibilityValue = searching ? "正在搜索" : nil
        toolbar.setSearching(searching)
        updateProgressAppearance()
    }

    func setProgress(_ progress: SourceChangeSearchProgress, resultCount: Int) {
        let total = max(Int(progress.total), 0)
        let searched = max(Int(progress.searched), 0)
        progressView.setProgress(
            total > 0 ? min(1, Float(searched) / Float(total)) : 0,
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        progressView.accessibilityValue = "已搜索 \(searched) / \(total)，结果 \(resultCount)"
        // Only ChangeBookSourceDialog collects changeSourceProgress into tv_dur.
        if !isChapterMode {
            setSummary("结果 \(resultCount), 当前进度 \(searched) / \(total): \(progress.currentSourceName)")
        }
        updateProgressAppearance()
    }

    func setFilterExpanded(_ expanded: Bool) {
        toolbar.setFilterExpanded(expanded)
    }

    func setFilterHasQuery(_ hasQuery: Bool) {
        toolbar.setFilterHasQuery(hasQuery)
    }

    func setActionsEnabled(_ enabled: Bool) {
        toolbar.setActionsEnabled(enabled)
    }

    override var isHidden: Bool {
        didSet {
            updateFastScrollAvailability()
            updateProgressAppearance()
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { updateFastScrollAvailability() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            isInWindow = false
            updateFastScrollAvailability()
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isInWindow = window != nil
        updateFastScrollAvailability()
        updateProgressAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ChangeSourceElevation.updatePath(for: toolbarBackground)
        updateFastScrollAvailability()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        applyPalette()
    }

    @objc private func themePaletteChanged() {
        applyPalette()
        toolbar.applyPalette()
        onPaletteChange?()
    }

    private func configureToolbar() {
        ChangeSourceElevation.apply(to: toolbarBackground)
        toolbar.onBack = { [weak self] in self?.onBack?() }
        toolbar.onFilter = { [weak self] in self?.onFilter?() }
        toolbar.onSearchToggle = { [weak self] in self?.onSearchToggle?() }
        toolbar.onMore = { [weak self] in self?.onMore?() }
        toolbar.onCollapseFilter = { [weak self] in
            guard let self else { return }
            if let onCollapseFilter = self.onCollapseFilter {
                onCollapseFilter()
            } else if let onFilter = self.onFilter {
                // Older owners clear a nonempty query before they collapse onFilter.
                self.searchField.text = nil
                self.searchField.sendActions(for: .editingChanged)
                onFilter()
            } else {
                self.setFilterExpanded(false)
            }
        }
    }

    private func configureBottomBar() {
        summaryLabel.numberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isAccessibilityElement = false
        summaryLabel.accessibilityIdentifier = "changeSource.progressLabel"
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        currentSourceButton.addSubview(summaryLabel)
        configureTransparentButton(currentSourceButton)
        currentSourceButton.isAccessibilityElement = true
        currentSourceButton.accessibilityIdentifier = "changeSource.currentSource"
        currentSourceButton.addInteraction(UIToolTipInteraction(defaultToolTip: "定位当前书源"))
        currentSourceButton.addAction(
            UIAction { [weak self] _ in
                guard let self, !self.isChapterTocVisible else { return }
                self.onLocateCurrent?()
            }, for: .touchUpInside)
        configureButton(
            topButton, title: L10n.Reader.scrollToTop, image: ReaderTocAndroidIcon.top.image(),
            identifier: "changeSource.scrollTop"
        ) { [weak self] in
            self?.onTop?()
        }
        configureButton(
            bottomButton, title: L10n.Reader.scrollToBottom, image: ReaderTocAndroidIcon.bottom.image(),
            identifier: "changeSource.scrollBottom"
        ) {
            [weak self] in self?.onBottom?()
        }
        for child in [currentSourceButton, topButton, bottomButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(child)
        }
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: currentSourceButton.leadingAnchor, constant: 10),
            summaryLabel.trailingAnchor.constraint(equalTo: currentSourceButton.trailingAnchor, constant: -10),
            summaryLabel.centerYAnchor.constraint(equalTo: currentSourceButton.centerYAnchor),
            summaryLabel.topAnchor.constraint(greaterThanOrEqualTo: currentSourceButton.topAnchor),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: currentSourceButton.bottomAnchor),
            currentSourceButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 10),
            currentSourceButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            currentSourceButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            currentSourceButton.trailingAnchor.constraint(equalTo: topButton.leadingAnchor),
            topButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            topButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            topButton.widthAnchor.constraint(equalToConstant: 36),
            topButton.trailingAnchor.constraint(equalTo: bottomButton.leadingAnchor),
            bottomButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            bottomButton.widthAnchor.constraint(equalToConstant: 36),
            bottomButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -10),
        ])
    }

    private func configureLayout() {
        for child in [
            toolbarBackground, toolbar, progressView, loadingIndicator, tableView, emptyLabel, bottomBackground,
            bottomBar, fastScroller,
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        // Keep elevation above page content without outranking later popup overlays.
        bringSubviewToFront(toolbarBackground)
        bringSubviewToFront(toolbar)
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.keyboardDismissMode = .onDrag
        tableView.showsVerticalScrollIndicator = false
        tableView.accessibilityIdentifier = "changeSource.table"
        fastScroller.accessibilityIdentifier = "changeSource.fastScroll"
        fastScroller.onScrubbingChanged = { [weak self] in self?.onFastScrollingChange?($0) }
        progressView.isHidden = true
        progressView.isAccessibilityElement = true
        progressView.accessibilityLabel = "书源搜索进度"
        progressView.accessibilityTraits = .updatesFrequently
        loadingIndicator.isHidden = true
        loadingIndicator.isUserInteractionEnabled = false
        loadingIndicator.isAccessibilityElement = true
        loadingIndicator.accessibilityLabel = "正在搜索书源"
        loadingIndicator.accessibilityTraits = .updatesFrequently
        keyboardLayoutGuide.followsUndockedKeyboard = false
        emptyLabel.attributedText = NSAttributedString(
            string: L10n.BookDetail.changeSourceEmpty, attributes: [.kern: 0])
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.isUserInteractionEnabled = false
        emptyLabel.accessibilityIdentifier = "changeSource.empty"
        let fastScrollerBottom = fastScroller.bottomAnchor.constraint(
            equalTo: tableView.bottomAnchor, constant: -8)
        // A nearly covered keyboard viewport must not force the full-width table taller.
        fastScrollerBottom.priority = .defaultHigh
        // Preserve the 36dp row until the summary's complete includeFontPadding box needs more room.
        let bottomBarPreferredHeight = bottomBar.heightAnchor.constraint(equalToConstant: 36)
        bottomBarPreferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            toolbarBackground.topAnchor.constraint(equalTo: topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
            loadingIndicator.topAnchor.constraint(equalTo: progressView.topAnchor),
            loadingIndicator.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            loadingIndicator.trailingAnchor.constraint(equalTo: progressView.trailingAnchor),
            loadingIndicator.heightAnchor.constraint(equalTo: progressView.heightAnchor),
            tableView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: ReaderListFastScrollerGeometry.columnWidth),
            fastScroller.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            fastScroller.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 8),
            fastScroller.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            fastScrollerBottom,
            bottomBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            bottomBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            bottomBarPreferredHeight,
            bottomBar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            bottomBackground.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableView.trailingAnchor, constant: -24),
        ])
    }

    private func configureButton(
        _ button: UIButton, title: String, image: UIImage?, identifier: String, handler: @escaping () -> Void
    ) {
        configureTransparentButton(button)
        button.setImage(image, for: .normal)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        button.addAction(
            UIAction { [weak self] _ in
                guard let self, !self.isChapterTocVisible else { return }
                handler()
            }, for: .touchUpInside)
    }

    private func configureTransparentButton(_ button: UIButton) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.imageView?.contentMode = .center
        button.accessibilityTraits = .button
    }

    private func updateFonts() {
        let summarySize = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 12, compatibleWith: traitCollection)
        summaryLabel.font = ReaderAndroidDefaultFont.font(size: summarySize) ?? .systemFont(ofSize: summarySize)
        emptyLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
    }

    private func updateProgressAppearance() {
        // ChangeBookSourceDialog keeps RefreshProgressBar.isAutoLoading true for the whole search.
        progressView.isHidden = true
        loadingIndicator.isHidden = !isSearching || isChapterTocVisible || isHidden
        loadingIndicator.accessibilityValue = progressView.accessibilityValue
        guard !loadingIndicator.isHidden, window != nil else {
            loadingIndicator.layer.removeAnimation(forKey: "changeSource.loading")
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            loadingIndicator.layer.removeAnimation(forKey: "changeSource.loading")
            loadingIndicator.transform = CGAffineTransform(scaleX: 0.35, y: 1)
            return
        }
        loadingIndicator.transform = .identity
        guard loadingIndicator.layer.animation(forKey: "changeSource.loading") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 50.0 / 60.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        loadingIndicator.layer.add(animation, forKey: "changeSource.loading")
    }

    private func updateFastScrollAvailability() {
        fastScroller.isHidden = isChapterTocVisible
        fastScroller.accessibilityElementsHidden = isChapterTocVisible
        fastScroller.isEnabled =
            fastScrollInteractionEnabled && isInWindow && !isHidden && isUserInteractionEnabled
            && !isChapterTocVisible && !tableView.isHidden
            && fastScroller.bounds.height > ReaderListFastScrollerGeometry.handleHeight
    }

    private func updateEmptyStateVisibility() {
        emptyLabel.isHidden = isChapterTocVisible || !isEmptyStateVisible
        emptyLabel.accessibilityElementsHidden = emptyLabel.isHidden
    }

    private func applyPalette() {
        fastScroller.apply(accent: palette.accent)
        backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        // ChangeBookSourceDialog.onFragmentCreated overrides background_menu with ThemeConfig.primaryColor.
        toolbarBackground.backgroundColor = palette.titleBackground
        toolbar.backgroundColor = palette.titleBackground
        bottomBackground.backgroundColor = palette.background
        bottomBar.backgroundColor = palette.background
        summaryLabel.textColor = palette.primaryText
        emptyLabel.textColor = palette.secondaryText
        for button in [topButton, bottomButton] { button.tintColor = palette.primaryText }
        progressView.progressTintColor = palette.accent
        progressView.trackTintColor = palette.background
        loadingIndicator.backgroundColor = UIColor(white: 193 / 255, alpha: 1)
    }
}
