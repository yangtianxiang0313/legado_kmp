import CoreText
import UIKit

final class AndroidReaderTextActionMenuView: UIView {
    var canInteract: (() -> Bool)? {
        didSet { if !allowsInteraction { cancelPendingTracking() } }
    }
    var expandsAllActions: Bool { expandAll }
    enum Action: CaseIterable, Hashable {
        case replace
        case copy
        case bookmark
        case readAloud
        case dictionary
        case search
        case browser
        case share

        var title: String {
            switch self {
            case .replace:
                return L10n.Reader.selectionReplace
            case .copy:
                return L10n.Reader.selectionCopy
            case .bookmark:
                return L10n.Reader.selectionBookmark
            case .readAloud:
                return L10n.Reader.selectionReadAloud
            case .dictionary:
                return L10n.Reader.selectionDictionary
            case .search:
                return L10n.Reader.searchInBook
            case .browser:
                return L10n.Reader.selectionBrowser
            case .share:
                return L10n.Reader.selectionShare
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .replace:
                return UIIdentifiers.Reader.textSelectionReplaceButton
            case .copy:
                return UIIdentifiers.Reader.textSelectionCopyButton
            case .bookmark:
                return UIIdentifiers.Reader.textSelectionBookmarkButton
            case .readAloud:
                return UIIdentifiers.Reader.textSelectionReadAloudButton
            case .dictionary:
                return UIIdentifiers.Reader.textSelectionDictionaryButton
            case .search:
                return UIIdentifiers.Reader.textSelectionSearchButton
            case .browser:
                return UIIdentifiers.Reader.textSelectionBrowserButton
            case .share:
                return UIIdentifiers.Reader.textSelectionShareButton
            }
        }
    }

    private enum Metrics {
        // Legado 5f5d314: popup_action_menu.xml, item_text.xml, shape_card_view.xml.
        static let margin: CGFloat = 5
        static let itemPadding: CGFloat = 5
        static let fontSize: CGFloat = 14
        static let iconSize: CGFloat = 24
        static let cornerRadius: CGFloat = 3
    }

    private struct ContentLayout {
        let size: CGSize
        let buttonFrames: [CGRect]
    }

    private let scrollView = ActionScrollView()
    private let contentView = UIView()
    private let navigationButton = TextActionButton(type: .custom)
    private let expandAll: Bool
    private let onAction: (Action) -> Void
    private let onLayoutChange: (() -> Void)?
    private var isShowingMore = false
    private var buttons: [TextActionButton] = []
    private var buttonsByAction: [Action: TextActionButton] = [:]
    private var contentOffsets: [Bool: CGPoint] = [:]
    private var pendingContentOffset: CGPoint?
    private var containerBounds: CGRect?
    private var containerSafeAreaInsets: UIEdgeInsets?

    init(expandAll: Bool, onAction: @escaping (Action) -> Void, onLayoutChange: (() -> Void)? = nil) {
        self.expandAll = expandAll
        self.onAction = onAction
        self.onLayoutChange = onLayoutChange
        super.init(frame: .zero)
        configureViews()
        rebuildButtons()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHidden: Bool {
        didSet {
            guard isHidden else { return }
            cancelPendingTracking()
            guard !expandAll, isShowingMore else { return }
            // TextActionMenu.onDismiss returns to the first five actions, including on handle down.
            contentOffsets[true] = scrollView.contentOffset
            isShowingMore = false
            pendingContentOffset = contentOffsets[false] ?? .zero
            rebuildButtons()
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelPendingTracking() } }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { cancelPendingTracking() }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { cancelPendingTracking() }
        super.willMove(toSuperview: newSuperview)
    }

    func cancelPendingTracking() {
        navigationButton.cancelPendingTracking()
        for button in buttonsByAction.values { button.cancelPendingTracking() }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        if scrollView.isDragging || scrollView.isTracking {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
        }
    }

    private var allowsInteraction: Bool {
        guard canInteract?() != false, let window,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            ancestor = view.superview
        }
        return true
    }

    @objc private func environmentWillDeactivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        cancelPendingTracking()
    }

    override var intrinsicContentSize: CGSize {
        preferredSize(maximumWidth: .greatestFiniteMagnitude)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        preferredSize(maximumWidth: targetSize.width)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority _: UILayoutPriority,
        verticalFittingPriority _: UILayoutPriority
    ) -> CGSize {
        preferredSize(maximumWidth: targetSize.width)
    }

    func minimumViewportSize(maximumWidth: CGFloat) -> CGSize {
        let widestTitle = buttons.map(naturalButtonWidth).max() ?? 0
        let navigationWidth = !expandAll && !isShowingMore ? Metrics.iconSize : 0
        let width = max(widestTitle, isShowingMore ? Metrics.iconSize : 0) + navigationWidth + Metrics.margin * 2
        let height =
            isShowingMore && !expandAll
            ? Metrics.iconSize + rowHeight : max(rowHeight, expandAll ? 0 : Metrics.iconSize)
        return CGSize(width: min(maximumWidth, width), height: height + Metrics.margin * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let innerFrame = CGRect(
            x: Metrics.margin, y: Metrics.margin,
            width: max(0, bounds.width - Metrics.margin * 2),
            height: max(0, bounds.height - Metrics.margin * 2)
        )
        if expandAll {
            scrollView.frame = innerFrame
        } else if isShowingMore {
            navigationButton.frame = CGRect(
                x: isRTL ? innerFrame.maxX - Metrics.iconSize : innerFrame.minX, y: innerFrame.minY,
                width: Metrics.iconSize, height: Metrics.iconSize)
            let listWidth = min(innerFrame.width, buttons.map(naturalButtonWidth).max() ?? 0)
            scrollView.frame = CGRect(
                x: innerFrame.midX - listWidth / 2, y: innerFrame.minY + Metrics.iconSize,
                width: listWidth, height: max(0, innerFrame.height - Metrics.iconSize))
        } else {
            scrollView.frame = CGRect(
                x: innerFrame.minX + (isRTL ? Metrics.iconSize : 0), y: innerFrame.minY,
                width: max(0, innerFrame.width - Metrics.iconSize), height: innerFrame.height)
            navigationButton.frame = CGRect(
                x: isRTL ? innerFrame.minX : innerFrame.maxX - Metrics.iconSize, y: innerFrame.midY - Metrics.iconSize / 2,
                width: Metrics.iconSize, height: Metrics.iconSize)
        }

        let layout = contentLayout(maximumWidth: max(1, scrollView.bounds.width))
        let topInset =
            !expandAll && !isShowingMore
            ? max(0, (scrollView.bounds.height - layout.size.height) / 2) : 0
        contentView.frame = CGRect(x: 0, y: topInset, width: layout.size.width, height: layout.size.height)
        for (button, frame) in zip(buttons, layout.buttonFrames) {
            button.frame = frame
        }
        scrollView.contentSize = CGSize(
            width: scrollView.bounds.width, height: max(scrollView.bounds.height, layout.size.height))
        let maximumOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let offset = min(max(0, (pendingContentOffset ?? scrollView.contentOffset).y), maximumOffset)
        pendingContentOffset = nil
        if scrollView.contentOffset != CGPoint(x: 0, y: offset) {
            scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
        scrollView.isScrollEnabled = layout.size.height > scrollView.bounds.height
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        refreshContainerGeometryIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        refreshContainerGeometryIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        navigationButton.refreshHighlight()
        for button in buttonsByAction.values { button.refreshHighlight() }
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        rebuildButtons()
        onLayoutChange?()
    }

    private func refreshContainerGeometryIfNeeded() {
        guard let superview,
            containerBounds != superview.bounds || containerSafeAreaInsets != superview.safeAreaInsets
        else { return }
        containerBounds = superview.bounds
        containerSafeAreaInsets = superview.safeAreaInsets
        onLayoutChange?()
    }

    private func configureViews() {
        accessibilityIdentifier = UIIdentifiers.Reader.textSelectionMenu
        // shape_card_view -> background_card -> md_grey_100 / md_grey_850.
        backgroundColor = UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 48.0 / 255 : 245.0 / 255, alpha: 1)
        }
        layer.cornerRadius = Metrics.cornerRadius
        // The pinned PopupWindow uses a plain shape, with no elevation or shadow drawable.
        layer.shadowOpacity = 0
        insetsLayoutMarginsFromSafeArea = false
        preservesSuperviewLayoutMargins = false

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.bounces = false
        scrollView.clipsToBounds = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        navigationButton.tintColor = AndroidReplicaTheme.primaryText
        navigationButton.isBorderless = true
        navigationButton.accessibilityIdentifier = UIIdentifiers.Reader.textSelectionMoreButton
        navigationButton.canActivate = { [weak self] in
            guard let self else { return false }
            return self.allowsInteraction && !self.expandAll && !self.navigationButton.isHidden
        }
        navigationButton.onActivate = { [weak self] in
            guard let self, self.allowsInteraction, !self.expandAll else { return }
            self.contentOffsets[self.isShowingMore] = self.scrollView.contentOffset
            self.isShowingMore.toggle()
            self.pendingContentOffset = self.contentOffsets[self.isShowingMore] ?? .zero
            self.rebuildButtons()
            self.onLayoutChange?()
            guard self.allowsInteraction else { return }
            UIAccessibility.post(
                notification: .layoutChanged,
                argument: self.isShowingMore ? self.navigationButton : self.buttons.first)
        }
        addSubview(navigationButton)
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentWillDeactivate(_:)), name: name, object: nil)
        }
    }

    private func rebuildButtons() {
        cancelPendingTracking()
        let actions: [Action]
        if expandAll {
            actions = Action.allCases
        } else if isShowingMore {
            actions = [.search, .browser, .share]
        } else {
            actions = [.replace, .copy, .bookmark, .readAloud, .dictionary]
        }
        let nextButtons = actions.map { action -> TextActionButton in
            if let button = buttonsByAction[action] { return button }
            let button = makeActionButton(action)
            buttonsByAction[action] = button
            return button
        }
        for button in buttons where !nextButtons.contains(where: { $0 === button }) { button.removeFromSuperview() }
        buttons = nextButtons
        for button in buttons {
            button.titleLabel?.font = actionFont
            button.contentEdgeInsets = actionInsets
            if button.superview !== contentView { contentView.addSubview(button) }
        }
        navigationButton.isHidden = expandAll
        navigationButton.setImage(isShowingMore ? Self.backIcon : Self.moreIcon, for: .normal)
        navigationButton.accessibilityLabel = isShowingMore ? L10n.Reader.backAction : L10n.Reader.selectionMore
        accessibilityElements =
            expandAll
            ? buttons
            : (isShowingMore ? [navigationButton] + buttons : buttons + [navigationButton])
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var actionFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(
            size: Metrics.fontSize, textStyle: .subheadline, compatibleWith: traitCollection)
    }

    private var actionInsets: UIEdgeInsets {
        // item_text keeps TextView's default font padding in addition to its 5dp padding.
        let font = actionFont
        let bounds = CTFontGetBoundingBox(font as CTFont)
        let scale = max(1, traitCollection.displayScale)
        return UIEdgeInsets(
            top: Metrics.itemPadding + max(0, ceil(bounds.maxY * scale) / scale - font.ascender),
            left: Metrics.itemPadding,
            bottom: Metrics.itemPadding + max(0, -floor(bounds.minY * scale) / scale + font.descender),
            right: Metrics.itemPadding)
    }

    private var rowHeight: CGFloat {
        let titleHeight = buttons.map { titleSize($0).height }.max() ?? 0
        let insets = actionInsets
        return ceil(max(actionFont.lineHeight, titleHeight)) + insets.top + insets.bottom
    }

    private func titleSize(_ button: UIButton) -> CGSize {
        let title = button.title(for: .normal) ?? ""
        return (title as NSString).size(withAttributes: [.font: actionFont])
    }

    private func naturalButtonWidth(_ button: UIButton) -> CGFloat {
        ceil(titleSize(button).width) + Metrics.itemPadding * 2
    }

    private func preferredSize(maximumWidth: CGFloat) -> CGSize {
        let width = maximumWidth.isFinite && maximumWidth > 0 ? maximumWidth : CGFloat.greatestFiniteMagnitude
        let navigationWidth = !expandAll && !isShowingMore ? Metrics.iconSize : 0
        let layout = contentLayout(maximumWidth: max(1, width - Metrics.margin * 2 - navigationWidth))
        let contentWidth = max(layout.size.width, isShowingMore ? Metrics.iconSize : 0) + navigationWidth
        let contentHeight =
            isShowingMore && !expandAll
            ? Metrics.iconSize + layout.size.height : max(layout.size.height, expandAll ? 0 : Metrics.iconSize)
        return CGSize(
            width: min(width, contentWidth + Metrics.margin * 2), height: contentHeight + Metrics.margin * 2)
    }

    private func contentLayout(maximumWidth: CGFloat) -> ContentLayout {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var width: CGFloat = 0
        let height = rowHeight
        let verticalList = isShowingMore && !expandAll
        for button in buttons {
            // item_text is wrap_content even in the vertical RecyclerView. Only the
            // list measures to its widest child; short rows never stretch to that width.
            let buttonWidth = min(maximumWidth, naturalButtonWidth(button))
            // Both normal and expanded RecyclerViews use row/wrap, not equal-width columns.
            if !frames.isEmpty && (verticalList || x + buttonWidth > maximumWidth) {
                x = 0
                y += height
            }
            frames.append(CGRect(x: x, y: y, width: buttonWidth, height: height))
            x += buttonWidth
            width = max(width, x)
        }
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            for index in frames.indices { frames[index].origin.x = width - frames[index].maxX }
        }
        return ContentLayout(size: CGSize(width: width, height: frames.isEmpty ? 0 : y + height), buttonFrames: frames)
    }

    private func makeActionButton(_ action: Action) -> TextActionButton {
        let button = TextActionButton(type: .custom)
        button.setTitle(action.title, for: .normal)
        button.setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        button.setTitleColor(AndroidReplicaTheme.primaryText, for: .highlighted)
        button.setTitleColor(AndroidReplicaTheme.primaryText, for: .disabled)
        button.contentEdgeInsets = actionInsets
        button.titleLabel?.font = actionFont
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.textAlignment = .center
        button.contentHorizontalAlignment = .center
        button.accessibilityLabel = action.title
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.canActivate = { [weak self, weak button] in
            guard let self, let button else { return false }
            return self.allowsInteraction && button.superview === self.contentView
                && self.buttons.contains(where: { $0 === button })
        }
        button.onActivate = { [weak self, weak button] in
            guard let self, let button, button.canActivate?() == true else { return }
            self.cancelPendingTracking()
            self.onAction(action)
        }
        return button
    }

    private static let moreIcon = navigationIcon(isBack: false)
    private static let backIcon = navigationIcon(isBack: true)

    private static func navigationIcon(isBack: Bool) -> UIImage {
        // Exact 24 x 24 paths from the pinned ic_more_vert.xml / ic_arrow_back.xml.
        // Unlike the toolbar's AppCompat assets, neither drawable declares autoMirrored.
        UIGraphicsImageRenderer(size: CGSize(width: Metrics.iconSize, height: Metrics.iconSize)).image { _ in
            UIColor.black.setFill()
            let path = UIBezierPath()
            if isBack {
                let points: [CGPoint] = [
                    CGPoint(x: 20, y: 11), CGPoint(x: 7.83, y: 11), CGPoint(x: 13.42, y: 5.41),
                    CGPoint(x: 12, y: 4), CGPoint(x: 4, y: 12), CGPoint(x: 12, y: 20),
                    CGPoint(x: 13.41, y: 18.59), CGPoint(x: 7.83, y: 13), CGPoint(x: 20, y: 13),
                ]
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.close()
            } else {
                for y in [CGFloat(6), 12, 18] {
                    path.move(to: CGPoint(x: 12, y: y + 2))
                    path.addCurve(
                        to: CGPoint(x: 14, y: y), controlPoint1: CGPoint(x: 13.1, y: y + 2),
                        controlPoint2: CGPoint(x: 14, y: y + 1.1))
                    path.addCurve(
                        to: CGPoint(x: 12, y: y - 2), controlPoint1: CGPoint(x: 14, y: y - 1.1),
                        controlPoint2: CGPoint(x: 13.1, y: y - 2))
                    path.addCurve(
                        to: CGPoint(x: 10, y: y), controlPoint1: CGPoint(x: 10.9, y: y - 2),
                        controlPoint2: CGPoint(x: 10, y: y - 1.1))
                    path.addCurve(
                        to: CGPoint(x: 12, y: y + 2), controlPoint1: CGPoint(x: 10, y: y + 1.1),
                        controlPoint2: CGPoint(x: 10.9, y: y + 2))
                    path.close()
                }
            }
            path.fill()
        }.withRenderingMode(.alwaysTemplate)
    }

    private final class ActionScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            view is UIControl || super.touchesShouldCancel(in: view)
        }
    }

    private final class TextActionButton: UIButton {
        var canActivate: (() -> Bool)?
        var onActivate: (() -> Void)?
        var isBorderless = false {
            didSet { setNeedsLayout() }
        }
        private let highlightLayer = CAShapeLayer()
        private var trackingTouch: UITouch?
        private var activationPress: UIPress?

        override init(frame: CGRect) {
            super.init(frame: frame)
            adjustsImageWhenHighlighted = false
            adjustsImageWhenDisabled = false
            imageView?.contentMode = .center
            highlightLayer.isHidden = true
            layer.insertSublayer(highlightLayer, at: 0)
            refreshHighlight()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

        override var frame: CGRect {
            didSet { if frame != oldValue { cancelPendingTracking() } }
        }

        override var isHighlighted: Bool {
            didSet { refreshHighlight() }
        }

        override var isEnabled: Bool {
            didSet { if !isEnabled { cancelPendingTracking() } }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            highlightLayer.frame = bounds
            let rect = CGRect(origin: .zero, size: bounds.size)
            if isBorderless {
                // SDK item_background_borderless_material has no rectangular mask.
                let radius = hypot(rect.width, rect.height) / 2
                highlightLayer.path =
                    UIBezierPath(
                        ovalIn: CGRect(
                            x: rect.midX - radius, y: rect.midY - radius,
                            width: radius * 2, height: radius * 2)
                    ).cgPath
            } else {
                // item_background_material's opaque mask bounds feedback to the item.
                highlightLayer.path = UIBezierPath(rect: rect).cgPath
            }
        }

        func refreshHighlight() {
            // AppCompat 1.7.1 Base.V21.Theme -> android:selectableItemBackground
            // -> SDK item_background_material -> colorControlHighlight. The theme
            // supplies ripple_material_light #1F000000 / dark #33FFFFFF, not btn_bg_press.
            let dark = traitCollection.userInterfaceStyle == .dark
            highlightLayer.fillColor = UIColor(white: dark ? 1 : 0, alpha: dark ? 51.0 / 255 : 31.0 / 255).cgColor
            highlightLayer.isHidden = !isHighlighted || !allowsActivation
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard trackingTouch == nil, allowsActivation else { return false }
            guard super.beginTracking(touch, with: event), allowsActivation else {
                cancelPendingTracking()
                return false
            }
            trackingTouch = touch
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard trackingTouch === touch, allowsActivation else {
                cancelPendingTracking()
                return false
            }
            let accepted = super.continueTracking(touch, with: event)
            if !accepted { cancelPendingTracking() }
            return accepted
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            let accepted =
                touch.map {
                    trackingTouch === $0 && allowsActivation && bounds.contains($0.location(in: self))
                } ?? false
            trackingTouch = nil
            super.endTracking(touch, with: event)
            isHighlighted = false
            if accepted, allowsActivation { onActivate?() }
        }

        override func cancelTracking(with event: UIEvent?) {
            trackingTouch = nil
            isHighlighted = false
            super.cancelTracking(with: event)
        }

        func cancelPendingTracking() {
            trackingTouch = nil
            activationPress = nil
            isHighlighted = false
            super.cancelTracking(with: nil)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let press = presses.first(where: Self.isActivation), allowsActivation, trackingTouch == nil {
                activationPress = press
            }
            super.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let accepted =
                activationPress.map { press in presses.contains(where: { $0 === press }) } == true
                && allowsActivation
            activationPress = nil
            super.pressesEnded(presses, with: event)
            isHighlighted = false
            if accepted, allowsActivation { onActivate?() }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            cancelPendingTracking()
            super.pressesCancelled(presses, with: event)
        }

        private static func isActivation(_ press: UIPress) -> Bool {
            press.type == .select || press.key?.keyCode == .keyboardSpacebar
                || press.key?.keyCode == .keyboardReturnOrEnter || press.key?.keyCode == .keypadEnter
        }

        override func accessibilityActivate() -> Bool {
            guard allowsActivation, trackingTouch == nil, activationPress == nil, !isTracking else { return false }
            onActivate?()
            return true
        }

        private var allowsActivation: Bool {
            isEnabled && !isHidden && alpha > 0.01 && isUserInteractionEnabled && canActivate?() == true
        }
    }
}
