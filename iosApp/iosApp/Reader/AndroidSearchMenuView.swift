import UIKit
import shared

// Legado 5f5d31404: view_search_menu.xml and SearchMenu.kt.
final class AndroidSearchMenuView: UIView {
    var onResultSelected: ((ContentSearchResult) -> Void)?
    var onOpenResultList: ((String?, [ContentSearchResult], Int?) -> Void)?
    var onOpenMainMenu: (() -> Void)?
    var onExit: (() -> Void)?
    /// Bind with a weak reader owner; include book/top controller, modal and navigation availability.
    var canInteract: (() -> Bool)? {
        didSet { updateInteractionAvailability() }
    }

    var hasResults: Bool { !results.isEmpty }
    var options = ReaderContentSearchOptions()
    private(set) var resultOptions = ReaderContentSearchOptions()

    private let backgroundButton = UIButton(type: .custom)
    private let previousResultButton = ReaderSearchFloatingButton(frame: .zero)
    private let nextResultButton = ReaderSearchFloatingButton(frame: .zero)
    private let bottomPanelScrollView = UIScrollView()
    private let bottomPanel = UIView()
    private let infoRow = UIView()
    private let previousInfoButton = ReaderSearchSelectorButton(frame: .zero)
    private let nextInfoButton = ReaderSearchSelectorButton(frame: .zero)
    private let infoLabel = ReaderTocSingleLineLabel()
    private let actionRow = UIView()
    private let resultsButton = ReaderSearchActionButton(
        title: ReaderSearchMenuText.results,
        image: ReaderMenuAndroidIcon.toc.image(size: 20))
    private let mainMenuButton = ReaderSearchActionButton(
        title: ReaderSearchMenuText.mainMenu,
        image: UIImage(named: "ReaderFindAndroidMenu")?.withRenderingMode(.alwaysTemplate))
    private let exitButton = ReaderSearchActionButton(
        title: ReaderSearchMenuText.exit,
        image: ReaderMenuAndroidIcon.autoPageStop.image(size: 20))

    private var results: [ContentSearchResult] = []
    private var selectedResultIndex = -1
    private var cachedQuery: String?
    private var currentChapterIndex = 0
    private var isBottomMenuVisible = false
    private var menuAnimationGeneration: UInt64 = 0
    private var resultGeneration: UInt64 = 0
    private var isBottomMenuTransitioning = false
    private var pendingMenuAction: (() -> Void)?
    private var interactionActive = true
    private var environmentActive = false

    init(screen _: ReaderScreenAdapterSearchable) {
        super.init(frame: .zero)
        configureViews()
        setVisible(false, currentChapterIndex: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHidden: Bool {
        didSet {
            if isHidden, !oldValue { cancelMenuTransition() }
            updateControls()
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { updateInteractionAvailability() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window {
            environmentActive = false
            updateInteractionAvailability()
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateEnvironmentAvailability()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundButton.frame = bounds
        updateInfo()

        // The mini FABs are centered in the entire page, not the space above the menu.
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let left = bounds.minX + safeAreaInsets.left + 16
        let right = bounds.maxX - safeAreaInsets.right - 56
        previousResultButton.frame = CGRect(x: isRTL ? right : left, y: bounds.midY - 20, width: 40, height: 40)
        nextResultButton.frame = CGRect(x: isRTL ? left : right, y: bounds.midY - 20, width: 40, height: 40)

        let contentWidth = max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right)
        // Keep Android's 36dp row at ordinary sizes; larger text retains its full padded line.
        let infoHeight = max(36, infoLabel.intrinsicContentSize.height)
        let actionHeight = max(
            resultsButton.preferredHeight, max(mainMenuButton.preferredHeight, exitButton.preferredHeight))
        let panelHeight = infoHeight + actionHeight + safeAreaInsets.bottom
        let availableHeight = max(0, min(bounds.height - safeAreaInsets.top, bounds.height / 2 - 28))
        let viewportHeight = min(panelHeight, availableHeight)
        // A short window scrolls the bottom controls without moving or covering the FABs.
        bottomPanelScrollView.bounds.size = CGSize(width: bounds.width, height: viewportHeight)
        bottomPanelScrollView.center = CGPoint(x: bounds.midX, y: bounds.maxY - viewportHeight / 2)
        bottomPanelScrollView.contentSize = CGSize(width: bounds.width, height: panelHeight)
        bottomPanelScrollView.showsVerticalScrollIndicator = viewportHeight < panelHeight
        let maxOffset = max(0, panelHeight - viewportHeight)
        if bottomPanelScrollView.contentOffset.y > maxOffset {
            bottomPanelScrollView.contentOffset.y = maxOffset
        }
        bottomPanel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: panelHeight)

        infoRow.frame = CGRect(x: safeAreaInsets.left, y: 0, width: contentWidth, height: infoHeight)
        let infoPadding = min(10, contentWidth / 2)
        let arrowWidth = min(36, max(0, contentWidth - infoPadding * 2) / 2)
        func infoFrame(leading: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: isRTL ? contentWidth - leading - width : leading, y: 0, width: width, height: infoHeight)
        }
        previousInfoButton.frame = infoFrame(leading: infoPadding, width: arrowWidth)
        nextInfoButton.frame = infoFrame(leading: infoPadding + arrowWidth, width: arrowWidth)
        let infoLeading = min(contentWidth, infoPadding + arrowWidth * 2 + 10)
        infoLabel.frame = infoFrame(leading: infoLeading, width: max(0, contentWidth - infoLeading - 20))

        actionRow.frame = CGRect(x: safeAreaInsets.left, y: infoHeight, width: contentWidth, height: actionHeight)
        let buttonWidth = min(60, contentWidth / 3)
        let gap = max(0, contentWidth - buttonWidth * 3) / 6
        for (button, leading) in [
            (resultsButton, gap), (mainMenuButton, gap * 3 + buttonWidth),
            (exitButton, gap * 5 + buttonWidth * 2),
        ] {
            button.frame = CGRect(
                x: isRTL ? contentWidth - leading - buttonWidth : leading,
                y: 0, width: buttonWidth, height: actionHeight)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard allowsInteraction else {
            cancelMenuTransition()
            return nil
        }
        let hit = super.hitTest(point, with: event)
        // runMenuOut leaves the FABs visible, but the reading page must receive other touches.
        return hit === self ? nil : hit
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        applyPalette()
    }

    func apply(readerTheme _: ReaderThemeController) {
        applyPalette()
    }

    private func applyPalette() {
        // SearchMenu uses app bottomBackground contrast, never the book's paper/text colors.
        bottomPanelScrollView.backgroundColor = AndroidReplicaTheme.bottomBackground
        infoLabel.textColor = ReaderSearchChromePalette.foreground
        for button in [previousInfoButton, nextInfoButton, resultsButton, mainMenuButton, exitButton] {
            button.applyPalette()
        }
        for button in [previousResultButton, nextResultButton] {
            button.applyPalette()
        }
    }

    func setVisible(_ visible: Bool, currentChapterIndex: Int) {
        self.currentChapterIndex = currentChapterIndex
        let wasBottomMenuVisible = !isHidden && isBottomMenuVisible
        let wasTransitioning = isBottomMenuTransitioning
        let hadPanel = !isHidden && !bottomPanelScrollView.isHidden
        invalidateMenuTransition(preservingPosition: visible && hadPanel)
        isBottomMenuVisible = visible
        isHidden = !visible
        alpha = 1
        backgroundButton.isHidden = !visible
        bottomPanelScrollView.isHidden = !visible
        updateInfo()
        guard visible, !wasBottomMenuVisible || wasTransitioning else {
            bottomPanelScrollView.transform = .identity
            updateControls()
            return
        }
        setNeedsLayout()
        layoutIfNeeded()
        if !hadPanel {
            bottomPanelScrollView.setContentOffset(.zero, animated: false)
            bottomPanelScrollView.transform = CGAffineTransform(
                translationX: 0, y: bottomPanelScrollView.bounds.height)
        }
        guard environmentActive, interactionActive else {
            bottomPanelScrollView.transform = .identity
            updateControls()
            return
        }
        let generation = menuAnimationGeneration
        isBottomMenuTransitioning = true
        updateControls()
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.bottomPanelScrollView.transform = .identity
        } completion: { [weak self] _ in
            guard let self, self.menuAnimationGeneration == generation,
                self.isBottomMenuVisible, !self.isHidden
            else { return }
            self.isBottomMenuTransitioning = false
            self.updateControls()
        }
    }

    /// Cancels tracking and deferred actions without changing search/FAB or bottom-menu visibility.
    /// The owner should deactivate before covering the reader, then reactivate when it owns input.
    func setInteractionActive(_ active: Bool) {
        interactionActive = active
        updateInteractionAvailability()
    }

    func updateCurrentChapter(index: Int) {
        currentChapterIndex = index
        updateInfo()
    }

    func open(query: String, currentChapterIndex: Int) {
        // This entry also opens search from the main menu while this view is hidden.
        guard allowsOpeningResults, let onOpenResultList else { return }
        self.currentChapterIndex = currentChapterIndex
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let canReuseResults = normalizedQuery.isEmpty || normalizedQuery == cachedQuery
        let query = normalizedQuery.isEmpty ? cachedQuery : normalizedQuery
        let snapshot = canReuseResults ? results : []
        let focusedIndex = canReuseResults ? focusedResultIndex : nil
        setVisible(false, currentChapterIndex: currentChapterIndex)
        onOpenResultList(query, snapshot, focusedIndex)
    }

    func restoreResults(
        _ results: [ContentSearchResult],
        selectedIndex: Int,
        query: String?,
        currentChapterIndex: Int,
        options: ReaderContentSearchOptions,
        resultOptions: ReaderContentSearchOptions
    ) {
        resultGeneration &+= 1
        pendingMenuAction = nil
        cancelControlTracking()
        self.options = options
        self.resultOptions = resultOptions
        self.results = results
        self.currentChapterIndex = currentChapterIndex
        selectedResultIndex = results.isEmpty ? -1 : min(max(0, selectedIndex), results.count - 1)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resultQuery = results.first?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cachedQuery = normalizedQuery.isEmpty ? (resultQuery.isEmpty ? nil : resultQuery) : normalizedQuery
        updateControls()
        updateInfo()
    }

    func resetResults(currentChapterIndex: Int) {
        restoreResults(
            [], selectedIndex: -1, query: nil, currentChapterIndex: currentChapterIndex,
            options: .init(), resultOptions: .init())
    }

    private var focusedResultIndex: Int? {
        results.indices.contains(selectedResultIndex) ? selectedResultIndex : nil
    }

    private func configureViews() {
        backgroundColor = .clear
        backgroundButton.backgroundColor = .clear
        backgroundButton.isAccessibilityElement = false
        backgroundButton.addTarget(self, action: #selector(dismissBottomMenu), for: .touchUpInside)
        for view in [backgroundButton, previousResultButton, nextResultButton, bottomPanelScrollView] {
            addSubview(view)
        }

        let arrow = UIImage(named: "ReaderFindAndroidArrow")?.withRenderingMode(.alwaysTemplate)
        previousResultButton.setImage(arrow, for: .normal)
        previousResultButton.imageView?.transform = CGAffineTransform(rotationAngle: .pi)
        nextResultButton.setImage(arrow, for: .normal)
        configureNavigationButton(
            previousResultButton, title: ReaderSearchMenuText.previousResult, action: #selector(openPreviousResult(_:)))
        previousResultButton.accessibilityIdentifier = "reader_find_previous"
        configureNavigationButton(
            nextResultButton, title: ReaderSearchMenuText.nextResult, action: #selector(openNextResult(_:)))
        nextResultButton.accessibilityIdentifier = "reader_find_next"
        previousInfoButton.setImage(ReaderTocAndroidIcon.top.image(), for: .normal)
        nextInfoButton.setImage(ReaderTocAndroidIcon.bottom.image(), for: .normal)
        configureNavigationButton(
            previousInfoButton, title: ReaderSearchMenuText.previousResult, action: #selector(openPreviousResult(_:)))
        previousInfoButton.accessibilityIdentifier = "reader_find_up"
        configureNavigationButton(
            nextInfoButton, title: ReaderSearchMenuText.nextResult, action: #selector(openNextResult(_:)))
        nextInfoButton.accessibilityIdentifier = "reader_find_down"

        bottomPanelScrollView.contentInsetAdjustmentBehavior = .never
        bottomPanelScrollView.bounces = false
        bottomPanelScrollView.showsHorizontalScrollIndicator = false
        bottomPanelScrollView.addSubview(bottomPanel)
        bottomPanel.addSubview(infoRow)
        bottomPanel.addSubview(actionRow)
        for view in [previousInfoButton, nextInfoButton, infoLabel] {
            infoRow.addSubview(view)
        }
        infoLabel.numberOfLines = 1
        infoLabel.adjustsFontForContentSizeCategory = false
        infoLabel.accessibilityIdentifier = "reader_find_info"
        infoLabel.lineBreakMode = .byTruncatingMiddle
        for button in [resultsButton, mainMenuButton, exitButton] {
            actionRow.addSubview(button)
        }
        resultsButton.addTarget(self, action: #selector(openResultList), for: .touchUpInside)
        resultsButton.accessibilityIdentifier = "reader_find_results"
        mainMenuButton.addTarget(self, action: #selector(openMainMenu), for: .touchUpInside)
        mainMenuButton.accessibilityIdentifier = "reader_find_main_menu"
        exitButton.addTarget(self, action: #selector(exitSearch), for: .touchUpInside)
        exitButton.accessibilityIdentifier = "reader_find_exit"
        updateFonts()
        applyPalette()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            center.addObserver(self, selector: #selector(environmentWillDeactivate(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            center.addObserver(self, selector: #selector(environmentDidActivate(_:)), name: name, object: nil)
        }
    }

    private func configureNavigationButton(_ button: UIButton, title: String, action: Selector) {
        button.tintColor = ReaderSearchChromePalette.foreground
        button.adjustsImageWhenHighlighted = false
        button.adjustsImageWhenDisabled = false
        button.accessibilityLabel = title
        button.imageView?.contentMode = .scaleAspectFit
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func updateFonts() {
        infoLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        for button in [resultsButton, mainMenuButton, exitButton] {
            button.applyFont(compatibleWith: traitCollection)
        }
        setNeedsLayout()
    }

    private func updateControls() {
        previousResultButton.isHidden = !hasResults
        nextResultButton.isHidden = !hasResults
        let active = interactionActive && environmentActive && isUserInteractionEnabled && !isHidden
        let bottomActive = active && isBottomMenuVisible && !isBottomMenuTransitioning
        for button in [previousResultButton, nextResultButton] { button.isEnabled = active && hasResults }
        for button in [previousInfoButton, nextInfoButton] { button.isEnabled = bottomActive && hasResults }
        for button in [resultsButton, mainMenuButton, exitButton] { button.isEnabled = bottomActive }
        backgroundButton.isEnabled = bottomActive
        bottomPanelScrollView.isUserInteractionEnabled = bottomActive
        bottomPanelScrollView.accessibilityElementsHidden = !bottomActive
        accessibilityElementsHidden = !active
    }

    private func updateInfo() {
        let text = "搜索结果: \(results.count) / 当前章节: \(displayedChapterTitle)"
        if infoLabel.accessibilityLabel != text {
            infoLabel.text = text
            // ReaderTocSingleLineLabel transforms display text, never the raw chapter title for AX.
            infoLabel.accessibilityLabel = text
            setNeedsLayout()
        }
    }

    private var displayedChapterTitle: String {
        // Like ReadBook.curTextChapter, the owning reader is authoritative after ordinary page turns.
        var responder = next
        while let current = responder {
            if let reader = current as? ReaderContainerViewController {
                return reader.chapterTitle
            }
            responder = current.next
        }
        return results.first(where: { Int($0.chapterIndex) == currentChapterIndex })?.chapterTitle ?? ""
    }

    private func selectResult(at index: Int, sender: UIButton) {
        guard canUseControl(sender), hasResults, let onResultSelected else { return }
        resultGeneration &+= 1
        pendingMenuAction = nil
        selectedResultIndex = min(max(0, index), results.count - 1)
        let result = results[selectedResultIndex]
        currentChapterIndex = Int(result.chapterIndex)
        onResultSelected(result)
        updateInfo()
    }

    @objc private func openPreviousResult(_ sender: UIButton) {
        selectResult(at: selectedResultIndex - 1, sender: sender)
    }

    @objc private func openNextResult(_ sender: UIButton) {
        selectResult(at: selectedResultIndex + 1, sender: sender)
    }

    @objc private func openResultList() {
        guard canUseControl(resultsButton), let onOpenResultList else { return }
        let query = cachedQuery
        let snapshot = results
        let focusedIndex = focusedResultIndex
        hideBottomMenu { [weak self] in
            guard let self else { return }
            self.setVisible(false, currentChapterIndex: self.currentChapterIndex)
            onOpenResultList(query, snapshot, focusedIndex)
        }
    }

    @objc private func openMainMenu() {
        guard canUseControl(mainMenuButton), let onOpenMainMenu else { return }
        hideBottomMenu { [weak self] in
            guard let self else { return }
            self.setVisible(false, currentChapterIndex: self.currentChapterIndex)
            onOpenMainMenu()
        }
    }

    @objc private func exitSearch() {
        guard canUseControl(exitButton), let onExit else { return }
        hideBottomMenu { [weak self] in
            guard let self else { return }
            self.setVisible(false, currentChapterIndex: self.currentChapterIndex)
            onExit()
        }
    }

    @objc private func dismissBottomMenu() {
        guard canUseControl(backgroundButton) else { return }
        hideBottomMenu()
    }

    private func hideBottomMenu(completion: (() -> Void)? = nil) {
        guard allowsInteraction, isBottomMenuVisible, !isBottomMenuTransitioning else { return }
        // The 100% slide-out uses the latest font-dependent viewport height.
        layoutIfNeeded()
        invalidateMenuTransition(preservingPosition: true)
        isBottomMenuVisible = false
        isBottomMenuTransitioning = true
        pendingMenuAction = completion
        backgroundButton.isHidden = true
        let generation = menuAnimationGeneration
        let snapshotGeneration = resultGeneration
        updateControls()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.bottomPanelScrollView.transform = CGAffineTransform(
                translationX: 0, y: self.bottomPanelScrollView.bounds.height)
        } completion: { [weak self] finished in
            guard let self, self.menuAnimationGeneration == generation, !self.isBottomMenuVisible else { return }
            let action = self.pendingMenuAction
            self.pendingMenuAction = nil
            self.isBottomMenuTransitioning = false
            self.bottomPanelScrollView.isHidden = true
            self.bottomPanelScrollView.transform = .identity
            self.updateControls()
            guard finished, self.resultGeneration == snapshotGeneration, self.allowsInteraction else { return }
            action?()
        }
    }

    private var controls: [UIButton] {
        [
            backgroundButton, previousResultButton, nextResultButton, previousInfoButton,
            nextInfoButton, resultsButton, mainMenuButton, exitButton,
        ]
    }

    private var allowsOpeningResults: Bool {
        guard interactionActive, environmentActive, isUserInteractionEnabled, canInteract?() != false,
            let window, UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        var ancestor = superview
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            ancestor = view.superview
        }
        return true
    }

    private var allowsInteraction: Bool {
        allowsOpeningResults && !isHidden && alpha > 0.01
    }

    private func canUseControl(_ button: UIButton) -> Bool {
        guard allowsInteraction, button.isEnabled, button.isDescendant(of: self) else { return false }
        if button !== previousResultButton, button !== nextResultButton {
            guard isBottomMenuVisible, !isBottomMenuTransitioning else { return false }
        }
        var ancestor: UIView? = button
        while let view = ancestor, view !== self {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func cancelControlTracking() {
        for button in controls {
            let enabled = button.isEnabled
            button.isEnabled = false
            button.cancelTracking(with: nil)
            button.isHighlighted = false
            button.isEnabled = enabled
        }
        bottomPanelScrollView.setContentOffset(bottomPanelScrollView.contentOffset, animated: false)
    }

    private func invalidateMenuTransition(preservingPosition: Bool = false) {
        menuAnimationGeneration &+= 1
        pendingMenuAction = nil
        isBottomMenuTransitioning = false
        // Capture before removing animations so runMenuIn can reverse a live runMenuOut.
        let position =
            bottomPanelScrollView.layer.presentation()?.affineTransform()
            ?? bottomPanelScrollView.transform
        bottomPanelScrollView.layer.removeAllAnimations()
        bottomPanelScrollView.transform = preservingPosition ? position : .identity
        cancelControlTracking()
    }

    private func cancelMenuTransition() {
        invalidateMenuTransition()
        bottomPanelScrollView.isHidden = !isBottomMenuVisible
        backgroundButton.isHidden = !isBottomMenuVisible
        updateControls()
    }

    private func updateInteractionAvailability() {
        if !allowsInteraction { cancelMenuTransition() }
        updateControls()
    }

    private func updateEnvironmentAvailability() {
        environmentActive =
            window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
        updateInteractionAvailability()
    }

    @objc private func environmentWillDeactivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        environmentActive = false
        updateInteractionAvailability()
    }

    @objc private func environmentDidActivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        updateEnvironmentAvailability()
    }
}

private class ReaderSearchSelectorButton: UIButton {
    private let pressedView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        pressedView.isUserInteractionEnabled = false
        pressedView.isAccessibilityElement = false
        insertSubview(pressedView, at: 0)
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyPalette() {
        tintColor = ReaderSearchChromePalette.foreground
        setTitleColor(ReaderSearchChromePalette.foreground, for: .normal)
        setTitleColor(ReaderSearchChromePalette.foreground, for: .disabled)
        // AppCompat's borderless selector uses ripple_material_light/dark (#1F/#33).
        pressedView.backgroundColor = AndroidReplicaTheme.activeIndicator
        pressedView.isHidden = !isHighlighted || !isEnabled
    }

    override var isHighlighted: Bool {
        didSet { pressedView.isHidden = !isHighlighted || !isEnabled }
    }

    override var isEnabled: Bool {
        didSet { pressedView.isHidden = !isHighlighted || !isEnabled }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = max(bounds.width, bounds.height)
        pressedView.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        pressedView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        pressedView.layer.cornerRadius = diameter / 2
        sendSubviewToBack(pressedView)
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(x: contentRect.midX - 12, y: contentRect.midY - 12, width: 24, height: 24)
    }
}

private final class ReaderSearchActionButton: ReaderSearchSelectorButton {
    private var textFont = ReaderAndroidDefaultFont.font(size: 12) ?? .systemFont(ofSize: 12)
    private var fontPadding = UIEdgeInsets.zero

    var preferredHeight: CGFloat {
        let scale = max(1, traitCollection.displayScale)
        let lineHeight = max(textFont.lineHeight, titleLabel?.intrinsicContentSize.height ?? 0)
        // TextView wrap_content includes font padding, in addition to the 20/3/7dp chrome.
        return ceil((20 + 3 + lineHeight + fontPadding.top + fontPadding.bottom + 7) * scale) / scale
    }

    init(title: String, image: UIImage?) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setImage(image, for: .normal)
        imageView?.contentMode = .scaleAspectFit
        titleLabel?.numberOfLines = 1
        titleLabel?.textAlignment = .center
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.lineBreakMode = .byTruncatingTail
        applyFont(compatibleWith: traitCollection)
        accessibilityLabel = title
        addInteraction(UIToolTipInteraction(defaultToolTip: title))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFont(compatibleWith traits: UITraitCollection) {
        textFont = ReaderAndroidDefaultFont.scaledFont(size: 12, textStyle: .caption1, compatibleWith: traits)
        fontPadding = AndroidExploreTextMetrics.padding(font: textFont, scale: traits.displayScale)
        titleLabel?.font = textFont
        titleLabel?.adjustsFontForContentSizeCategory = false
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(x: contentRect.midX - 10, y: contentRect.minY, width: 20, height: 20)
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(
            x: contentRect.minX, y: contentRect.minY + 23 + fontPadding.top, width: contentRect.width,
            height: max(0, contentRect.height - 30 - fontPadding.top - fontPadding.bottom))
    }
}

private final class ReaderSearchFloatingButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        layer.cornerRadius = 20
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 2)
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(x: contentRect.midX - 12, y: contentRect.midY - 12, width: 24, height: 24)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { applyPalette() }
    }

    override var isEnabled: Bool {
        didSet { applyPalette() }
    }

    func applyPalette() {
        let pressed = isHighlighted && isEnabled
        tintColor = ReaderSearchChromePalette.foreground
        // Selector only defines default and pressed; disabled retains the default background.
        backgroundColor = pressed ? ReaderSearchChromePalette.pressedBackground : AndroidReplicaTheme.bottomBackground
        layer.shadowRadius = pressed ? 4 : 2
        layer.shadowOffset = CGSize(width: 0, height: pressed ? 4 : 2)
    }
}
