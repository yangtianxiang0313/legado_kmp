import UIKit

@MainActor
final class BookInfoEditTypeButton: UIButton {
    fileprivate static let titles = ["文本", "音频", "图片", "文件"]

    var selectedIndex: Int {
        get { selection }
        set { setSelectedIndex(newValue) }
    }

    var onSelectionChanged: ((Int) -> Void)? {
        didSet {
            bindingRevision = UUID()
            dismissPopup()
        }
    }

    private var selection = 0
    private var bindingRevision = UUID()
    private var popup: BookInfoEditTypePopup?

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsMenuAsPrimaryAction = false
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byClipping
        titleLabel?.textAlignment = .natural
        titleLabel?.adjustsFontForContentSizeCategory = false
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.isAccessibilityElement = false
        isAccessibilityElement = true
        accessibilityLabel = "类型"
        accessibilityIdentifier = "bookInfoEdit.type"
        addTarget(self, action: #selector(togglePopup), for: .touchUpInside)
        updateSelection()
        refreshAppearance()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    // Rebinding, including to the current value, cancels any pending selection without a callback.
    func setSelectedIndex(_ index: Int) {
        bindingRevision = UUID()
        if Self.titles.indices.contains(index) {
            selection = index
            updateSelection()
        }
        dismissPopup()
    }

    @discardableResult
    func dismissPopup() -> Bool {
        guard let popup else { return false }
        self.popup = nil
        return popup.dismiss()
    }

    func refreshAppearance() {
        // Spinner's Holo text appearance is regular 16sp; the adjacent form label is 14sp.
        titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .disabled)
        setBackgroundImage(Self.spinnerBackground(compatibleWith: traitCollection), for: .normal)
        backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if !isEnabled { dismissPopup() }
        }
    }

    override var isHidden: Bool {
        didSet { if isHidden { dismissPopup() } }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { dismissPopup() } }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { dismissPopup() }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        dismissPopup()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        dismissPopup()
        refreshAppearance()
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let font = titleLabel?.font ?? .systemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = Self.titles.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        // Holo nine-patch padding is 4/7/16/8dp; the child adds 8dp at each horizontal edge.
        let preferredWidth = max(22, ceil(textWidth) + 36)
        let width = size.width > 0 && size.width.isFinite ? min(size.width, preferredWidth) : preferredWidth
        return CGSize(width: width, height: max(44, spinnerVisualHeight))
    }

    private var spinnerFontPadding: UIEdgeInsets {
        AndroidExploreTextMetrics.padding(
            font: titleLabel?.font ?? .systemFont(ofSize: 16), scale: traitCollection.displayScale)
    }

    private var spinnerVisualHeight: CGFloat {
        let font = titleLabel?.font ?? .systemFont(ofSize: 16)
        let textHeight = max(
            font.lineHeight,
            titleLabel?.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).height ?? 0)
        let padding = spinnerFontPadding
        let scale = max(1, traitCollection.displayScale)
        // The 24x34 mdpi PNG has a 1px metadata border, leaving a 22x32 minimum drawable.
        return max(32, ceil((textHeight + padding.top + padding.bottom + 15) * scale) / scale)
    }

    override func backgroundRect(forBounds bounds: CGRect) -> CGRect {
        // Keep the original drawable density inside an at-least-44pt iOS touch/accessibility frame.
        let height = min(bounds.height, spinnerVisualHeight)
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let visualBounds = backgroundRect(forBounds: bounds)
        let padding = spinnerFontPadding
        titleLabel?.frame = CGRect(
            x: visualBounds.minX + (isRTL ? 24 : 12), y: visualBounds.minY + 7 + padding.top,
            width: max(1, visualBounds.width - 36),
            height: max(0, visualBounds.height - 15 - padding.top - padding.bottom))
        popup?.cancelIfGeometryChanged()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, isUserInteractionEnabled, window != nil else { return false }
        togglePopup()
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        dismissPopup() || super.accessibilityPerformEscape()
    }

    static func spinnerBackground(compatibleWith traits: UITraitCollection) -> UIImage? {
        guard let raw = UIImage(named: "BookInfoAndroidTypeSpinner", in: nil, compatibleWith: traits)?.cgImage,
            let image = raw.cropping(to: CGRect(x: 1, y: 1, width: raw.width - 2, height: raw.height - 2))
        else { return nil }
        // Original mdpi top/left stretch pixels 5...6, excluding the metadata border.
        return UIImage(cgImage: image).resizableImage(
            withCapInsets: UIEdgeInsets(top: 4, left: 4, bottom: 26, right: 16), resizingMode: .stretch
        ).imageFlippedForRightToLeftLayoutDirection()
    }

    private func updateSelection() {
        setTitle(Self.titles[selection], for: .normal)
        accessibilityValue = Self.titles[selection]
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    @objc private func togglePopup() {
        if dismissPopup() { return }
        guard isEnabled, isUserInteractionEnabled, let host = window, host.isKeyWindow,
            host.windowScene?.activationState == .foregroundActive
        else { return }
        host.layoutIfNeeded()
        let popup = BookInfoEditTypePopup(anchor: self, selectedIndex: selection)
        let revision = bindingRevision
        popup.onSelect = { [weak self, weak popup, weak host] index in
            guard let self, let popup, let host, self.popup === popup, self.bindingRevision == revision,
                self.isEnabled, popup.hasCurrentGeometry, Self.titles.indices.contains(index)
            else { return }
            guard self.selection != index else {
                self.dismissPopup()
                return
            }
            let committedRevision = UUID()
            self.bindingRevision = committedRevision
            self.selection = index
            self.updateSelection()
            self.dismissPopup()
            guard self.bindingRevision == committedRevision, self.isEnabled, self.window === host,
                host.isKeyWindow, host.windowScene?.activationState == .foregroundActive
            else { return }
            // No valueChanged action: the controller receives exactly this one callback.
            self.onSelectionChanged?(index)
        }
        popup.onDismiss = { [weak self, weak popup] in
            guard let self, let popup, self.popup === popup else { return }
            self.popup = nil
        }
        self.popup = popup
        popup.present(in: host)
    }
}

@MainActor
private final class BookInfoEditTypePopup: UIView {
    var onSelect: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private struct Geometry: Equatable {
        let anchorBounds: CGRect
        let anchorRect: CGRect
        let visibleRect: CGRect
        let hostBounds: CGRect
        let safeInsets: UIEdgeInsets
        let direction: UIUserInterfaceLayoutDirection
        let interfaceStyle: UIUserInterfaceStyle
        let contentSizeCategory: UIContentSizeCategory
    }

    private weak var anchor: BookInfoEditTypeButton?
    private let outsideControl = UIButton(type: .custom)
    private let panel = UIView()
    private let scrollView = BookInfoEditTypePopupScrollView()
    private let rows: [BookInfoEditTypeOption]
    private let selectedIndex: Int
    private var geometry: Geometry?
    private var displayLink: CADisplayLink?
    private var isPresented = false
    private var didRevealSelection = false

    init(anchor: BookInfoEditTypeButton, selectedIndex: Int) {
        self.anchor = anchor
        self.selectedIndex = selectedIndex
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: anchor.traitCollection)
        rows = BookInfoEditTypeButton.titles.enumerated().map { index, title in
            BookInfoEditTypeOption(
                title: title, font: font, showsDivider: index < BookInfoEditTypeButton.titles.count - 1)
        }
        super.init(frame: .zero)
        overrideUserInterfaceStyle = anchor.traitCollection.userInterfaceStyle
        semanticContentAttribute =
            anchor.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        accessibilityIdentifier = "bookInfoEdit.typePopup"
        accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = true
        outsideControl.accessibilityLabel = L10n.Common.cancel
        outsideControl.accessibilityIdentifier = "bookInfoEdit.typePopup.dismiss"
        outsideControl.accessibilityTraits = .button
        outsideControl.addTarget(self, action: #selector(dismissFromOutside), for: .touchUpInside)
        addSubview(outsideControl)
        // AppCompat's support_simple_spinner_dropdown_item has no title or choice indicator.
        panel.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1) : .white }
        panel.layer.cornerRadius = 2
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.22
        panel.layer.shadowRadius = 6
        panel.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(panel)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        panel.addSubview(scrollView)
        for (index, row) in rows.enumerated() {
            row.tag = index
            row.isSelected = index == selectedIndex
            row.accessibilityIdentifier = "bookInfoEdit.typePopup.\(index)"
            row.addTarget(self, action: #selector(selectOption(_:)), for: .touchUpInside)
            scrollView.addSubview(row)
        }
        accessibilityElements = [scrollView, outsideControl]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard isPresented else { return super.keyCommands }
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissFromOutside))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    var hasCurrentGeometry: Bool {
        guard isPresented, let geometry, let current = currentGeometry() else { return false }
        return geometry == current
    }

    func present(in host: UIWindow) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)
        isPresented = true
        becomeFirstResponder()
        host.layoutIfNeeded()
        guard let geometry = currentGeometry() else {
            dismiss(restoreFocus: false)
            return
        }
        self.geometry = geometry
        setNeedsLayout()
        layoutIfNeeded()
        guard isPresented else { return }
        let proxy = DisplayProxy(owner: self)
        displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayProxy.tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(cancelPresentation), name: UIApplication.willResignActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(cancelPresentation), name: UIWindow.didResignKeyNotification, object: host)
        center.addObserver(
            self, selector: #selector(cancelPresentation), name: UIScene.willDeactivateNotification,
            object: host.windowScene)
        UIAccessibility.post(notification: .screenChanged, argument: rows[selectedIndex])
    }

    @discardableResult
    func dismiss(restoreFocus: Bool = true) -> Bool {
        guard isPresented else { return false }
        let focusAnchor = restoreFocus && hasCurrentGeometry ? anchor : nil
        let ownedFirstResponder = isFirstResponder
        isPresented = false
        isUserInteractionEnabled = false
        accessibilityViewIsModal = false
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
        onSelect = nil
        let completion = onDismiss
        onDismiss = nil
        removeFromSuperview()
        completion?()
        if let focusAnchor {
            if ownedFirstResponder { focusAnchor.becomeFirstResponder() }
            UIAccessibility.post(notification: .screenChanged, argument: focusAnchor)
        }
        return true
    }

    func cancelIfGeometryChanged() {
        guard isPresented, geometry != nil else { return }
        if !hasCurrentGeometry { dismiss(restoreFocus: false) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dismiss(restoreFocus: false) }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        guard isPresented, let geometry else { return }
        guard hasCurrentGeometry else {
            dismiss(restoreFocus: false)
            return
        }
        let safeBounds = bounds.inset(by: geometry.safeInsets)
        let anchorRect = geometry.anchorRect
        let width = min(safeBounds.width, max(anchorRect.width, rows.map(\.preferredWidth).max() ?? 0))
        var contentHeight: CGFloat = 0
        for row in rows {
            let height = row.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
            row.frame = CGRect(x: 0, y: contentHeight, width: width, height: height)
            contentHeight += height
        }
        let belowY = min(max(anchorRect.maxY, safeBounds.minY), safeBounds.maxY)
        let aboveBottom = min(max(anchorRect.minY, safeBounds.minY), safeBounds.maxY)
        let belowHeight = safeBounds.maxY - belowY
        let aboveHeight = aboveBottom - safeBounds.minY
        let opensAbove = belowHeight < min(contentHeight, aboveHeight)
        // Only overlap the anchor when neither side can expose a usable touch target.
        let usesViewport = max(belowHeight, aboveHeight) < min(44, safeBounds.height)
        let availableHeight = usesViewport ? safeBounds.height : (opensAbove ? aboveHeight : belowHeight)
        let height = min(contentHeight, availableHeight)
        guard width > 0, height > 0 else {
            dismiss(restoreFocus: false)
            return
        }
        let preferredX = geometry.direction == .rightToLeft ? anchorRect.maxX - width : anchorRect.minX
        panel.frame = CGRect(
            x: min(max(preferredX, safeBounds.minX), safeBounds.maxX - width),
            y: usesViewport ? safeBounds.minY : (opensAbove ? aboveBottom - height : belowY),
            width: width, height: height)
        panel.layer.shadowPath = UIBezierPath(roundedRect: panel.bounds, cornerRadius: 2).cgPath
        scrollView.frame = panel.bounds
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        scrollView.isScrollEnabled = contentHeight > height
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        if !didRevealSelection {
            didRevealSelection = true
            scrollView.scrollRectToVisible(rows[selectedIndex].frame, animated: false)
        }
    }

    private func currentGeometry() -> Geometry? {
        guard let anchor, let host = window, superview === host, anchor.window === host,
            anchor.isEnabled, host.isKeyWindow, host.windowScene?.activationState == .foregroundActive,
            host.bounds.width > 0, host.bounds.height > 0
        else { return nil }
        let safeBounds = host.bounds.inset(by: host.safeAreaInsets)
        guard safeBounds.width > 0, safeBounds.height > 0 else { return nil }
        let rect = anchor.convert(anchor.bounds, to: host)
        guard !rect.isEmpty, !rect.isNull, !rect.isInfinite else { return nil }
        var visibleRect = rect.intersection(safeBounds)
        var ancestor: UIView? = anchor
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return nil }
            if view.clipsToBounds {
                visibleRect = visibleRect.intersection(view.convert(view.bounds, to: host))
            }
            ancestor = view.superview
        }
        guard !visibleRect.isNull, !visibleRect.isEmpty else { return nil }
        return Geometry(
            anchorBounds: anchor.bounds, anchorRect: rect, visibleRect: visibleRect,
            hostBounds: host.bounds, safeInsets: host.safeAreaInsets,
            direction: anchor.effectiveUserInterfaceLayoutDirection,
            interfaceStyle: anchor.traitCollection.userInterfaceStyle,
            contentSizeCategory: anchor.traitCollection.preferredContentSizeCategory)
    }

    @objc private func dismissFromOutside() {
        dismiss()
    }

    @objc private func cancelPresentation() {
        dismiss(restoreFocus: false)
    }

    @objc private func selectOption(_ sender: UIControl) {
        guard isUserInteractionEnabled, hasCurrentGeometry, rows.indices.contains(sender.tag),
            rows[sender.tag] === sender, sender.isEnabled
        else {
            dismiss(restoreFocus: false)
            return
        }
        isUserInteractionEnabled = false
        let callback = onSelect
        onSelect = nil
        callback?(sender.tag)
    }

    @MainActor
    private final class DisplayProxy: NSObject {
        private weak var owner: BookInfoEditTypePopup?

        init(owner: BookInfoEditTypePopup) { self.owner = owner }

        @objc func tick(_: CADisplayLink) { owner?.cancelIfGeometryChanged() }
    }
}

@MainActor
private final class BookInfoEditTypeOption: UIControl {
    private let label = UILabel()
    private let divider = UIView()

    var preferredWidth: CGFloat {
        ceil(
            label.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width) + 16
    }

    init(title: String, font: UIFont, showsDivider: Bool) {
        super.init(frame: .zero)
        label.text = title
        label.font = font
        label.textColor = AndroidReplicaTheme.primaryText
        label.textAlignment = .natural
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = false
        label.isAccessibilityElement = false
        addSubview(label)
        divider.backgroundColor = UIColor {
            ($0.userInterfaceStyle == .dark ? UIColor.white : UIColor.black).withAlphaComponent(0.12)
        }
        divider.isHidden = !showsDivider
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        addSubview(divider)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isSelected: Bool {
        didSet { accessibilityTraits = isSelected ? [.button, .selected] : .button }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = label.sizeThatFits(
            CGSize(width: max(1, size.width - 16), height: CGFloat.greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: max(48, ceil(height) + 16))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
        let pixel = 1 / max(1, traitCollection.displayScale)
        divider.frame = CGRect(x: 0, y: max(0, bounds.height - pixel), width: bounds.width, height: pixel)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, isUserInteractionEnabled, window != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}

@MainActor
private final class BookInfoEditTypePopupScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
