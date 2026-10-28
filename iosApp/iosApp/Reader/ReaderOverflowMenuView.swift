import UIKit

final class ReaderOverflowMenuView: UIView, UIScrollViewDelegate {
    enum Placement { case belowAnchor, automatic }

    struct Item {
        let identifier: String
        let title: String
        let image: UIImage?
        let isChecked: Bool?
        let isEnabled: Bool
        let handler: () -> Void

        init(
            identifier: String, title: String, image: UIImage? = nil, isChecked: Bool? = nil,
            isEnabled: Bool = true, handler: @escaping () -> Void
        ) {
            self.identifier = identifier
            self.title = title
            self.image = image
            self.isChecked = isChecked
            self.isEnabled = isEnabled
            self.handler = handler
        }
    }

    /// Include the book/source/query identity captured when constructing the items.
    var canActivateItem: (() -> Bool)? {
        didSet { if isPresented { revalidatePresentation() } }
    }
    var onDismiss: (() -> Void)?

    private static let rowAction = UIAction.Identifier("reader.popup.row")
    private static let outsideAction = UIAction.Identifier("reader.popup.outside")
    private weak var anchorView: UIView?
    private let items: [Item]
    private let placement: Placement
    private let outsideControl = UIControl()
    private let panelView = UIView()
    private let scrollView = MenuScrollView()
    private var rows: [ReaderOverflowMenuRowView] = []
    private var context: ReaderOverflowPresentationContext?
    private var presentationID: UUID?
    private var presentationTimer: Timer?
    private var lastAnchorRect: CGRect?
    private var isPresented = false
    private var didActivateItem = false

    init(items: [Item], anchorView: UIView, interfaceStyle: UIUserInterfaceStyle, placement: Placement = .automatic) {
        self.items = items
        self.anchorView = anchorView
        self.placement = placement
        super.init(frame: .zero)
        overrideUserInterfaceStyle = interfaceStyle
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        presentationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func present(in host: UIView) {
        guard host !== self, !host.isDescendant(of: self), let anchorView, !items.isEmpty else { return }
        if isPresented {
            guard superview === host else {
                dismiss()
                return
            }
            revalidatePresentation()
            return
        }
        let context = ReaderOverflowPresentationContext(anchor: anchorView, host: host)
        guard context.isCurrent, canActivateItem?() != false else { return }
        self.context = context
        let id = UUID()
        presentationID = id
        didActivateItem = false
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)
        isPresented = true
        isUserInteractionEnabled = true
        accessibilityViewIsModal = true
        scrollView.setContentOffset(.zero, animated: false)
        for row in rows { row.removeFromSuperview() }
        rows = items.map { item in
            let row = ReaderOverflowMenuRowView(item: item)
            scrollView.addSubview(row)
            return row
        }
        applyPalette()
        for (index, row) in rows.enumerated() {
            row.canInteract = { [weak self, weak row] in
                guard let self, let row else { return false }
                return self.canInteract(id: id) && !self.scrollView.isDragging && !self.scrollView.isDecelerating
                    && row.superview === self.scrollView && row.frame.intersects(self.scrollView.bounds)
            }
            row.removeAction(identifiedBy: Self.rowAction, for: .touchUpInside)
            row.addAction(
                UIAction(identifier: Self.rowAction) { [weak self] _ in
                    self?.activateItem(at: index, id: id)
                }, for: .touchUpInside)
        }
        outsideControl.removeAction(identifiedBy: Self.outsideAction, for: .touchUpInside)
        outsideControl.addAction(
            UIAction(identifier: Self.outsideAction) { [weak self] _ in
                guard self?.presentationID == id else { return }
                self?.dismiss()
            }, for: .touchUpInside)
        setNeedsLayout()
        layoutIfNeeded()
        guard isPresented else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidatePresentation() }
        }
        presentationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        UIAccessibility.post(notification: .screenChanged, argument: rows.first(where: { $0.isEnabled }) ?? rows.first)
    }

    func dismiss() { endPresentation(removingView: true) }

    private func endPresentation(removingView: Bool) {
        guard isPresented else { return }
        let restoreFocus = context?.isCurrent == true
        isPresented = false
        presentationID = nil
        context = nil
        lastAnchorRect = nil
        presentationTimer?.invalidate()
        presentationTimer = nil
        isUserInteractionEnabled = false
        accessibilityViewIsModal = false
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        for row in rows {
            row.cancelPendingTracking()
            row.canInteract = { false }
        }
        if removingView { removeFromSuperview() }
        if restoreFocus { UIAccessibility.post(notification: .screenChanged, argument: anchorView) }
        onDismiss?()
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if isPresented, newSuperview !== superview { endPresentation(removingView: false) }
        super.willMove(toSuperview: newSuperview)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if isPresented, newWindow !== window { endPresentation(removingView: false) }
        super.willMove(toWindow: newWindow)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isPresented else { return false }
        dismiss()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        guard isPresented, let anchorView, let host = superview,
            context?.isCurrent == true, canActivateItem?() != false,
            anchorView === host || anchorView.isDescendant(of: host)
        else {
            if isPresented { dismiss() }
            return
        }
        let anchorRect = anchorView.convert(anchorView.bounds, to: self)
        lastAnchorRect = anchorRect
        let safeBounds = bounds.inset(by: safeAreaInsets)
        guard safeBounds.width > 0, safeBounds.height > 0 else {
            dismiss()
            return
        }
        // StandardMenuPopup: minWidth=196dp; cap=max(screenWidth/2, abc_config_prefDialogWidth).
        let maximumWidth = min(safeBounds.width, max(safeBounds.width / 2, 320))
        let preferredWidth = rows.map { $0.preferredWidth(maximum: maximumWidth) }.max() ?? 196
        let width = min(maximumWidth, max(min(196, maximumWidth), preferredWidth))
        var contentHeight: CGFloat = 0
        for row in rows {
            let height = row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            row.frame = CGRect(x: 0, y: contentHeight, width: width, height: height)
            contentHeight += height
        }
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let preferredX = isRTL ? anchorRect.minX : anchorRect.maxX - width
        let x = min(max(preferredX, safeBounds.minX), safeBounds.maxX - width)
        let minimumHeight = min(contentHeight, 48, safeBounds.height)
        let belowY = min(max(anchorRect.maxY, safeBounds.minY), safeBounds.maxY - minimumHeight)
        let belowHeight = max(0, safeBounds.maxY - max(safeBounds.minY, anchorRect.maxY))
        let aboveBottom = min(max(anchorRect.minY, safeBounds.minY), safeBounds.maxY)
        let aboveHeight = max(0, aboveBottom - safeBounds.minY)
        // PopupWindow.tryFitVertical also tries above the anchor before clipping a dropdown.
        let opensAbove = placement == .automatic && belowHeight < min(contentHeight, aboveHeight)
        let height = min(contentHeight, opensAbove ? aboveHeight : safeBounds.maxY - belowY)
        let y = opensAbove ? aboveBottom - height : belowY
        panelView.frame = CGRect(x: x, y: y, width: width, height: height)
        panelView.layer.shadowPath = UIBezierPath(roundedRect: panelView.bounds, cornerRadius: 2).cgPath
        scrollView.frame = panelView.bounds
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        let canScroll = contentHeight > height
        scrollView.isScrollEnabled = canScroll
        scrollView.showsVerticalScrollIndicator = canScroll
        let offset = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height))
        if scrollView.contentOffset != CGPoint(x: 0, y: offset) {
            scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyPalette()
        setNeedsLayout()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        for row in rows { row.cancelPendingTracking() }
    }

    private func canInteract(id: UUID) -> Bool {
        isPresented && !didActivateItem && presentationID == id && context?.isCurrent == true
            && canActivateItem?() != false
    }

    private func revalidatePresentation() {
        guard isPresented else { return }
        guard let id = presentationID, canInteract(id: id) else {
            dismiss()
            return
        }
        if let anchorView, lastAnchorRect != anchorView.convert(anchorView.bounds, to: self) { setNeedsLayout() }
    }

    private func configureViews() {
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "reader.overflowMenu"
        isAccessibilityElement = false
        outsideControl.backgroundColor = .clear
        outsideControl.isAccessibilityElement = true
        outsideControl.accessibilityIdentifier = "reader.overflowMenu.dismiss"
        outsideControl.accessibilityLabel = L10n.Common.cancel
        outsideControl.accessibilityTraits = .button
        addSubview(outsideControl)
        panelView.accessibilityIdentifier = "reader.overflowMenu.panel"
        panelView.layer.cornerRadius = 2
        panelView.layer.shadowColor = UIColor.black.cgColor
        panelView.layer.shadowOpacity = 0.22
        panelView.layer.shadowRadius = 6
        panelView.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(panelView)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.clipsToBounds = true
        scrollView.layer.cornerRadius = 2
        scrollView.delegate = self
        panelView.addSubview(scrollView)
        accessibilityElements = [scrollView, outsideControl]
        applyPalette()
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)), name: name, object: nil)
        }
    }

    private func applyPalette() {
        let style =
            overrideUserInterfaceStyle == .unspecified ? traitCollection.userInterfaceStyle : overrideUserInterfaceStyle
        let appearance = ReaderOverflowMenuAppearance(isDark: style == .dark)
        panelView.backgroundColor = appearance.background
        scrollView.indicatorStyle = style == .dark ? .white : .black
        for row in rows { row.apply(appearance) }
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        dismiss()
    }

    private func activateItem(at index: Int, id: UUID) {
        guard items.indices.contains(index), items[index].isEnabled, canInteract(id: id),
            !scrollView.isDragging, !scrollView.isDecelerating
        else { return }
        didActivateItem = true
        let handler = items[index].handler
        let context = context
        dismiss()
        // onDismiss can synchronously navigate or present a replacement; never leak the old action.
        guard context?.isCurrent == true else { return }
        handler()
    }

    private final class MenuScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            view is UIControl || super.touchesShouldCancel(in: view)
        }
    }
}
