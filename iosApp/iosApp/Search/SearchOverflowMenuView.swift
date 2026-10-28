import UIKit

final class SearchOverflowMenuView: UIView, UIScrollViewDelegate {
    enum Selection: Equatable {
        case none
        case checkbox
        case radio
    }

    struct Item {
        let id: String
        let title: String
        let selection: Selection
        let isSelected: Bool

        init(id: String, title: String, selection: Selection = .none, isSelected: Bool = false) {
            self.id = id
            self.title = title
            self.selection = selection
            self.isSelected = isSelected
        }
    }

    private enum Metrics {
        // AppCompat 1.7.1 popup rows; legado 5f5d31404 uses 16sp menu titles.
        static let minimumRowHeight: CGFloat = 48
        static let minimumWidth: CGFloat = 196
        static let preferredDialogWidth: CGFloat = 320
        static let horizontalPadding: CGFloat = 16
        static let indicatorWidth: CGFloat = 32
        static let fontSize: CGFloat = 16
        static let verticalPadding: CGFloat = 8
        static let touchSlop: CGFloat = 8
        static let cornerRadius: CGFloat = 2
    }

    var canActivateItem: (() -> Bool)? {
        didSet {
            for row in rows { row.cancelPendingTracking() }
            if isPresented { refreshPresentation() }
        }
    }
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isPresented = false

    private static let outsideAction = UIAction.Identifier("search.popup.outside")
    private weak var hostView: UIView?
    private weak var anchorView: UIView?
    private let outsideControl = UIControl()
    private let panelView = UIView()
    private let scrollView = MenuScrollView()
    private var items: [Item] = []
    private var rows: [Row] = []
    private var onSelect: ((String) -> Void)?
    private var context: ReaderOverflowPresentationContext?
    private var presentationID: UUID?
    private var presentationRevision: UInt64 = 0
    private var didNotifyPresentation = false
    private var didActivateItem = false
    private var displayLink: CADisplayLink?
    private var lastAnchorRect = CGRect.null
    private var lastSafeBounds = CGRect.null

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func show(in host: UIView, anchor: UIView, items: [Item], onSelect: @escaping (String) -> Void) {
        let revision = presentationRevision &+ 1
        dismiss()
        guard presentationRevision == revision,
            host !== self, !host.isDescendant(of: self),
            anchor !== self, !anchor.isDescendant(of: self),
            anchor === host || anchor.isDescendant(of: host), !items.isEmpty
        else { return }

        // Content pauses the toolbar while the popup owns input. Use the root as the
        // context's logical anchor; the real anchor supplies geometry/visibility only.
        let context = ReaderOverflowPresentationContext(anchor: host, host: host)
        guard context.isCurrent, canActivateItem?() != false else { return }
        host.layoutIfNeeded()
        let id = UUID()
        presentationID = id
        self.context = context
        hostView = host
        anchorView = anchor
        updateLayoutDirection(from: anchor)
        self.items = items
        self.onSelect = onSelect
        didActivateItem = false
        lastAnchorRect = .null
        lastSafeBounds = .null
        rows = items.enumerated().map { index, item in
            let row = Row(item: item)
            row.canInteract = { [weak self, weak row] in
                guard let self, let row else { return false }
                return self.canInteract(id: id) && !self.isScrolling
                    && row.superview === self.scrollView && row.frame.intersects(self.scrollView.bounds)
            }
            row.addAction(UIAction { [weak self] _ in self?.activateItem(at: index, id: id) }, for: .touchUpInside)
            scrollView.addSubview(row)
            return row
        }
        outsideControl.addAction(
            UIAction(identifier: Self.outsideAction) { [weak self] _ in
                guard let self, self.presentationID == id else { return }
                self.dismiss()
            }, for: .touchUpInside)
        scrollView.setContentOffset(.zero, animated: false)
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)
        isPresented = true
        isHidden = false
        isUserInteractionEnabled = true
        accessibilityViewIsModal = true
        applyPalette()
        setNeedsLayout()
        layoutIfNeeded()
        guard presentationID == id, isPresented, window != nil else { return }
        startMonitoring()
        didNotifyPresentation = true
        onVisibilityChange?(true)
        guard presentationID == id, isPresented else { return }
        guard presentationIsValid() else {
            dismiss()
            return
        }
        UIAccessibility.post(notification: .screenChanged, argument: rows.first)
    }

    func dismiss() {
        presentationRevision &+= 1
        endPresentation(removingView: true)
    }

    func refreshAppearance(interfaceStyle: UIUserInterfaceStyle? = nil) {
        if let interfaceStyle, overrideUserInterfaceStyle != interfaceStyle {
            overrideUserInterfaceStyle = interfaceStyle
        }
        // A same-style palette refresh must retain rows, AX focus and the scroll offset.
        applyPalette()
    }

    private func endPresentation(removingView: Bool) {
        guard isPresented else { return }
        let anchor = anchorView
        let context = context
        let shouldRestoreFocus = presentationIsValid()
        let shouldNotify = didNotifyPresentation
        resetPresentation()
        let revision = presentationRevision
        if removingView { removeFromSuperview() }
        if shouldNotify { onVisibilityChange?(false) }
        if shouldRestoreFocus, context?.isCurrent == true,
            presentationID == nil, presentationRevision == revision
        {
            UIAccessibility.post(notification: .screenChanged, argument: anchor)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isPresented else { return false }
        dismiss()
        return true
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if isPresented, newSuperview !== hostView {
            presentationRevision &+= 1
            endPresentation(removingView: false)
        }
        super.willMove(toSuperview: newSuperview)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if isPresented, newWindow !== window {
            presentationRevision &+= 1
            endPresentation(removingView: false)
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard isPresented else { return }
        if window == nil {
            dismiss()
        } else {
            startMonitoring()
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isPresented else { return }
        guard presentationIsValid(), let anchorView else {
            dismiss()
            return
        }
        outsideControl.frame = bounds
        let anchorRect = anchorView.convert(anchorView.bounds, to: self)
        let safeBounds = bounds.inset(by: safeAreaInsets)
        guard safeBounds.width > 0, safeBounds.height > 0, bounds.intersects(anchorRect) else {
            dismiss()
            return
        }
        lastAnchorRect = anchorRect
        lastSafeBounds = safeBounds
        updateLayoutDirection(from: anchorView)
        // StandardMenuPopup measures content, capped by max(screenWidth / 2, prefDialogWidth).
        let maximumWidth = min(safeBounds.width, max(safeBounds.width / 2, Metrics.preferredDialogWidth))
        let naturalWidth = rows.map(\.preferredWidth).max() ?? Metrics.minimumWidth
        let width = min(max(Metrics.minimumWidth, ceil(naturalWidth)), maximumWidth)
        var contentHeight: CGFloat = 0
        for row in rows {
            let height = row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let frame = CGRect(x: 0, y: contentHeight, width: width, height: height)
            if row.frame != frame { row.cancelPendingTracking() }
            row.frame = frame
            contentHeight += height
        }
        let minimumHeight = min(Metrics.minimumRowHeight, safeBounds.height)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let preferredX = isRTL ? anchorRect.minX : anchorRect.maxX - width
        let x = min(max(preferredX, safeBounds.minX), safeBounds.maxX - width)
        // The Android search popup opens near the overflow button's vertical center.
        // Clamp upward in short windows without shrinking individual rows.
        let y = min(max(anchorRect.midY, safeBounds.minY), safeBounds.maxY - minimumHeight)
        let height = min(contentHeight, safeBounds.maxY - y)
        let panelFrame = CGRect(x: x, y: y, width: width, height: height)
        if panelView.frame != panelFrame {
            for row in rows { row.cancelPendingTracking() }
        }
        panelView.frame = panelFrame
        panelView.layer.shadowPath =
            UIBezierPath(
                roundedRect: panelView.bounds, cornerRadius: Metrics.cornerRadius
            ).cgPath
        scrollView.frame = panelView.bounds
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        scrollView.isScrollEnabled = contentHeight > height
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        let offsetY = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height))
        if scrollView.contentOffset != CGPoint(x: 0, y: offsetY) {
            scrollView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
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

    private func configureViews() {
        backgroundColor = .clear
        isOpaque = false
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = "search.overflowMenu"

        outsideControl.backgroundColor = .clear
        outsideControl.isAccessibilityElement = true
        outsideControl.accessibilityIdentifier = "search.overflowMenu.dismiss"
        outsideControl.accessibilityLabel = L10n.Common.cancel
        outsideControl.accessibilityTraits = .button
        addSubview(outsideControl)

        panelView.accessibilityIdentifier = "search.overflowMenu.panel"
        panelView.layer.cornerRadius = Metrics.cornerRadius
        panelView.layer.shadowColor = UIColor.black.cgColor
        panelView.layer.shadowOpacity = 0.22
        panelView.layer.shadowRadius = 6
        panelView.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(panelView)

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.clipsToBounds = true
        scrollView.layer.cornerRadius = Metrics.cornerRadius
        scrollView.delegate = self
        panelView.addSubview(scrollView)
        accessibilityElements = [scrollView, outsideControl]
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)), name: name, object: nil)
        }
    }

    private func applyPalette() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let palette = ReaderOverflowMenuAppearance(isDark: isDark)
        panelView.backgroundColor = palette.background
        scrollView.indicatorStyle = isDark ? .white : .black
        for row in rows { row.apply(palette) }
    }

    private func presentationIsValid() -> Bool {
        guard context?.isCurrent == true, canActivateItem?() != false,
            let hostView, let anchorView, superview === hostView,
            hostView.subviews.last === self,
            anchorView === hostView || anchorView.isDescendant(of: hostView),
            anchorView.window === window, anchorIsVisible(anchorView)
        else { return false }
        var view: UIView? = self
        var opacity: CGFloat = 1
        while let current = view {
            opacity *= current.alpha
            if current.isHidden || opacity <= 0.01 || !current.isUserInteractionEnabled
                || current.accessibilityElementsHidden
            {
                return false
            }
            view = current.superview
        }
        return true
    }

    private func anchorIsVisible(_ anchor: UIView) -> Bool {
        guard let window, anchor.window === window, !anchor.bounds.isEmpty else { return false }
        var visibleRect = anchor.convert(anchor.bounds, to: window).intersection(window.bounds)
        var opacity: CGFloat = 1
        var ancestor: UIView? = anchor
        while let view = ancestor {
            opacity *= view.alpha
            // A paused toolbar may be disabled, non-interactive and AX-hidden without
            // invalidating its popup. Hidden/detached/clipped anchors still invalidate it.
            guard !view.isHidden, opacity > 0.01 else { return false }
            if view.clipsToBounds { visibleRect = visibleRect.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        return !visibleRect.isNull && !visibleRect.isEmpty
            && visibleRect.minX.isFinite && visibleRect.minY.isFinite
            && visibleRect.width.isFinite && visibleRect.height.isFinite
    }

    private func startMonitoring() {
        guard displayLink == nil, isPresented, window != nil else { return }
        let target = DisplayLinkTarget(menu: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.refresh(_:)))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func refreshPresentation() {
        guard isPresented else { return }
        guard presentationIsValid(), let hostView, let anchorView else {
            dismiss()
            return
        }
        // A host reorder or independently moving toolbar need not lay out this overlay.
        if frame != hostView.bounds { frame = hostView.bounds }
        updateLayoutDirection(from: anchorView)
        let anchorRect = anchorView.convert(anchorView.bounds, to: self)
        if anchorRect != lastAnchorRect || bounds.inset(by: safeAreaInsets) != lastSafeBounds {
            setNeedsLayout()
        }
        layoutIfNeeded()
        guard isPresented else { return }
        if let window, !panelView.bounds.isEmpty {
            let point = panelView.convert(CGPoint(x: panelView.bounds.midX, y: panelView.bounds.midY), to: window)
            guard let hit = window.hitTest(point, with: nil), hit === self || hit.isDescendant(of: self) else {
                dismiss()
                return
            }
        }
    }

    private func resetPresentation() {
        isPresented = false
        presentationID = nil
        didNotifyPresentation = false
        isHidden = true
        isUserInteractionEnabled = false
        accessibilityViewIsModal = false
        displayLink?.invalidate()
        displayLink = nil
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        for row in rows {
            row.cancelPendingTracking()
            row.canInteract = nil
            row.removeFromSuperview()
        }
        rows = []
        outsideControl.cancelTracking(with: nil)
        outsideControl.removeAction(identifiedBy: Self.outsideAction, for: .touchUpInside)
        onSelect = nil
        items = []
        context = nil
        anchorView = nil
        hostView = nil
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        dismiss()
    }

    private func updateLayoutDirection(from anchor: UIView) {
        let attribute: UISemanticContentAttribute =
            anchor.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        guard semanticContentAttribute != attribute else { return }
        for row in rows { row.cancelPendingTracking() }
        semanticContentAttribute = attribute
        setNeedsLayout()
    }

    private var isScrolling: Bool {
        let state = scrollView.panGestureRecognizer.state
        return scrollView.isDragging || scrollView.isDecelerating || state == .began || state == .changed
    }

    private func canInteract(id: UUID) -> Bool {
        isPresented && !didActivateItem && presentationID == id && presentationIsValid()
    }

    private func activateItem(at index: Int, id: UUID) {
        guard canInteract(id: id), !isScrolling, items.indices.contains(index) else { return }
        didActivateItem = true
        let action = items[index].id
        let handler = onSelect
        let context = context
        let canActivate = canActivateItem
        let revision = presentationRevision &+ 1
        dismiss()
        // Visibility observers may synchronously navigate or present a replacement menu.
        guard presentationID == nil, presentationRevision == revision,
            context?.isCurrent == true, canActivate?() != false
        else { return }
        handler?(action)
    }

    private final class DisplayLinkTarget: NSObject {
        weak var menu: SearchOverflowMenuView?

        init(menu: SearchOverflowMenuView) {
            self.menu = menu
        }

        @objc func refresh(_ link: CADisplayLink) {
            guard let menu else {
                link.invalidate()
                return
            }
            menu.refreshPresentation()
        }
    }

    private final class MenuScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            view is UIControl || super.touchesShouldCancel(in: view)
        }
    }

    private final class Row: UIControl {
        var canInteract: (() -> Bool)? {
            didSet { cancelPendingTracking() }
        }

        private struct TouchInteraction {
            let touch: UITouch
            let revision: UInt64
            let origin: CGPoint
            let rowRect: CGRect
        }

        private let titleLabel = UILabel()
        private let indicatorView: UIImageView?
        private let itemSelected: Bool
        private var highlightColor = UIColor.clear
        private var revision: UInt64 = 0
        private var interaction: TouchInteraction?
        private var hasActivated = false
        private var dispatchRevision: UInt64?
        private var isSendingActions = false
        private var isCancellingInteraction = false
        private var hasReceivedAccessibilityFocus = false
        private var accessibilityFocusRevision: UInt64?

        var preferredWidth: CGFloat {
            let titleWidth = titleLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width
            return ceil(titleWidth) + horizontalChromeWidth
        }

        override var isHighlighted: Bool {
            didSet { backgroundColor = isHighlighted ? highlightColor : .clear }
        }

        init(item: Item) {
            itemSelected = item.isSelected
            switch item.selection {
            case .none:
                indicatorView = nil
            case .checkbox:
                indicatorView = ReaderOverflowMenuCheckView(isChecked: item.isSelected)
            case .radio:
                let name = item.isSelected ? "SearchScopeAndroidRadioOn" : "SearchScopeAndroidRadioOff"
                indicatorView = UIImageView(image: UIImage(named: name)?.withRenderingMode(.alwaysTemplate))
            }
            super.init(frame: .zero)
            isMultipleTouchEnabled = false
            clipsToBounds = true
            isAccessibilityElement = true
            accessibilityIdentifier = "search.more.\(item.id)"
            accessibilityLabel = item.title
            accessibilityTraits = .button
            if item.selection != .none {
                accessibilityValue =
                    item.isSelected
                    ? NSLocalizedString("search.more.selected", value: "已选中", comment: "Selected menu option")
                    : NSLocalizedString("search.more.notSelected", value: "未选中", comment: "Unselected menu option")
                if item.isSelected { accessibilityTraits.insert(.selected) }
            }

            titleLabel.text = item.title
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.adjustsFontSizeToFitWidth = false
            titleLabel.textAlignment = .natural
            titleLabel.isAccessibilityElement = false
            titleLabel.isUserInteractionEnabled = false
            addSubview(titleLabel)

            if let indicatorView {
                indicatorView.isUserInteractionEnabled = false
                indicatorView.isAccessibilityElement = false
                indicatorView.accessibilityElementsHidden = true
                indicatorView.contentMode = .scaleAspectFit
                addSubview(indicatorView)
            }
            updateTypography()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            preconditionFailure("init(coder:) is unavailable")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let layout = horizontalLayout(width: bounds.width)
            let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
            titleLabel.textAlignment = isRTL ? .right : .left
            titleLabel.frame = CGRect(
                x: bounds.minX + layout.padding + (isRTL ? layout.indicatorWidth : 0),
                y: bounds.minY + Metrics.verticalPadding,
                width: layout.textWidth, height: max(0, bounds.height - Metrics.verticalPadding * 2)
            )
            indicatorView?.frame = CGRect(
                x: bounds.minX + (isRTL ? layout.padding : bounds.width - layout.padding - layout.indicatorWidth),
                y: bounds.midY - layout.indicatorWidth / 2,
                width: layout.indicatorWidth, height: layout.indicatorWidth
            )
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let width = size.width.isFinite ? max(0, size.width) : preferredWidth
            let layout = horizontalLayout(width: width)
            let textHeight = titleLabel.sizeThatFits(
                CGSize(width: max(1, layout.textWidth), height: CGFloat.greatestFiniteMagnitude)
            ).height
            return CGSize(
                width: width,
                height: max(Metrics.minimumRowHeight, ceil(textHeight) + Metrics.verticalPadding * 2))
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
                || previousTraitCollection?.layoutDirection != traitCollection.layoutDirection
            {
                cancelPendingTracking()
                updateTypography()
                var ancestor = superview
                while let view = ancestor, !(view is UIWindow) {
                    view.setNeedsLayout()
                    ancestor = view.superview
                }
            }
            setNeedsLayout()
        }

        private var horizontalChromeWidth: CGFloat {
            Metrics.horizontalPadding * 2 + (indicatorView == nil ? 0 : Metrics.indicatorWidth)
        }

        private func horizontalLayout(width: CGFloat) -> (padding: CGFloat, indicatorWidth: CGFloat, textWidth: CGFloat) {
            let scale = min(1, max(0, width - 1) / horizontalChromeWidth)
            let padding = Metrics.horizontalPadding * scale
            let indicatorWidth = (indicatorView == nil ? 0 : Metrics.indicatorWidth) * scale
            return (padding, indicatorWidth, max(0, width - padding * 2 - indicatorWidth))
        }

        private func updateTypography() {
            let allowsWrapping = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            titleLabel.numberOfLines = allowsWrapping ? 0 : 1
            titleLabel.lineBreakMode = allowsWrapping ? .byWordWrapping : .byTruncatingTail
            titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: Metrics.fontSize), compatibleWith: traitCollection)
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }

        func apply(_ palette: ReaderOverflowMenuAppearance) {
            titleLabel.textColor = palette.text
            indicatorView?.tintColor = itemSelected ? palette.checked : palette.control
            highlightColor = palette.highlight
            backgroundColor = isHighlighted ? highlightColor : .clear
        }

        override var isEnabled: Bool {
            didSet { if !isEnabled { cancelPendingTracking() } }
        }

        override var isHidden: Bool {
            didSet { if isHidden { cancelPendingTracking() } }
        }

        override var alpha: CGFloat {
            didSet { if alpha <= 0.01 { cancelPendingTracking() } }
        }

        override var isUserInteractionEnabled: Bool {
            didSet { if !isUserInteractionEnabled { cancelPendingTracking() } }
        }

        override func willMove(toSuperview newSuperview: UIView?) {
            if newSuperview !== superview { cancelPendingTracking() }
            super.willMove(toSuperview: newSuperview)
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow !== window { cancelPendingTracking() }
            super.willMove(toWindow: newWindow)
        }

        func cancelPendingTracking() {
            guard !isCancellingInteraction else { return }
            isCancellingInteraction = true
            revision &+= 1
            interaction = nil
            dispatchRevision = nil
            accessibilityFocusRevision = nil
            isHighlighted = false
            super.cancelTracking(with: nil)
            isCancellingInteraction = false
        }

        private var interactionAllowed: Bool {
            guard !hasActivated, !isCancellingInteraction, isEnabled, canInteract?() == true, let window else {
                return false
            }
            var visibleRect = convert(bounds, to: window).intersection(window.bounds)
            var opacity: CGFloat = 1
            var ancestor: UIView? = self
            while let view = ancestor {
                opacity *= view.alpha
                guard !view.isHidden, opacity > 0.01, view.isUserInteractionEnabled,
                    !view.accessibilityElementsHidden
                else { return false }
                if view.clipsToBounds { visibleRect = visibleRect.intersection(view.convert(view.bounds, to: window)) }
                ancestor = view.superview
            }
            guard !visibleRect.isNull, !visibleRect.isEmpty,
                visibleRect.minX.isFinite, visibleRect.minY.isFinite,
                visibleRect.width.isFinite, visibleRect.height.isFinite,
                let hit = window.hitTest(CGPoint(x: visibleRect.midX, y: visibleRect.midY), with: nil)
            else { return false }
            return hit === self || hit.isDescendant(of: self)
        }

        // Match Reader's guarded touch dispatch; UIControl must not also send an automatic up event.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard interaction == nil, touches.count == 1, let touch = touches.first else {
                cancelPendingTracking()
                return
            }
            _ = beginTracking(touch, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = interaction?.touch, touches.contains(touch) else { return }
            _ = continueTracking(touch, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = interaction?.touch, touches.contains(touch) else { return }
            endTracking(touch, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            cancelTracking(with: event)
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let currentRevision = revision
            guard interaction == nil, interactionAllowed, revision == currentRevision,
                let window, bounds.contains(touch.location(in: self))
            else { return false }
            interaction = TouchInteraction(
                touch: touch, revision: currentRevision,
                origin: touch.location(in: window), rowRect: convert(bounds, to: window))
            isHighlighted = true
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard let interaction, accepts(touch, interaction: interaction) else {
                cancelPendingTracking()
                return false
            }
            isHighlighted = true
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard let interaction, let touch, accepts(touch, interaction: interaction) else {
                cancelPendingTracking()
                return
            }
            self.interaction = nil
            isHighlighted = false
            _ = activate(revision: interaction.revision)
        }

        override func cancelTracking(with event: UIEvent?) {
            cancelPendingTracking()
        }

        private func accepts(_ touch: UITouch, interaction: TouchInteraction) -> Bool {
            guard interaction.touch === touch, interaction.revision == revision,
                interactionAllowed, interaction.revision == revision, let window,
                bounds.contains(touch.location(in: self))
            else { return false }
            let point = touch.location(in: window)
            guard let hit = window.hitTest(point, with: nil), hit === self || hit.isDescendant(of: self) else {
                return false
            }
            return hypot(point.x - interaction.origin.x, point.y - interaction.origin.y) <= Metrics.touchSlop
                && convert(bounds, to: window) == interaction.rowRect
        }

        override func accessibilityElementDidBecomeFocused() {
            super.accessibilityElementDidBecomeFocused()
            hasReceivedAccessibilityFocus = true
            let currentRevision = revision
            accessibilityFocusRevision = interactionAllowed && revision == currentRevision ? currentRevision : nil
        }

        override func accessibilityElementDidLoseFocus() {
            accessibilityFocusRevision = nil
            super.accessibilityElementDidLoseFocus()
        }

        override func accessibilityActivate() -> Bool {
            guard isAccessibilityElement, interaction == nil,
                !hasReceivedAccessibilityFocus || accessibilityFocusRevision == revision
            else { return false }
            return activate(revision: revision)
        }

        private func activate(revision expectedRevision: UInt64) -> Bool {
            guard expectedRevision == revision, interactionAllowed, expectedRevision == revision else { return false }
            hasActivated = true
            isHighlighted = false
            dispatchRevision = expectedRevision
            defer { dispatchRevision = nil }
            sendActions(for: .touchUpInside)
            return true
        }

        override func sendActions(for controlEvents: UIControl.Event) {
            guard controlEvents == .touchUpInside, dispatchRevision == revision, !isSendingActions else { return }
            isSendingActions = true
            defer { isSendingActions = false }
            super.sendActions(for: .touchUpInside)
        }
    }
}
