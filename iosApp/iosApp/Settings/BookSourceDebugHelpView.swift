import UIKit

/// The help section of activity_source_debug.xml; the owner supplies all debug actions.
final class BookSourceDebugHelpView: UIView {
    enum Action {
        case keyword(String)
        case explore
        case detail
        case toc
        case content
    }

    var onAction: ((Action) -> Void)? {
        didSet { invalidateChipActions() }
    }
    var onExploreLongPress: (() -> Void)? {
        didSet { updateExploreLongPress() }
    }

    private let scrollView = BookSourceDebugHelpScrollView()
    private let contentView = UIView()
    private var actionsActive = false
    private let paragraphs: [BookSourceDebugHelpLabel] = [
        "调试搜索>>输入关键字，如：",
        "调试发现>>输入发现URL，如：",
        "调试详情页>>输入详情页URL，如：",
        "调试目录页>>输入目录页URL，如：",
        "调试正文页>>输入正文页URL，如：",
    ].map { text in
        let label = BookSourceDebugHelpLabel()
        label.text = text
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = false
        return label
    }
    private let keywordChip = BookSourceDebugHelpChip(text: "我的", identifier: "keyword")
    private let systemChip = BookSourceDebugHelpChip(text: "系统", identifier: "system")
    private let exploreChip = BookSourceDebugHelpChip(text: "系统::http://xxx", identifier: "explore")
    private let detailChip = BookSourceDebugHelpChip(
        text: "https://m.qidian.com/book/1015609210", identifier: "detail")
    private let tocChip = BookSourceDebugHelpChip(
        text: "++https://www.zhaishuyuan.com/read/30394", identifier: "toc")
    private let contentChip = BookSourceDebugHelpChip(
        text: "--https://www.zhaishuyuan.com/chapter/30394/20940996", identifier: "content")

    private var chipGroups: [[BookSourceDebugHelpChip]] {
        [[keywordChip, systemChip], [exploreChip], [detailChip], [tocChip], [contentChip]]
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        scrollView.onScroll = { [weak self] in self?.invalidateChipActions() }
        accessibilityIdentifier = "bookSource.debug.help"
        clipsToBounds = true
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        for (index, paragraph) in paragraphs.enumerated() {
            paragraph.accessibilityIdentifier = "bookSource.debug.help.section.\(index)"
            contentView.addSubview(paragraph)
            for chip in chipGroups[index] { contentView.addSubview(chip) }
        }
        keywordChip.onSelect = { [weak self] in
            guard let self else { return }
            self.onAction?(.keyword(self.keywordChip.text))
        }
        systemChip.onSelect = { [weak self] in self?.onAction?(.keyword("系统")) }
        exploreChip.onSelect = { [weak self] in self?.onAction?(.explore) }
        detailChip.onSelect = { [weak self] in self?.onAction?(.detail) }
        tocChip.onSelect = { [weak self] in self?.onAction?(.toc) }
        contentChip.onSelect = { [weak self] in self?.onAction?(.content) }
        contentView.accessibilityElements = zip(paragraphs, chipGroups).flatMap { paragraph, chips -> [UIView] in
            [paragraph] + chips.map { $0 as UIView }
        }
        applyTypographyAndPalette()
        configure(checkKeyword: "", exploreTitle: nil, exploreError: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setActionsActive(_ active: Bool) {
        guard actionsActive != active else { return }
        actionsActive = active
        for chip in chipGroups.flatMap({ $0 }) { chip.actionsActive = active }
        invalidatePendingActions()
    }

    func invalidatePendingActions() { invalidateChipActions() }

    func configure(checkKeyword: String, exploreTitle: String?, exploreError: String?) {
        invalidateChipActions()
        keywordChip.text = checkKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的" : checkKeyword
        let title = exploreTitle.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let error = exploreError.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let error {
            exploreChip.text = error.hasPrefix("ERROR:") ? error : "ERROR:\(error)"
        } else {
            exploreChip.text = title ?? "系统::http://xxx"
        }
        exploreChip.isEnabled = error == nil && !exploreChip.text.hasPrefix("ERROR:")
        updateExploreLongPress()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(0, size.width)
        return CGSize(width: width, height: min(max(0, size.height), layoutContent(width: width, applyFrames: false)))
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layoutContent(width: bounds.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let height = layoutContent(width: bounds.width, applyFrames: true)
        contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = height > bounds.height
        if !scrollView.isTracking, !scrollView.isDecelerating {
            let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, height - bounds.height)))
            if offset != scrollView.contentOffset { scrollView.setContentOffset(offset, animated: false) }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTypographyAndPalette()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func invalidateChipActions() {
        for chip in chipGroups.flatMap({ $0 }) { chip.invalidateActions() }
    }

    @objc private func refreshPalette() { applyTypographyAndPalette(updateTypography: false) }

    private func applyTypographyAndPalette(updateTypography: Bool = true) {
        let palette = ReaderTocPalette(traits: traitCollection)
        let night = ReaderPaletteColor.isNightResource(traits: traitCollection)
        // The help LinearLayout explicitly uses @color/background, not the decor tint.
        backgroundColor = UIColor(white: CGFloat(night ? 0x21 : 0xF5) / 255, alpha: 1)
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        for paragraph in paragraphs {
            if updateTypography { paragraph.font = font }
            paragraph.textColor = palette.secondaryText
        }
        for chip in chipGroups.flatMap({ $0 }) { chip.apply(font: updateTypography ? font : nil, palette: palette) }
        scrollView.indicatorStyle = ReaderPaletteColor.isNightResource(traits: traitCollection) ? .white : .black
    }

    private func updateExploreLongPress() {
        exploreChip.onLongPress =
            onExploreLongPress == nil || !exploreChip.isEnabled
            ? nil
            : { [weak self] in
                self?.onExploreLongPress?()
            }
    }

    private func layoutContent(width: CGFloat, applyFrames: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        let padding = min(16, width / 2)
        let availableWidth = max(1, width - 2 * padding)
        let margin: CGFloat = 3
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 16
        for (index, paragraph) in paragraphs.enumerated() {
            let paragraphHeight = ceil(
                paragraph.sizeThatFits(
                    CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
                ).height)
            if applyFrames {
                paragraph.frame = CGRect(x: padding, y: y, width: availableWidth, height: paragraphHeight)
            }
            y += paragraphHeight + margin
            var x = margin
            var rowHeight: CGFloat = 0
            for chip in chipGroups[index] {
                // Android's horizontal LinearLayout measures each example in the remaining width.
                let size = chip.sizeThatFits(
                    CGSize(width: max(0, availableWidth - x - margin), height: .greatestFiniteMagnitude))
                if applyFrames {
                    chip.frame = CGRect(
                        x: padding + (rtl ? availableWidth - x - size.width : x),
                        y: y, width: size.width, height: size.height)
                }
                x += size.width + 2 * margin
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + margin
        }
        return y + 16
    }
}

private final class BookSourceDebugHelpChip: UIControl, UIGestureRecognizerDelegate {
    var actionsActive = false {
        didSet { if oldValue != actionsActive { invalidateActions() } }
    }
    var onSelect: (() -> Void)? {
        didSet { invalidateActions() }
    }
    var onLongPress: (() -> Void)? {
        didSet { invalidateActions() }
    }
    var text: String {
        get { label.text ?? "" }
        set {
            invalidateActions()
            label.text = newValue
            accessibilityLabel = newValue
            setNeedsLayout()
        }
    }
    override var isEnabled: Bool {
        didSet {
            invalidateActions()
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            updateLongPress()
        }
    }
    override var isHighlighted: Bool { didSet { updateAppearance() } }

    private var generation = 0
    private var touchGeneration: Int?
    private var longPressGeneration: Int?
    private var observations: [NSKeyValueObservation] = []
    private let label = UILabel()
    private var longPressGesture: UILongPressGestureRecognizer?

    init(text: String, identifier: String) {
        super.init(frame: .zero)
        label.text = text
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        layer.cornerRadius = 16
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityTraits = .button
        accessibilityIdentifier = "bookSource.debug.help.\(identifier)"
        addTarget(self, action: #selector(activate(_:event:)), for: .touchUpInside)
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidateActions), name: name, object: nil)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func apply(font: UIFont?, palette: ReaderTocPalette) {
        if let font { label.font = font }
        label.textColor = palette.primaryText
        updateAppearance()
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(max(0, size.width), ceil(label.intrinsicContentSize.width) + 24)
        let fontPadding = AndroidExploreTextMetrics.padding(font: label.font, scale: traitCollection.displayScale)
        let lineHeight = max(label.font.lineHeight, label.intrinsicContentSize.height)
        return CGSize(width: width, height: ceil(lineHeight) + fontPadding.top + fontPadding.bottom + 8)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalPadding = min(12, max(0, (bounds.width - 1) / 2))
        let fontPadding = AndroidExploreTextMetrics.padding(font: label.font, scale: traitCollection.displayScale)
        label.frame = bounds.inset(
            by: UIEdgeInsets(
                top: 4 + fontPadding.top, left: horizontalPadding,
                bottom: 4 + fontPadding.bottom, right: horizontalPadding))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -3, dy: -3).contains(point)
    }

    override func accessibilityActivate() -> Bool {
        guard canDeliver else { return false }
        onSelect?()
        return true
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        revealBookSourceDebugHelpElement(self)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        invalidateActions()
        observations.removeAll()
        var ancestor: UIView? = self
        while let current = ancestor {
            observations.append(current.observe(\.isHidden, options: [.new]) { [weak self] _, _ in self?.invalidateActions() })
            observations.append(current.observe(\.alpha, options: [.new]) { [weak self] _, _ in self?.invalidateActions() })
            observations.append(current.observe(\.isUserInteractionEnabled, options: [.new]) { [weak self] _, _ in self?.invalidateActions() })
            ancestor = current.superview
        }
    }

    private var canDeliver: Bool {
        guard actionsActive, isEnabled, let window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        var ancestor: UIView? = self
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01, current.isUserInteractionEnabled else { return false }
            if let scroll = current as? UIScrollView,
                scroll.isDragging || scroll.isDecelerating || scroll.panGestureRecognizer.state == .began
                    || scroll.panGestureRecognizer.state == .changed
            {
                return false
            }
            ancestor = current.superview
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let owner = current as? UIViewController {
                guard owner.presentedViewController == nil, !owner.isBeingDismissed,
                    !owner.isBeingPresented, owner.transitionCoordinator == nil
                else { return false }
                if let navigation = owner.navigationController {
                    guard navigation.topViewController === owner, navigation.presentedViewController == nil,
                        navigation.transitionCoordinator == nil
                    else { return false }
                }
                break
            }
            responder = current.next
        }
        return !convert(bounds, to: window).intersection(window.bounds).isEmpty
    }

    @objc func invalidateActions() {
        generation &+= 1
        touchGeneration = nil
        longPressGeneration = nil
        cancelTracking(with: nil)
        isHighlighted = false
        if let gesture = longPressGesture {
            gesture.isEnabled = false
            gesture.isEnabled = onLongPress != nil && isEnabled
        }
        updateLongPress()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard canDeliver else { return false }
        touchGeneration = generation
        return super.beginTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        touchGeneration = nil
        super.cancelTracking(with: event)
    }

    private func updateAppearance() {
        let night = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let value = isHighlighted || isFocused ? (night ? 0x68 : 0x85) : (night ? 0x4D : 0xAC)
        backgroundColor = UIColor(white: CGFloat(value) / 255, alpha: 99.0 / 255)
    }

    private func updateLongPress() {
        if onLongPress != nil, isEnabled {
            if longPressGesture == nil {
                let gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
                gesture.cancelsTouchesInView = true
                gesture.delegate = self
                addGestureRecognizer(gesture)
                longPressGesture = gesture
            }
            longPressGesture?.isEnabled = true
            let configuredGeneration = generation
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "选择发现") { [weak self] _ in
                    guard let self, self.canDeliver, self.generation == configuredGeneration, let action = self.onLongPress else { return false }
                    action()
                    return true
                }
            ]
        } else {
            longPressGesture?.isEnabled = false
            accessibilityCustomActions = nil
        }
    }

    @objc private func activate(_ sender: UIControl, event: UIEvent?) {
        let validTouch = event?.allTouches?.isEmpty != false || touchGeneration == generation
        touchGeneration = nil
        guard canDeliver, validTouch else { return }
        onSelect?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard canDeliver else { return false }
        longPressGeneration = generation
        return true
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, canDeliver, longPressGeneration == generation else { return }
        longPressGeneration = nil
        cancelTracking(with: nil)
        isHighlighted = false
        onLongPress?()
    }
}

private final class BookSourceDebugHelpScrollView: UIScrollView, UIScrollViewDelegate {
    var onScroll: (() -> Void)?

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScroll?() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onScroll?() }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        delaysContentTouches = false
        canCancelContentTouches = true
        isDirectionalLockEnabled = true
        scrollsToTop = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class BookSourceDebugHelpLabel: UILabel {
    private var fontPadding: UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let measured = super.sizeThatFits(size)
        let padding = fontPadding
        return CGSize(width: measured.width, height: ceil(measured.height) + padding.top + padding.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: fontPadding))
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        revealBookSourceDebugHelpElement(self)
    }
}

private func revealBookSourceDebugHelpElement(_ element: UIView) {
    var ancestor = element.superview
    while let current = ancestor {
        if let scrollView = current as? BookSourceDebugHelpScrollView {
            scrollView.scrollRectToVisible(element.convert(element.bounds, to: scrollView).insetBy(dx: 0, dy: -3), animated: false)
            return
        }
        ancestor = current.superview
    }
}
