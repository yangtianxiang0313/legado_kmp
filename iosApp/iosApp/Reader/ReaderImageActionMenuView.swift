import UIKit

@MainActor
final class ReaderImageActionMenuView: UIView {
    enum Action: String, CaseIterable {
        case show
        case refresh
        case save
        case mainMenu
        case selectFolder

        fileprivate var title: String {
            switch self {
            case .show: return NSLocalizedString("reader.image_action.show", value: "显示", comment: "Image action")
            case .refresh: return NSLocalizedString("reader.image_action.refresh", value: "刷新", comment: "Image action")
            case .save: return NSLocalizedString("reader.image_action.save", value: "保存", comment: "Image action")
            case .mainMenu: return NSLocalizedString("reader.image_action.menu", value: "菜单", comment: "Image action")
            case .selectFolder: return NSLocalizedString("reader.image_action.folder", value: "选择文件夹", comment: "Image action")
            }
        }
    }

    private enum Metrics {
        // Legado 5f5d314: popup_action.xml, item_text.xml, shape_card_view.xml.
        static let padding: CGFloat = 5
        static let itemPadding: CGFloat = 5
        static let fontSize: CGFloat = 14
        static let cornerRadius: CGFloat = 3
    }

    var onDismiss: (() -> Void)?

    private let onAction: (Action) -> Void
    private let outsideControl = UIControl()
    private let panel = UIView()
    private let scrollView = ActionScrollView()
    private var controls: [ActionControl] = []
    private weak var hostView: UIView?
    private weak var previousFirstResponder: UIResponder?
    private var anchorRect = CGRect.zero
    private var isPresented = false
    private var didActivateAction = false

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init(frame: .zero)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissFromOutside))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    /// The anchor is expressed in the host view's coordinate space.
    func present(in host: UIView, anchor: CGRect, interfaceStyle: UIUserInterfaceStyle) {
        guard host !== self, !host.isDescendant(of: self),
            [anchor.minX, anchor.minY, anchor.width, anchor.height].allSatisfy({ $0.isFinite })
        else { return }
        if isPresented, hostView !== host { dismiss() }
        let isNewPresentation = !isPresented
        if isNewPresentation {
            previousFirstResponder = firstResponder(in: host)
            didActivateAction = false
            scrollView.setContentOffset(.zero, animated: false)
        }
        hostView = host
        anchorRect = anchor.standardized
        overrideUserInterfaceStyle = interfaceStyle
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if superview !== host {
            host.addSubview(self)
        } else {
            host.bringSubviewToFront(self)
        }
        isPresented = true
        isUserInteractionEnabled = true
        accessibilityViewIsModal = true
        updateAppearance()
        setNeedsLayout()
        layoutIfNeeded()
        becomeFirstResponder()
        if isNewPresentation, window != nil {
            UIAccessibility.post(notification: .screenChanged, argument: controls.first)
        }
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        isUserInteractionEnabled = false
        accessibilityViewIsModal = false
        let host = hostView
        let previous = previousFirstResponder
        previousFirstResponder = nil
        hostView = nil
        resignFirstResponder()
        removeFromSuperview()
        if let previousView = previous as? UIView, previousView.window != nil {
            previousView.becomeFirstResponder()
        }
        if host?.window != nil {
            UIAccessibility.post(notification: .screenChanged, argument: previous ?? host)
        }
        onDismiss?()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isPresented else { return false }
        dismiss()
        return true
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil, isPresented { dismiss() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, isPresented { dismiss() }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        guard let host = hostView else { return }
        let safeBounds = bounds.inset(by: safeAreaInsets)
        guard safeBounds.width > Metrics.padding * 2, safeBounds.height > Metrics.padding * 2 else {
            panel.isHidden = true
            return
        }
        panel.isHidden = false
        let anchor = host.convert(anchorRect, to: self)
        let naturalWidth = controls.reduce(CGFloat.zero) { $0 + $1.naturalWidth }
        let width = min(safeBounds.width, naturalWidth + Metrics.padding * 2)
        let layout = contentLayout(maximumWidth: max(1, width - Metrics.padding * 2))
        let fullHeight = layout.size.height + Metrics.padding * 2
        let aboveBottom = min(max(anchor.minY, safeBounds.minY), safeBounds.maxY)
        let belowTop = min(max(anchor.maxY, safeBounds.minY), safeBounds.maxY)
        let aboveHeight = aboveBottom - safeBounds.minY
        let belowHeight = safeBounds.maxY - belowTop
        // The Android bottom/left PopupWindow places its bottom at the long-press point.
        let opensAbove = fullHeight <= aboveHeight || (fullHeight > belowHeight && aboveHeight >= belowHeight)
        let availableHeight = opensAbove ? aboveHeight : belowHeight
        let height = min(fullHeight, availableHeight > Metrics.padding * 2 ? availableHeight : safeBounds.height)
        let preferredX = effectiveUserInterfaceLayoutDirection == .rightToLeft ? anchor.maxX - width : anchor.minX
        let x = min(max(preferredX, safeBounds.minX), safeBounds.maxX - width)
        let preferredY = opensAbove ? aboveBottom - height : belowTop
        let y = min(max(preferredY, safeBounds.minY), safeBounds.maxY - height)
        panel.frame = CGRect(x: x, y: y, width: width, height: height)
        scrollView.frame = panel.bounds.insetBy(dx: Metrics.padding, dy: Metrics.padding)
        for (control, frame) in zip(controls, layout.frames) { control.frame = frame }
        scrollView.contentSize = layout.size
        scrollView.isScrollEnabled = layout.size.height > scrollView.bounds.height
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        let offsetY = min(max(0, scrollView.contentOffset.y), max(0, layout.size.height - scrollView.bounds.height))
        if scrollView.contentOffset != CGPoint(x: 0, y: offsetY) {
            scrollView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
        }
    }

    private func configureViews() {
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityIdentifier = "reader.imageActionMenu"
        outsideControl.backgroundColor = .clear
        outsideControl.isAccessibilityElement = true
        outsideControl.accessibilityLabel = NSLocalizedString("common.cancel", value: "取消", comment: "Dismiss menu")
        outsideControl.accessibilityTraits = .button
        outsideControl.accessibilityIdentifier = "reader.imageActionMenu.dismiss"
        outsideControl.addTarget(self, action: #selector(dismissFromOutside), for: .touchUpInside)
        addSubview(outsideControl)

        panel.layer.cornerRadius = Metrics.cornerRadius
        panel.layer.shadowOpacity = 0
        panel.clipsToBounds = true
        panel.accessibilityIdentifier = "reader.imageActionMenu.panel"
        addSubview(panel)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        panel.addSubview(scrollView)

        controls = Action.allCases.map { action in
            let control = ActionControl(action: action)
            control.addAction(UIAction { [weak self] _ in self?.activate(action) }, for: .touchUpInside)
            scrollView.addSubview(control)
            return control
        }
        scrollView.accessibilityElements = controls
        accessibilityElements = [scrollView, outsideControl]
        updateAppearance()
    }

    private func updateAppearance() {
        let dark = traitCollection.userInterfaceStyle == .dark
        // background_card is grey_100 / grey_850, not the darker background_menu surface.
        panel.backgroundColor = UIColor(white: dark ? 48.0 / 255.0 : 245.0 / 255.0, alpha: 1)
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: Metrics.fontSize), compatibleWith: traitCollection)
        for control in controls {
            control.update(font: font, dark: dark)
        }
        scrollView.indicatorStyle = dark ? .white : .black
    }

    private func contentLayout(maximumWidth: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowStart = 0
        func finishRow() {
            for index in rowStart..<frames.count {
                frames[index].size.height = rowHeight
                if effectiveUserInterfaceLayoutDirection == .rightToLeft {
                    frames[index].origin.x = maximumWidth - frames[index].maxX
                }
            }
        }
        for control in controls {
            let width = min(maximumWidth, control.naturalWidth)
            if x > 0, x + width > maximumWidth {
                finishRow()
                y += rowHeight
                x = 0
                rowHeight = 0
                rowStart = frames.count
            }
            let height = control.height(for: width)
            frames.append(CGRect(x: x, y: y, width: width, height: height))
            x += width
            rowHeight = max(rowHeight, height)
        }
        finishRow()
        return (CGSize(width: maximumWidth, height: y + rowHeight), frames)
    }

    private func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }

    private func activate(_ action: Action) {
        guard isPresented, !didActivateAction else { return }
        didActivateAction = true
        let handler = onAction
        dismiss()
        handler(action)
    }

    @objc private func dismissFromOutside() { dismiss() }

    private final class ActionScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool { view is UIControl || super.touchesShouldCancel(in: view) }
    }

    private final class ActionControl: UIControl {
        private let label = UILabel()
        private var highlightColor = UIColor.clear

        init(action: Action) {
            super.init(frame: .zero)
            label.text = action.title
            label.numberOfLines = 0
            label.textAlignment = .center
            label.lineBreakMode = .byWordWrapping
            label.isAccessibilityElement = false
            label.isUserInteractionEnabled = false
            addSubview(label)
            isAccessibilityElement = true
            accessibilityLabel = action.title
            accessibilityTraits = .button
            accessibilityIdentifier = "reader.imageActionMenu.\(action.rawValue)"
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            preconditionFailure("init(coder:) is unavailable")
        }

        override var isHighlighted: Bool {
            didSet { backgroundColor = isHighlighted ? highlightColor : .clear }
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            backgroundColor = isFocused || isHighlighted ? highlightColor : .clear
        }

        var naturalWidth: CGFloat {
            max(
                44,
                ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width)
                    + Metrics.itemPadding * 2)
        }

        func height(for width: CGFloat) -> CGFloat {
            let size = label.sizeThatFits(CGSize(width: max(1, width - Metrics.itemPadding * 2), height: CGFloat.greatestFiniteMagnitude))
            return max(44, ceil(size.height) + Metrics.itemPadding * 2)
        }

        func update(font: UIFont, dark: Bool) {
            label.font = font
            label.textColor = dark ? .white : UIColor.black.withAlphaComponent(222.0 / 255.0)
            highlightColor = UIColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.08)
            backgroundColor = isHighlighted || isFocused ? highlightColor : .clear
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds.insetBy(dx: Metrics.itemPadding, dy: Metrics.itemPadding)
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled, window != nil else { return false }
            sendActions(for: .touchUpInside)
            return true
        }
    }
}
