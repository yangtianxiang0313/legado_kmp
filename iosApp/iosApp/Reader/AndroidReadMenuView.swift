import UIKit

final class AndroidReadMenuView: UIView {
    private enum Metrics {
        static let topBarHeight: CGFloat = 56
        static let progressRowHorizontalInset: CGFloat = 20
        static let progressSliderMinimumWidth: CGFloat = 64
        static let floatingRowHeight: CGFloat = 72
    }

    private struct MenuLayoutState {
        let minimumContentHeight: CGFloat

        init(bottomInset: CGFloat, showsBrightness: Bool, bottomRowsHeight: CGFloat) {
            // XML keeps the 40dp end controls vertical; only the weighted seekbar shrinks.
            minimumContentHeight =
                bottomInset + bottomRowsHeight + Metrics.floatingRowHeight
                + (showsBrightness ? 16 + 40 + 40 : 0)
        }
    }

    var onBack: (() -> Void)?
    var onBookInfo: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onNextChapter: (() -> Void)?
    var onPageSliderChange: ((Int, ReaderProgressBehavior) -> Void)?
    var onRefresh: (() -> Void)?
    var onRefreshLongPress: (() -> Void)?
    var onDownload: (() -> Void)?
    var onSetCharset: (() -> Void)?
    var onSearch: (() -> Void)?
    var onAutoPage: (() -> Void)?
    var onReplace: (() -> Void)?
    var onNight: (() -> Void)?
    var onToc: (() -> Void)?
    var onReadAloud: (() -> Void)?
    var onReadAloudLongPress: (() -> Void)?
    var onSettings: (() -> Void)?
    var onMoreSettings: (() -> Void)?
    var onMore: (() -> Void)?
    var onSource: (() -> Void)?
    var onChangeSource: (() -> Void)?
    var onChangeSourceLongPress: (() -> Void)?
    var onChapterSource: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onBrightnessChange: ((Float) -> Void)?
    var onBrightnessAutoChange: ((Bool, Float) -> Void)?

    private let backgroundButton = UIButton(type: .custom)
    private let menuScrollView = ReaderMenuContentScrollView()
    private let menuContentView = UIView()
    private let titleBar = UIView()
    private let titleEdgeBorder = CALayer()
    private let bottomEdgeBorder = CALayer()
    private let titleStack = UIStackView()
    private let toolbarView = ReaderMenuToolbarView()
    private let titleAdditionView = ReaderMenuTitleAdditionView()
    private let brightnessPanel = UIStackView()
    private let brightnessSliderHost = ReaderMenuBrightnessSliderHost()
    private var brightnessSlider: UISlider { brightnessSliderHost.slider }
    private let brightnessAutoButton = UIButton(type: .system)
    private let brightnessPositionButton = UIButton(type: .system)
    private let floatingStack = UIStackView()
    private let bottomPanel = UIStackView()
    private let previousButton = ReaderMenuChapterButton(type: .custom)
    private let nextButton = ReaderMenuChapterButton(type: .custom)
    private let pageSlider = ReaderMenuProgressSlider()
    private let menuStack = UIStackView()
    private var autoPageButton: UIButton?
    private var readAloudButton: ReaderMenuBottomActionButton?
    private var nightThemeButton: UIButton?
    private var actionButtons: [UIButton] = []
    private var floatingButtons: [ReaderMenuFloatingButton] = []
    private var localSettings = ReaderLocalSettings.load()
    private var menuTextColor = AndroidReplicaTheme.primaryText
    private var menuAccentColor = UIColor.systemOrange
    private var menuDisabledColor = UIColor.secondaryLabel
    private var sliderDisabledColor = UIColor.secondaryLabel
    private var currentPage = 0
    private var currentPageCount = 1
    private var currentChapter = 0
    private var currentChapterCount = 1
    private var progressContext = ReaderMenuProgressContext(bookURL: "", chapterURL: nil)
    private var isProgressTracking = false
    private var hasChapterSource = false
    private var isLocalBook = false
    private var chapterTitle = ""
    private var sourceName = ""
    private var chapterURL: String?
    private var nightThemeActive: Bool?
    private var brightnessLeadingConstraint: NSLayoutConstraint?
    private var brightnessTrailingConstraint: NSLayoutConstraint?
    private var brightnessWidthConstraint: NSLayoutConstraint?
    private var brightnessTopConstraint: NSLayoutConstraint?
    private var brightnessBottomConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var toolbarHeight = Metrics.topBarHeight
    private var minimumContentHeightConstraint: NSLayoutConstraint?
    private var chapterButtonHeightConstraints: [NSLayoutConstraint] = []
    private var progressRowHeightConstraint: NSLayoutConstraint?
    private var bottomMenuHeightConstraint: NSLayoutConstraint?
    private var progressRowHeight: CGFloat { max(previousButton.preferredHeight, nextButton.preferredHeight) + 10 }
    private var bottomMenuHeight: CGFloat {
        actionButtons.compactMap { $0 as? ReaderMenuBottomActionButton }.map(\.preferredHeight).max() ?? 47
    }
    private var isPresented = false
    private var presentationGeneration: UInt64 = 0
    private var isPresentationTransitioning = false
    private var presentationCompletions: [() -> Void] = []
    private var pageProgressAvailable = true
    private var chapterProgressAvailable = true
    private var appliedReaderTheme: ReaderThemeController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMenuTextMetrics()
        updateProgressInteraction()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            updateMenuTextMetrics()
        }
    }

    private func updateMenuTextMetrics() {
        previousButton.applyFont(compatibleWith: traitCollection)
        nextButton.applyFont(compatibleWith: traitCollection)
        for (button, height) in zip([previousButton, nextButton], chapterButtonHeightConstraints) {
            height.constant = button.preferredHeight
        }
        for button in actionButtons.compactMap({ $0 as? ReaderMenuBottomActionButton }) {
            button.applyFont(compatibleWith: traitCollection)
        }
        progressRowHeightConstraint?.constant = progressRowHeight
        bottomMenuHeightConstraint?.constant = bottomMenuHeight
        setNeedsLayout()
    }

    override func layoutSubviews() {
        toolbarHeight = toolbarView.updateLayout(availableSize: bounds.size)
        toolbarHeightConstraint?.constant = toolbarHeight
        updateBrightnessLayout()
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleEdgeBorder.frame = CGRect(
            x: 0, y: max(titleBar.bounds.height - 1, 0), width: titleBar.bounds.width, height: 1)
        bottomEdgeBorder.frame = CGRect(x: 0, y: 0, width: bottomPanel.bounds.width, height: 1)
        CATransaction.commit()
        if !isPresented && !isPresentationTransitioning {
            prepareForHiddenState()
        }
    }

    func apply(readerTheme: ReaderThemeController) {
        appliedReaderTheme = readerTheme
        let menuTraits =
            nightThemeActive.map {
                UITraitCollection(userInterfaceStyle: $0 ? .dark : .light)
            } ?? traitCollection
        let palette = ReaderMenuPalette(readerTheme: readerTheme, traits: menuTraits)
        menuTextColor = palette.bodyText
        menuAccentColor = palette.accent
        menuDisabledColor = palette.disabled
        sliderDisabledColor = palette.sliderDisabled
        titleBar.backgroundColor = palette.titleBackground
        bottomPanel.backgroundColor = palette.bottomBackground
        brightnessPanel.backgroundColor = palette.brightnessBackground
        for floatingButton in floatingButtons {
            floatingButton.apply(
                background: palette.floatingBackground, pressedBackground: palette.floatingPressedBackground)
        }
        for border in [titleEdgeBorder, bottomEdgeBorder] {
            border.backgroundColor = palette.edgeBorder?.cgColor
            border.isHidden = palette.edgeBorder == nil
        }
        toolbarView.apply(textColor: palette.titleText)
        titleAdditionView.apply(
            background: palette.titleBackground, text: palette.titleSecondaryText,
            sourceBackground: palette.accent, sourceText: palette.sourceText
        )
        brightnessAutoButton.tintColor = menuTextColor
        brightnessPositionButton.tintColor = menuTextColor
        configureSliderAppearance(pageSlider)
        configureSliderAppearance(brightnessSlider)
        for button in actionButtons {
            button.tintColor = menuTextColor
            button.setTitleColor(menuTextColor, for: .normal)
        }
        previousButton.setTitleColor(menuTextColor, for: .normal)
        nextButton.setTitleColor(menuTextColor, for: .normal)
        previousButton.setTitleColor(menuTextColor, for: .disabled)
        nextButton.setTitleColor(menuTextColor, for: .disabled)
        updateBrightnessControls()
        updateNavigationButtonAppearance()
    }

    func reloadLocalSettings() {
        localSettings = ReaderLocalSettings.load()
        updateBrightnessControls()
        updateTitleAdditionVisibility()
        updateProgressControl()
    }

    func setBrightnessValue(_ value: Float) {
        brightnessSlider.value = min(
            max(value, brightnessSlider.minimumValue), brightnessSlider.maximumValue)
    }

    func updateBookTitle(_ title: String) {
        toolbarView.updateBookTitle(title)
    }

    var overflowAnchorView: UIView { toolbarView.overflowAnchorView }

    var refreshMenuAnchor: UIView? {
        isPresented ? toolbarView.refreshMenuAnchor : nil
    }

    var changeSourceMenuAnchor: UIView? {
        isPresented ? toolbarView.changeSourceMenuAnchor : nil
    }

    var sourceMenuAnchor: UIView? {
        isPresented ? titleAdditionView.sourceMenuAnchor : nil
    }

    var overflowInterfaceStyle: UIUserInterfaceStyle {
        nightThemeActive.map { $0 ? .dark : .light } ?? traitCollection.userInterfaceStyle
    }

    func updateBookLocalState(isLocal: Bool) {
        isLocalBook = isLocal
        updateTitleAdditionVisibility()
        updateOnlineActionVisibility()
    }

    func updateChapter(title: String, source: String, url: String?) {
        chapterTitle = title
        sourceName = source
        chapterURL = url
        hasChapterSource = url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        updateTitleAdditionVisibility()
        updateOnlineActionVisibility()
    }

    func updateMenuProgress(page: Int, pageCount: Int, chapter: Int, chapterCount: Int) {
        currentPage = min(max(page, 0), max(pageCount - 1, 0))
        currentPageCount = max(pageCount, 1)
        currentChapter = min(max(chapter, 0), max(chapterCount - 1, 0))
        currentChapterCount = max(chapterCount, 1)
        updateProgressControl()
    }

    func updateProgressContext(bookURL: String, chapterURL: String?) {
        let context = ReaderMenuProgressContext(bookURL: bookURL, chapterURL: chapterURL)
        guard context != progressContext else { return }
        progressContext = context
        updateProgressControl()
    }

    func setProgressAvailability(page: Bool, chapter: Bool) {
        pageProgressAvailable = page
        chapterProgressAvailable = chapter
        updateProgressAvailability()
    }

    func setChapterLoading(_ loading: Bool) {
        toolbarView.setRefreshEnabled(!loading)
    }

    private func updateProgressAvailability() {
        pageSlider.setAvailability(page: pageProgressAvailable, chapter: chapterProgressAvailable)
    }

    private func updateProgressControl() {
        pageSlider.update(
            page: currentPage, pageCount: currentPageCount, chapter: currentChapter,
            chapterCount: currentChapterCount, behavior: ReaderLocalSettings.load().progressBehavior,
            context: progressContext)
        updateProgressAvailability()
    }

    private func updateProgressInteraction() {
        pageSlider.setInteractionActive(
            isPresented && window?.windowScene?.activationState == .foregroundActive
                && UIApplication.shared.applicationState == .active)
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        if notification.name == UIScene.willDeactivateNotification {
            pageSlider.setInteractionActive(false)
        } else {
            resumeProgressInteraction()
        }
    }

    @objc private func applicationDidBecomeActive() {
        resumeProgressInteraction()
    }

    private func resumeProgressInteraction() {
        updateProgressInteraction()
        // Scene activation can precede UIApplication's active state by one delivery turn.
        DispatchQueue.main.async { [weak self] in self?.updateProgressInteraction() }
    }

    func setNavigationEnabled(previous: Bool, next: Bool) {
        previousButton.isEnabled = previous
        nextButton.isEnabled = next
        updateNavigationButtonAppearance()
    }

    func setAutoPageRunning(_ running: Bool) {
        let icon: ReaderMenuAndroidIcon = running ? .autoPageStop : .autoPage
        autoPageButton?.setImage(icon.image(), for: .normal)
        autoPageButton?.accessibilityLabel =
            running ? L10n.Reader.autoPageStop : L10n.Reader.autoPageStart
    }

    func setNightThemeActive(_ active: Bool) {
        nightThemeActive = active
        nightThemeButton?.setImage((active ? ReaderMenuAndroidIcon.daytime : .brightness).image(), for: .normal)
        nightThemeButton?.accessibilityValue =
            active ? L10n.Settings.themeModeDark : L10n.Settings.themeModeLight
    }

    private func configureViews() {
        backgroundColor = .clear
        backgroundButton.backgroundColor = .clear
        backgroundButton.accessibilityLabel = "关闭菜单"
        backgroundButton.accessibilityTraits = .button
        backgroundButton.addTarget(self, action: #selector(hideSelf), for: .touchUpInside)

        titleBar.backgroundColor = AndroidReplicaTheme.background.withAlphaComponent(0.96)
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        titleStack.axis = .vertical
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.addArrangedSubview(toolbarView)
        titleStack.addArrangedSubview(titleAdditionView)
        titleBar.addSubview(titleStack)
        titleEdgeBorder.isHidden = true
        titleBar.layer.addSublayer(titleEdgeBorder)
        titleAdditionView.onChapterSource = { [weak self] in self?.handleChapterSource() }
        titleAdditionView.onSource = { [weak self] in self?.handleSource() }
        bottomPanel.axis = .vertical
        bottomPanel.backgroundColor = AndroidReplicaTheme.background.withAlphaComponent(0.96)
        bottomPanel.isLayoutMarginsRelativeArrangement = true
        bottomPanel.insetsLayoutMarginsFromSafeArea = false
        bottomPanel.setContentHuggingPriority(.required, for: .vertical)
        bottomPanel.setContentCompressionResistancePriority(.required, for: .vertical)
        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomEdgeBorder.isHidden = true
        bottomPanel.layer.addSublayer(bottomEdgeBorder)

        for item in [backgroundButton, menuScrollView, titleBar] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        menuScrollView.contentInsetAdjustmentBehavior = .never
        menuScrollView.showsVerticalScrollIndicator = false
        menuScrollView.bounces = false
        menuScrollView.passthroughView = menuContentView
        menuContentView.translatesAutoresizingMaskIntoConstraints = false
        menuScrollView.addSubview(menuContentView)
        for item in [brightnessPanel, floatingStack, bottomPanel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            menuContentView.addSubview(item)
        }

        configureTitleBar()
        configureBrightness()
        configureFloatingButtons()
        configureBottomPanel()
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteChanged), name: .androidReplicaThemeDidChange, object: nil)

        // upBrightnessVwPos uses physical LEFT/RIGHT, independent of the menu's RTL flow.
        brightnessLeadingConstraint = brightnessPanel.leftAnchor.constraint(
            equalTo: safeAreaLayoutGuide.leftAnchor, constant: 16)
        brightnessTrailingConstraint = brightnessPanel.rightAnchor.constraint(
            equalTo: safeAreaLayoutGuide.rightAnchor, constant: -16)
        brightnessWidthConstraint = brightnessPanel.widthAnchor.constraint(equalToConstant: 40)
        brightnessTopConstraint = brightnessPanel.topAnchor.constraint(
            equalTo: menuContentView.topAnchor, constant: 16)
        brightnessBottomConstraint = brightnessPanel.bottomAnchor.constraint(
            equalTo: floatingStack.topAnchor)
        minimumContentHeightConstraint = menuContentView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 0)
        toolbarHeightConstraint = toolbarView.heightAnchor.constraint(equalToConstant: Metrics.topBarHeight)
        let preferredContentHeight = menuContentView.heightAnchor.constraint(
            equalTo: menuScrollView.frameLayoutGuide.heightAnchor)
        preferredContentHeight.priority = .defaultLow
        brightnessWidthConstraint?.isActive = true
        brightnessTopConstraint?.isActive = true
        minimumContentHeightConstraint?.isActive = true
        toolbarHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            backgroundButton.topAnchor.constraint(equalTo: topAnchor),
            backgroundButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            titleStack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            titleStack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            titleStack.bottomAnchor.constraint(equalTo: titleBar.bottomAnchor),

            menuScrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            menuScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            menuScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuContentView.topAnchor.constraint(equalTo: menuScrollView.contentLayoutGuide.topAnchor),
            menuContentView.leadingAnchor.constraint(
                equalTo: menuScrollView.contentLayoutGuide.leadingAnchor),
            menuContentView.trailingAnchor.constraint(
                equalTo: menuScrollView.contentLayoutGuide.trailingAnchor),
            menuContentView.bottomAnchor.constraint(
                equalTo: menuScrollView.contentLayoutGuide.bottomAnchor),
            menuContentView.widthAnchor.constraint(equalTo: menuScrollView.frameLayoutGuide.widthAnchor),
            menuContentView.heightAnchor.constraint(
                greaterThanOrEqualTo: menuScrollView.frameLayoutGuide.heightAnchor),
            preferredContentHeight,

            floatingStack.leadingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            floatingStack.trailingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            floatingStack.topAnchor.constraint(greaterThanOrEqualTo: menuContentView.topAnchor),
            floatingStack.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),
            floatingStack.heightAnchor.constraint(equalToConstant: Metrics.floatingRowHeight),

            bottomPanel.leadingAnchor.constraint(equalTo: menuContentView.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: menuContentView.trailingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: menuContentView.bottomAnchor),
        ])
        updateBrightnessControls()
        updateSystemBarInsets()
        prepareForHiddenState()
    }

    @objc private func themePaletteChanged() {
        guard let appliedReaderTheme else { return }
        apply(readerTheme: appliedReaderTheme)
    }

    func setPresented(_ presented: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        if presented == isPresented, isPresentationTransitioning {
            if let completion { presentationCompletions.append(completion) }
            return
        }
        if presented == isPresented, isHidden == !presented {
            completion?()
            return
        }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationCompletions = completion.map { [$0] } ?? []
        let wasHidden = isHidden
        let shouldAnimate = animated && !ReaderPaletteColor.isEInk
        isPresented = presented
        isPresentationTransitioning = true
        isUserInteractionEnabled = presented
        updateProgressInteraction()
        backgroundButton.isEnabled = presented && !isProgressTracking
        layoutIfNeeded()
        let finish = { [weak self] in
            guard let self, self.presentationGeneration == generation, self.isPresented == presented else { return }
            self.isPresentationTransitioning = false
            self.isHidden = !presented
            self.accessibilityViewIsModal = presented
            let callbacks = self.presentationCompletions
            self.presentationCompletions.removeAll()
            UIAccessibility.post(
                notification: .screenChanged, argument: presented ? self.toolbarView.titleAccessibilityElement : nil)
            for callback in callbacks {
                guard self.presentationGeneration == generation else { break }
                callback()
            }
        }
        if presented {
            isHidden = false
            menuScrollView.setContentOffset(.zero, animated: false)
            accessibilityViewIsModal = true
            // Reversing a live transition keeps its presentation-layer position.
            if wasHidden { prepareForHiddenState() }
            animateMenuIn(animated: shouldAnimate, completion: finish)
        } else {
            animateMenuOut(animated: shouldAnimate, completion: finish)
        }
    }

    private func configureTitleBar() {
        toolbarView.onBack = { [weak self] in self?.onBack?() }
        toolbarView.onBookInfo = { [weak self] in self?.onBookInfo?() }
        toolbarView.onChangeSource = { [weak self] in self?.onChangeSource?() }
        toolbarView.onRefresh = { [weak self] in self?.onRefresh?() }
        toolbarView.onBookAction = { [weak self] in
            guard let self else { return }
            if self.isLocalBook {
                self.onSetCharset?()
            } else {
                self.onDownload?()
            }
        }
        toolbarView.onMore = { [weak self] in self?.onMore?() }
        toolbarView.onChangeSourceLongPress = { [weak self] in
            guard let self, self.isPresented, let action = self.onChangeSourceLongPress else {
                return false
            }
            action()
            return true
        }
        toolbarView.onRefreshLongPress = { [weak self] in
            guard let self, self.isPresented, let action = self.onRefreshLongPress else {
                return false
            }
            action()
            return true
        }
        updateOnlineActionVisibility()
    }

    private func configureBrightness() {
        brightnessPanel.axis = .vertical
        brightnessPanel.alignment = .center
        brightnessPanel.spacing = 0
        brightnessPanel.backgroundColor = AndroidReplicaTheme.primaryText.withAlphaComponent(0.08)
        brightnessPanel.layer.cornerRadius = 5
        configureIconButton(
            brightnessAutoButton, systemName: "sun.max", androidIcon: .brightnessAuto,
            action: #selector(handleBrightnessAuto))
        configureIconButton(
            brightnessPositionButton, systemName: "arrow.left.arrow.right",
            androidIcon: .swapHoriz,
            action: #selector(handleBrightnessPosition))
        brightnessAutoButton.accessibilityIdentifier = UIIdentifiers.Reader.brightnessAutoButton
        brightnessPositionButton.accessibilityIdentifier = UIIdentifiers.Reader.brightnessPositionButton
        brightnessAutoButton.setContentHuggingPriority(.required, for: .vertical)
        brightnessPositionButton.setContentHuggingPriority(.required, for: .vertical)
        brightnessSlider.accessibilityIdentifier = UIIdentifiers.Reader.brightnessBar
        brightnessSlider.setContentHuggingPriority(.defaultLow, for: .vertical)
        brightnessSlider.minimumValue = 0
        brightnessSlider.maximumValue = 1
        brightnessSlider.value = Float(UIScreen.main.brightness)
        brightnessSlider.addTarget(self, action: #selector(handleBrightnessSlider), for: .valueChanged)
        let brightnessTap = UITapGestureRecognizer(
            target: self, action: #selector(handleBrightnessPanelTap(_:)))
        brightnessTap.cancelsTouchesInView = false
        let brightnessPan = UIPanGestureRecognizer(
            target: self, action: #selector(handleBrightnessPanelPan(_:)))
        brightnessPan.cancelsTouchesInView = false
        brightnessPanel.addGestureRecognizer(brightnessTap)
        brightnessPanel.addGestureRecognizer(brightnessPan)
        brightnessPanel.addArrangedSubview(brightnessAutoButton)
        brightnessPanel.addArrangedSubview(brightnessSliderHost)
        brightnessPanel.addArrangedSubview(brightnessPositionButton)
        brightnessAutoButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        brightnessPositionButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        brightnessAutoButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        brightnessPositionButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        brightnessSliderHost.widthAnchor.constraint(equalToConstant: 40).isActive = true
        brightnessSliderHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
    }

    private func configureFloatingButtons() {
        floatingStack.axis = .horizontal
        floatingStack.alignment = .fill
        floatingStack.distribution = .equalSpacing
        let searchButton = addFloatingButton("magnifyingglass", androidIcon: .search, action: #selector(handleSearch))
        autoPageButton = addFloatingButton("play.rectangle", androidIcon: .autoPage, action: #selector(handleAutoPage))
        let replaceRuleButton = addFloatingButton(
            "text.magnifyingglass", androidIcon: .findReplace, action: #selector(handleReplace))
        nightThemeButton = addFloatingButton("moon", androidIcon: .brightness, action: #selector(handleNight))
        searchButton.accessibilityLabel = L10n.Reader.menuSearch
        replaceRuleButton.accessibilityLabel = L10n.Reader.quickReplaceAction
        nightThemeButton?.accessibilityLabel = L10n.Reader.menuNightTheme
        searchButton.accessibilityIdentifier = UIIdentifiers.Reader.searchButton
        autoPageButton?.accessibilityIdentifier = UIIdentifiers.Reader.autoPageButton
        replaceRuleButton.accessibilityIdentifier = UIIdentifiers.Reader.replaceRuleButton
        nightThemeButton?.accessibilityIdentifier = UIIdentifiers.Reader.nightThemeButton
        setAutoPageRunning(false)
    }

    private func configureBottomPanel() {
        let progressRow = UIStackView()
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.isLayoutMarginsRelativeArrangement = true
        progressRow.insetsLayoutMarginsFromSafeArea = false
        progressRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 5,
            leading: Metrics.progressRowHorizontalInset,
            bottom: 5,
            trailing: Metrics.progressRowHorizontalInset
        )

        previousButton.setTitle(L10n.Reader.menuPrevious, for: .normal)
        nextButton.setTitle(L10n.Reader.menuNext, for: .normal)
        progressRow.addArrangedSubview(previousButton)
        progressRow.addArrangedSubview(pageSlider)
        progressRow.addArrangedSubview(nextButton)
        for button in [previousButton, nextButton] {
            button.isEnabled = false
            // Android's 10pt horizontal margins remain tappable on iOS.
            button.applyFont(compatibleWith: traitCollection)
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.adjustsFontSizeToFitWidth = false
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.clipsToBounds = true
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let height = button.heightAnchor.constraint(equalToConstant: button.preferredHeight)
            chapterButtonHeightConstraints.append(height)
            NSLayoutConstraint.activate([
                height,
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                button.widthAnchor.constraint(
                    lessThanOrEqualTo: progressRow.widthAnchor, multiplier: 0.5,
                    constant: -Metrics.progressRowHorizontalInset - Metrics.progressSliderMinimumWidth / 2),
            ])
        }
        previousButton.addTarget(self, action: #selector(handlePrevious), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(handleNext), for: .touchUpInside)
        previousButton.accessibilityLabel = L10n.Reader.menuPrevious
        nextButton.accessibilityLabel = L10n.Reader.menuNext
        previousButton.accessibilityIdentifier = UIIdentifiers.Reader.previousButton
        nextButton.accessibilityIdentifier = UIIdentifiers.Reader.nextButton
        pageSlider.onCommit = { [weak self] value, behavior in
            self?.onPageSliderChange?(value, behavior)
        }
        pageSlider.onTrackingChange = { [weak self] tracking in
            guard let self else { return }
            self.isProgressTracking = tracking
            self.backgroundButton.isEnabled = self.isPresented && !tracking
            self.updateBrightnessLayout()
        }

        pageSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pageSlider.heightAnchor.constraint(equalToConstant: 25).isActive = true
        pageSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.progressSliderMinimumWidth).isActive =
            true

        menuStack.axis = .horizontal
        // Equal-width hosts place the fixed 60pt buttons at W/8, 3W/8, 5W/8, 7W/8.
        menuStack.distribution = .fillEqually
        menuStack.alignment = .fill
        menuStack.insetsLayoutMarginsFromSafeArea = false
        let tocButton = addMenuButton(
            title: L10n.Reader.menuToc, icon: .toc, action: #selector(handleToc))
        readAloudButton = addMenuButton(
            title: L10n.Reader.menuReadAloud, icon: .readAloud, action: #selector(handleReadAloud))
        let settingsButton = addMenuButton(
            title: L10n.Reader.menuInterface, icon: .interfaceSetting, action: #selector(handleSettings))
        let moreButton = addMenuButton(
            title: L10n.Reader.menuSettings, icon: .settings, action: #selector(handleMoreSettings))
        tocButton.accessibilityIdentifier = UIIdentifiers.Reader.tocButton
        readAloudButton?.accessibilityIdentifier = UIIdentifiers.Reader.readAloudButton
        settingsButton.accessibilityIdentifier = UIIdentifiers.Reader.interfaceButton
        moreButton.accessibilityIdentifier = UIIdentifiers.Reader.settingsButton
        readAloudButton?.configureSecondaryAction(name: "朗读设置") { [weak self] in
            guard let self, self.isPresented, let action = self.onReadAloudLongPress else { return false }
            self.performAfterMenuOut(action)
            return true
        }

        bottomPanel.addArrangedSubview(progressRow)
        bottomPanel.addArrangedSubview(menuStack)
        progressRowHeightConstraint = progressRow.heightAnchor.constraint(equalToConstant: progressRowHeight)
        bottomMenuHeightConstraint = menuStack.heightAnchor.constraint(equalToConstant: bottomMenuHeight)
        progressRowHeightConstraint?.isActive = true
        bottomMenuHeightConstraint?.isActive = true
        updateMenuTextMetrics()
    }

    private func configureIconButton(
        _ button: UIButton, systemName: String, androidIcon: ReaderMenuAndroidIcon? = nil, action: Selector
    ) {
        button.setImage(androidIcon?.image() ?? UIImage(systemName: systemName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .regular), forImageIn: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureSliderAppearance(_ slider: UISlider) {
        // Custom assets retain Android's thin track and round thumb on newer UIKit sliders.
        func track(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            }.resizableImage(withCapInsets: .zero)
        }
        func thumb(_ color: UIColor, diameter: CGFloat = 12, outlined: Bool = false) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { _ in
                let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                if outlined {
                    // abc_scrubber_control_off_mtrl_alpha is a 12dp ring with a 2dp stroke.
                    color.setStroke()
                    let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                    ring.lineWidth = 2
                    ring.stroke()
                } else {
                    color.setFill()
                    UIBezierPath(ovalIn: rect).fill()
                }
            }
        }
        slider.setMinimumTrackImage(track(menuAccentColor), for: .normal)
        slider.setMaximumTrackImage(track(menuTextColor.withAlphaComponent(0.3)), for: .normal)
        slider.setThumbImage(thumb(menuAccentColor), for: .normal)
        // AppCompat's thumb selector uses a 12dp resting bitmap and an 18dp pressed bitmap.
        slider.setThumbImage(thumb(menuAccentColor, diameter: 18), for: .highlighted)
        slider.setMinimumTrackImage(track(sliderDisabledColor), for: .disabled)
        slider.setMaximumTrackImage(track(sliderDisabledColor), for: .disabled)
        slider.setThumbImage(thumb(sliderDisabledColor, outlined: true), for: .disabled)
    }

    @discardableResult
    private func addFloatingButton(_ systemName: String, androidIcon: ReaderMenuAndroidIcon? = nil, action: Selector)
        -> UIButton
    {
        let button = ReaderMenuFloatingButton(type: .custom)
        button.adjustsImageWhenHighlighted = false
        configureIconButton(button, systemName: systemName, androidIcon: androidIcon, action: action)
        actionButtons.append(button)
        let background = AndroidReplicaTheme.background.withAlphaComponent(0.96)
        button.apply(background: background, pressedBackground: background)
        button.layer.cornerRadius = 20
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.08
        button.layer.shadowRadius = 2
        // Root padding is 16pt; each mini FAB has another 16pt margin on each side.
        let host = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        floatingStack.addArrangedSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: Metrics.floatingRowHeight),
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
            button.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        floatingButtons.append(button)
        return button
    }

    @discardableResult
    private func addMenuButton(
        title: String, icon: ReaderMenuAndroidIcon, action: Selector
    ) -> ReaderMenuBottomActionButton {
        let button = ReaderMenuBottomActionButton(title: title, icon: icon)
        button.addTarget(self, action: action, for: .touchUpInside)
        actionButtons.append(button)
        let host = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        menuStack.addArrangedSubview(host)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 60),
            button.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            button.topAnchor.constraint(equalTo: host.topAnchor),
            button.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return button
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateSystemBarInsets()
        setNeedsLayout()
    }

    private func updateSystemBarInsets() {
        let bottomInset = max(safeAreaInsets.bottom, 0)
        let margins = NSDirectionalEdgeInsets(
            top: 0,
            leading: max(safeAreaInsets.left, 0),
            bottom: bottomInset,
            trailing: max(safeAreaInsets.right, 0)
        )
        if bottomPanel.directionalLayoutMargins != margins {
            bottomPanel.directionalLayoutMargins = margins
            setNeedsLayout()
        }
    }

    private func prepareForHiddenState() {
        let topOffset = -max(titleBar.bounds.height, toolbarHeight + safeAreaInsets.top)
        // Android translates the entire bottom_menu, including its floating-button row.
        let bottomOffset = max(
            floatingStack.bounds.height + bottomPanel.bounds.height,
            Metrics.floatingRowHeight + bottomMenuHeight + safeAreaInsets.bottom + progressRowHeight)
        titleBar.transform = CGAffineTransform(translationX: 0, y: topOffset)
        floatingStack.transform = CGAffineTransform(translationX: 0, y: bottomOffset)
        bottomPanel.transform = CGAffineTransform(translationX: 0, y: bottomOffset)
        backgroundButton.alpha = 0
    }

    private func animateMenuIn(animated: Bool, completion: (() -> Void)?) {
        let applyVisibleState = {
            self.titleBar.transform = .identity
            self.floatingStack.transform = .identity
            self.bottomPanel.transform = .identity
            self.backgroundButton.alpha = 1
        }
        guard animated else {
            applyVisibleState()
            completion?()
            return
        }
        // The Android translate resources use Animation's default accelerate-decelerate interpolator.
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: {
                self.titleBar.transform = .identity
                self.backgroundButton.alpha = 1
            },
            completion: { _ in completion?() }
        )
        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: {
                self.floatingStack.transform = .identity
                self.bottomPanel.transform = .identity
            }
        )
    }

    private func animateMenuOut(animated: Bool, completion: (() -> Void)?) {
        let applyHiddenState = {
            self.prepareForHiddenState()
        }
        guard animated else {
            applyHiddenState()
            completion?()
            return
        }
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: applyHiddenState,
            completion: { _ in completion?() }
        )
    }

    @objc private func hideSelf() {
        guard let onDismiss else {
            setPresented(false, animated: true)
            return
        }
        onDismiss()
    }

    @objc private func handlePrevious() {
        onPreviousChapter?()
    }

    @objc private func handleNext() {
        onNextChapter?()
    }

    @objc private func handleSearch() {
        performAfterMenuOut(onSearch)
    }

    @objc private func handleAutoPage() {
        performAfterMenuOut(onAutoPage)
    }

    @objc private func handleReplace() {
        onReplace?()
    }

    @objc private func handleNight() {
        onNight?()
    }

    @objc private func handleToc() {
        performAfterMenuOut(onToc)
    }

    @objc private func handleReadAloud() {
        performAfterMenuOut(onReadAloud)
    }

    @objc private func handleSettings() {
        performAfterMenuOut(onSettings)
    }

    @objc private func handleMoreSettings() {
        performAfterMenuOut(onMoreSettings)
    }

    private func performAfterMenuOut(_ action: (() -> Void)?) {
        guard isPresented, let action, let window, let scene = window.windowScene else { return }
        // Notify the owner immediately, then append to its in-flight dismissal completion.
        hideSelf()
        setPresented(false, animated: true) { [weak self, weak window, weak scene] in
            guard let self, let window, let scene, self.window === window,
                window.windowScene === scene, scene.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active, self.isHidden, !self.isPresented
            else { return }
            action()
        }
    }

    @objc private func handleSource() {
        guard sourceMenuAnchor != nil else { return }
        onSource?()
    }

    @objc private func handleChapterSource() {
        guard isPresented, !isLocalBook, hasChapterSource else { return }
        onChapterSource?()
    }

    @objc private func handleBrightnessSlider() {
        localSettings.brightnessAuto = false
        localSettings.persist()
        onBrightnessChange?(brightnessSlider.value)
        updateBrightnessControls()
    }

    @objc private func handleBrightnessAuto() {
        localSettings.brightnessAuto.toggle()
        if localSettings.brightnessAuto {
            brightnessSlider.value = Float(UIScreen.main.brightness)
        }
        localSettings.persist()
        onBrightnessAutoChange?(localSettings.brightnessAuto, brightnessSlider.value)
        updateBrightnessControls()
    }

    @objc private func handleBrightnessPosition() {
        localSettings.brightnessOnRight.toggle()
        localSettings.persist()
        updateBrightnessControls()
    }

    @objc private func handleBrightnessPanelTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        applyBrightnessPanelLocation(recognizer.location(in: brightnessPanel))
    }

    @objc private func handleBrightnessPanelPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        applyBrightnessPanelLocation(recognizer.location(in: brightnessPanel))
    }

    private func applyBrightnessPanelLocation(_ point: CGPoint) {
        guard !localSettings.brightnessAuto, brightnessSlider.isEnabled else { return }
        let location = brightnessSliderHost.convert(point, from: brightnessPanel)
        guard brightnessSliderHost.bounds.contains(location) else { return }
        let progress = 1 - Float((location.y - 8) / max(brightnessSliderHost.bounds.height - 16, 1))
        brightnessSlider.value = min(
            max(progress, brightnessSlider.minimumValue), brightnessSlider.maximumValue)
        handleBrightnessSlider()
    }

    private func updateBrightnessLayout() {
        let availableHeight = max(
            bounds.height - max(titleBar.bounds.height, toolbarHeight + safeAreaInsets.top), 0)
        let layout = MenuLayoutState(
            bottomInset: max(safeAreaInsets.bottom, 0),
            showsBrightness: !brightnessPanel.isHidden,
            bottomRowsHeight: progressRowHeight + bottomMenuHeight
        )
        updateSystemBarInsets()
        minimumContentHeightConstraint?.constant = layout.minimumContentHeight
        brightnessBottomConstraint?.isActive = !brightnessPanel.isHidden
        menuScrollView.isScrollEnabled = layout.minimumContentHeight > availableHeight && !isProgressTracking
        if layout.minimumContentHeight <= availableHeight, menuScrollView.contentOffset != .zero {
            menuScrollView.setContentOffset(.zero, animated: false)
        }
    }

    private func updateBrightnessControls() {
        brightnessPanel.isHidden = !localSettings.showBrightnessBar
        let brightnessAuto = localSettings.brightnessAuto || !localSettings.showBrightnessBar
        brightnessLeadingConstraint?.isActive = !localSettings.brightnessOnRight
        brightnessTrailingConstraint?.isActive = localSettings.brightnessOnRight
        brightnessAutoButton.tintColor =
            brightnessAuto ? menuAccentColor : menuDisabledColor
        brightnessPositionButton.tintColor = menuTextColor
        brightnessAutoButton.alpha = 1
        brightnessSlider.isEnabled = !brightnessAuto
        brightnessPanel.accessibilityLabel =
            localSettings.brightnessOnRight
            ? L10n.Reader.brightnessPositionRight
            : L10n.Reader.brightnessPositionLeft
        brightnessAutoButton.accessibilityLabel =
            brightnessAuto
            ? L10n.Reader.brightnessAutoEnabled
            : L10n.Reader.brightnessAutoDisabled
        brightnessPositionButton.accessibilityLabel =
            localSettings.brightnessOnRight
            ? L10n.Reader.brightnessPositionRight
            : L10n.Reader.brightnessPositionLeft
        setNeedsLayout()
    }

    private func updateTitleAdditionVisibility() {
        titleAdditionView.update(
            chapter: chapterTitle, source: sourceName, url: chapterURL,
            isLocal: isLocalBook, showsAddition: localSettings.showTitleAddition
        )
        updateOnlineActionVisibility()
        setNeedsLayout()
    }

    private func updateOnlineActionVisibility() {
        toolbarView.updateBookLocalState(isLocal: isLocalBook)
    }

    private func updateNavigationButtonAppearance() {
        // Android ReadMenu sets a single text color even at a chapter boundary.
        previousButton.alpha = 1
        nextButton.alpha = 1
    }

}

private final class ReaderMenuContentScrollView: UIScrollView {
    weak var passthroughView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        if isScrollEnabled { return target }
        // Only pass blank-area taps through when scrolling is unnecessary.
        return target === self || target === passthroughView ? nil : target
    }
}
