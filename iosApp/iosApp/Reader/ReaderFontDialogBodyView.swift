import UIKit

/// FontSelectDialog's flat surface, toolbar, list and single-item overflow.
@MainActor
final class ReaderFontDialogBodyView: UIView {
    var onCancel: (() -> Void)?
    var onDefaults: (() -> Void)?
    var onDirectory: (() -> Void)?
    var onRetry: (() -> Void)?
    var onWindowChange: (() -> Void)?
    /// Synchronous; true suspends list selection/preview, false restores the owner's current state.
    var onMenuVisibilityChange: ((Bool) -> Void)?

    let tableView = UITableView(frame: .zero, style: .plain)
    let titleLabel = UILabel()
    let moreButton = UIButton(type: .system)
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let toolbarScrollView = ReaderFontControlScrollView()
    private let toolbar = UIView()
    private let defaultButton = UIButton(type: .system)
    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private let statusView = UIView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var overflowMenu: ReaderOverflowMenuView?
    private(set) var isMenuVisible = false
    private var shouldRevealStatus = false
    private var controlsEnabled = false
    private var cancellationEnabled = false
    private var showsDefaultInOverflow = false
    private var menuGeneration: UInt64 = 0
    private var dismissedMenuGeneration: UInt64?

    private enum OverflowAction { case defaults, directory }

    private static let toolbarForeground = UIColor { traits in
        // BaseActivity selects the AppCompat toolbar overlay by primaryColor luminance.
        ReaderSearchChromePalette.foreground(on: AndroidReplicaTheme.toolbarBackground, traits: traits)
    }

    private static let toolbarSecondary = UIColor { traits in
        let foreground = toolbarForeground.resolvedColor(with: traits)
        return foreground.withAlphaComponent(foreground.cgColor.alpha < 1 ? 138.0 / 255 : 179.0 / 255)
    }

    var textColor: UIColor { AndroidReplicaTheme.primaryText }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHidden: Bool {
        didSet { if isHidden { hideMenu(restoreFocus: false) } }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { hideMenu(restoreFocus: false) } }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { hideMenu(restoreFocus: false) }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    func applyAppearance() {
        // FontSelectDialog uses the app theme, independent of the book's paper/style.
        dialogView.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        toolbarScrollView.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.textColor = Self.toolbarForeground
        defaultButton.tintColor = Self.toolbarForeground
        defaultButton.setTitleColor(Self.toolbarForeground, for: .normal)
        moreButton.tintColor = Self.toolbarSecondary
        busyIndicator.color = Self.toolbarSecondary
        statusLabel.textColor = textColor
        retryButton.tintColor = textColor
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let actionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        defaultButton.titleLabel?.font = actionFont
        retryButton.titleLabel?.font = actionFont
        statusLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        setNeedsLayout()
    }

    func setState(enabled: Bool, busy: Bool, canCancel: Bool, message: String?, retryVisible: Bool) {
        controlsEnabled = enabled && !busy
        cancellationEnabled = canCancel
        if !controlsEnabled { hideMenu(restoreFocus: false) }
        for button in [defaultButton, moreButton, retryButton] { button.isEnabled = controlsEnabled }
        updateListInteraction()
        outsideControl.isEnabled = canCancel
        moreButton.imageView?.isHidden = busy
        moreButton.isAccessibilityElement = !busy
        busyIndicator.isAccessibilityElement = busy
        if busy { busyIndicator.startAnimating() } else { busyIndicator.stopAnimating() }
        statusLabel.text = message
        statusLabel.isHidden = message == nil
        retryButton.isHidden = !retryVisible
        setNeedsLayout()
    }

    func revealStatusOnNextLayout() {
        shouldRevealStatus = true
        setNeedsLayout()
    }

    func showMenu() {
        guard !isMenuVisible, controlsEnabled, moreButton.isEnabled, isHostAvailable else { return }
        setNeedsLayout()
        layoutIfNeeded()
        menuGeneration &+= 1
        let generation = menuGeneration
        dismissedMenuGeneration = nil
        var items: [ReaderOverflowMenuView.Item] = []
        if showsDefaultInOverflow {
            items.append(
                .init(identifier: "reader.font.default", title: L10n.ReaderAppearance.fontDefault) { [weak self] in
                    self?.activateMenuItem(.defaults, generation: generation)
                })
        }
        items.append(
            .init(identifier: "reader.font.otherDirectory", title: "其它目录") { [weak self] in
                self?.activateMenuItem(.directory, generation: generation)
            })
        let menu = ReaderOverflowMenuView(items: items, anchorView: moreButton, interfaceStyle: .unspecified)
        menu.onDismiss = { [weak self, weak menu] in
            guard let self, let menu, self.overflowMenu === menu, self.menuGeneration == generation else { return }
            self.overflowMenu = nil
            self.dismissedMenuGeneration = generation
            self.setMenuVisibility(false)
            // Overflow dismisses before invoking the item. Expire that synchronous
            // handoff so a retained handler cannot perform a later directory action.
            DispatchQueue.main.async { [weak self] in
                guard self?.dismissedMenuGeneration == generation else { return }
                self?.dismissedMenuGeneration = nil
            }
        }
        overflowMenu = menu
        setMenuVisibility(true)
        guard menuGeneration == generation, overflowMenu === menu, controlsEnabled, isHostAvailable else {
            if overflowMenu === menu { hideMenu(restoreFocus: false) }
            return
        }
        menu.present(in: self)
    }

    func hideMenu(restoreFocus: Bool) {
        menuGeneration &+= 1
        let generation = menuGeneration
        dismissedMenuGeneration = nil
        let menu = overflowMenu
        overflowMenu = nil
        menu?.onDismiss = nil
        // Suppress the shared menu's automatic focus restoration on owner close/busy.
        menu?.removeFromSuperview()
        menu?.dismiss()
        let wasVisible = isMenuVisible
        setMenuVisibility(false)
        if wasVisible, restoreFocus, menuGeneration == generation, !isMenuVisible,
            controlsEnabled, isHostAvailable
        {
            UIAccessibility.post(notification: .screenChanged, argument: moreButton)
        }
    }

    private func setMenuVisibility(_ visible: Bool) {
        guard isMenuVisible != visible else { return }
        isMenuVisible = visible
        dialogView.accessibilityElementsHidden = visible
        updateListInteraction()
        onMenuVisibilityChange?(visible)
    }

    private func updateListInteraction() {
        let enabled = controlsEnabled && !isMenuVisible
        tableView.allowsSelection = enabled
        tableView.isUserInteractionEnabled = enabled
        for case let cell as ReaderFontListCell in tableView.visibleCells { cell.setInteractionEnabled(enabled) }
    }

    private func activateMenuItem(_ action: OverflowAction, generation: UInt64) {
        guard menuGeneration == generation, dismissedMenuGeneration == generation,
            !isMenuVisible, overflowMenu == nil, controlsEnabled, isHostAvailable
        else { return }
        menuGeneration &+= 1
        dismissedMenuGeneration = nil
        switch action {
        case .defaults: onDefaults?()
        case .directory: onDirectory?()
        }
    }

    private var isHostAvailable: Bool {
        guard window?.isKeyWindow == true, window?.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            ancestor = view.superview
        }
        var responder = next
        while let current = responder {
            if let owner = current as? UIViewController {
                return !owner.isBeingDismissed && !owner.isBeingPresented && !owner.isMovingFromParent
                    && owner.presentedViewController == nil
            }
            responder = current.next
        }
        return false
    }

    @objc private func environmentWillDeactivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        if let notificationWindow = notification.object as? UIWindow, notificationWindow !== window { return }
        hideMenu(restoreFocus: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        let safe = safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        // setLayout(.9, .9) retains the Android window background's 16dp insets.
        let width = min(safe.width, max(1, bounds.width * 0.9 - 32))
        let height = min(safe.height, max(1, bounds.height * 0.9 - 32))
        dialogView.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        let toolbarHeight = layoutToolbar(width: width)
        let viewport = min(toolbarHeight, max(0, height - min(44, height / 2)))
        toolbarScrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewport)
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        toolbarScrollView.contentSize = toolbar.bounds.size
        toolbarScrollView.isScrollEnabled = toolbarHeight > viewport
        clampOffset(of: toolbarScrollView)
        tableView.frame = CGRect(x: 0, y: viewport, width: width, height: height - viewport)
        layoutStatus()
        overflowMenu?.setNeedsLayout()
    }

    private func configureViews() {
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        accessibilityViewIsModal = true
        accessibilityIdentifier = "reader.font.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.clipsToBounds = true
        titleLabel.text = L10n.ReaderAppearance.fontSelectTitle
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.font.title"
        configureTextButton(defaultButton, title: L10n.ReaderAppearance.fontDefault)
        defaultButton.titleLabel?.numberOfLines = 1
        defaultButton.titleLabel?.lineBreakMode = .byTruncatingTail
        defaultButton.accessibilityIdentifier = "reader.font.default"
        defaultButton.addTarget(self, action: #selector(defaults), for: .touchUpInside)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        moreButton.imageView?.contentMode = .center
        moreButton.accessibilityLabel = L10n.Reader.menuMore
        moreButton.accessibilityHint = "其它目录"
        moreButton.accessibilityIdentifier = "reader.font.more"
        moreButton.addTarget(self, action: #selector(showOverflow), for: .touchUpInside)
        busyIndicator.hidesWhenStopped = true
        busyIndicator.accessibilityLabel = L10n.Common.loadingTitle
        for scrollView in [toolbarScrollView] {
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            scrollView.delaysContentTouches = false
            scrollView.canCancelContentTouches = true
            scrollView.scrollsToTop = false
        }
        tableView.register(ReaderFontListCell.self, forCellReuseIdentifier: ReaderFontListCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.alwaysBounceVertical = false
        tableView.scrollsToTop = false
        tableView.accessibilityIdentifier = "reader.font.list"
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byCharWrapping
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "reader.font.status"
        configureTextButton(retryButton, title: L10n.Common.retry)
        retryButton.accessibilityIdentifier = "reader.font.retry"
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        statusView.addSubview(statusLabel)
        statusView.addSubview(retryButton)
        addSubview(outsideControl)
        addSubview(dialogView)
        dialogView.addSubview(toolbarScrollView)
        toolbarScrollView.addSubview(toolbar)
        for item in [titleLabel, defaultButton, moreButton, busyIndicator] { toolbar.addSubview(item) }
        dialogView.addSubview(tableView)
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentWillDeactivate(_:)), name: name, object: nil)
        }
    }

    private func configureTextButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byCharWrapping
        button.titleLabel?.textAlignment = .center
    }

    private func layoutToolbar(width: CGFloat) -> CGFloat {
        let unlimited = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let titleSize = titleLabel.sizeThatFits(unlimited)
        let actionSize = defaultButton.titleLabel?.sizeThatFits(unlimited) ?? .zero
        // Toolbar + ActionMenuView: 56dp bar, 56dp minimum text action, 24+6+10 overflow.
        let actionWidth = max(56, ceil(actionSize.width) + 16)
        let iconWidth = min(40, width)
        let inset = min(16, max(0, width - iconWidth))
        let defaultInOverflow = titleSize.width + inset + actionWidth + iconWidth > width
        if showsDefaultInOverflow != defaultInOverflow {
            showsDefaultInOverflow = defaultInOverflow
            hideMenu(restoreFocus: true)
        }
        let displayedActionWidth = defaultInOverflow ? 0 : actionWidth
        let titleWidth = max(0, width - inset - displayedActionWidth - iconWidth)
        let height = max(56, ceil(max(titleSize.height, defaultInOverflow ? 0 : actionSize.height)) + 16)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func slot(leading: CGFloat, width itemWidth: CGFloat) -> CGRect {
            CGRect(x: isRTL ? width - leading - itemWidth : leading, y: 0, width: itemWidth, height: height)
        }
        titleLabel.frame = slot(leading: inset, width: titleWidth).insetBy(dx: 0, dy: 8)
        defaultButton.isHidden = defaultInOverflow
        defaultButton.frame = slot(leading: width - iconWidth - displayedActionWidth, width: displayedActionWidth)
        moreButton.frame = slot(leading: width - iconWidth, width: iconWidth)
        moreButton.contentEdgeInsets = UIEdgeInsets(
            top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
        moreButton.accessibilityHint = defaultInOverflow ? "\(L10n.ReaderAppearance.fontDefault)、其它目录" : "其它目录"
        busyIndicator.center = moreButton.center
        return height
    }

    private func layoutStatus() {
        guard !statusLabel.isHidden || !retryButton.isHidden else {
            tableView.tableFooterView = nil
            return
        }
        let width = tableView.bounds.width
        let textWidth = max(1, width - 32)
        let labelHeight =
            statusLabel.isHidden
            ? 0
            : ceil(
                statusLabel.sizeThatFits(
                    CGSize(width: textWidth, height: .greatestFiniteMagnitude)
                ).height)
        let retryHeight =
            retryButton.isHidden
            ? 0
            : max(
                44,
                ceil(
                    retryButton.titleLabel?.sizeThatFits(
                        CGSize(width: textWidth, height: .greatestFiniteMagnitude)
                    ).height ?? 0) + 16)
        let gap: CGFloat = labelHeight > 0 && retryHeight > 0 ? 8 : 0
        let contentHeight = labelHeight + gap + retryHeight
        let height = max(tableView.numberOfRows(inSection: 0) == 0 ? tableView.bounds.height : 0, contentHeight + 32)
        let size = CGSize(width: width, height: height)
        let needsAssignment = tableView.tableFooterView !== statusView || statusView.bounds.size != size
        statusView.frame = CGRect(origin: statusView.frame.origin, size: size)
        statusLabel.frame = CGRect(x: 16, y: (height - contentHeight) / 2, width: textWidth, height: labelHeight)
        retryButton.frame = CGRect(x: 16, y: statusLabel.frame.maxY + gap, width: textWidth, height: retryHeight)
        if needsAssignment { tableView.tableFooterView = statusView }
        if shouldRevealStatus {
            shouldRevealStatus = false
            tableView.layoutIfNeeded()
            let maximum = max(0, tableView.contentSize.height - tableView.bounds.height)
            let top = max(0, tableView.contentSize.height - statusView.bounds.height)
            tableView.setContentOffset(CGPoint(x: 0, y: min(top, maximum)), animated: false)
            if window?.isKeyWindow == true, window?.windowScene?.activationState == .foregroundActive,
                controlsEnabled, !isMenuVisible
            {
                UIAccessibility.post(notification: .layoutChanged, argument: statusLabel)
            }
        }
    }

    private func clampOffset(of scrollView: UIScrollView) {
        let y = min(max(0, scrollView.contentOffset.y), max(0, scrollView.contentSize.height - scrollView.bounds.height))
        if scrollView.contentOffset != CGPoint(x: 0, y: y) { scrollView.contentOffset = CGPoint(x: 0, y: y) }
    }

    @objc private func cancel() {
        if isMenuVisible {
            hideMenu(restoreFocus: true)
            return
        }
        guard cancellationEnabled, isHostAvailable else { return }
        hideMenu(restoreFocus: false)
        onCancel?()
    }

    @objc private func defaults() {
        guard controlsEnabled, defaultButton.isEnabled, !defaultButton.isHidden,
            !isMenuVisible, isHostAvailable
        else { return }
        onDefaults?()
    }

    @objc private func retry() {
        guard controlsEnabled, retryButton.isEnabled, !retryButton.isHidden,
            !isMenuVisible, isHostAvailable
        else { return }
        onRetry?()
    }

    @objc private func showOverflow() {
        showMenu()
    }
}

private final class ReaderFontControlScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
