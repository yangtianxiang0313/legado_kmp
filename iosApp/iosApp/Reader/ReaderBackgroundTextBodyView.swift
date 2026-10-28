import UIKit
import shared

/// BgTextConfigDialog / dialog_read_bg_text.xml at Legado 5f5d314.
/// The host owns actions, preferences, safe-area placement, and the maximum height.
final class ReaderBackgroundTextBodyView: UIView {
    let editNameButton: UIButton = ReaderBackgroundTextBodyIconButton(asset: "BookDetailAndroidEdit", pointSize: 20)
    let restoreButton: UIButton = ReaderBackgroundTextBodyTextButton(title: "恢复")
    let textColorButton: UIButton = ReaderBackgroundTextBodyTextButton(title: "文字颜色", outlined: true)
    let backgroundColorButton: UIButton = ReaderBackgroundTextBodyTextButton(title: "背景颜色", outlined: true)
    let importButton: UIButton = ReaderBackgroundTextBodyIconButton(asset: "BookshelfAndroidImport")
    let exportButton: UIButton = ReaderBackgroundTextBodyIconButton(asset: "BookshelfAndroidExport")
    let deleteButton: UIButton = ReaderBackgroundTextBodyIconButton(asset: "ReaderPresetAndroidDelete")
    let darkStatusSwitch = ReaderAndroidSwitchControl()
    let underlineSwitch = ReaderAndroidSwitchControl()
    let alphaSlider: UISlider = ReaderBackgroundTextBodyAlphaSlider()
    let imageStrip = ReaderBackgroundImageStripView()

    /// The host must capture itself weakly and reject covered, inactive or stale style contexts.
    var canInteract: (() -> Bool)? {
        didSet { if !allowsInteraction { cancelPendingTracking() } }
    }

    var isUnderlineAvailable = true {
        didSet {
            guard oldValue != isUnderlineAvailable else { return }
            underlineRow.cancelPendingTracking()
            underlineSwitch.cancelPendingTracking()
            underlineRow.isHidden = !isUnderlineAvailable
            underlineLabel.isHidden = !isUnderlineAvailable
            underlineSwitch.isHidden = !isUnderlineAvailable
            underlineRow.isEnabled = !isBusy && isUnderlineAvailable
            updateAccessibilityOrder()
            lastReportedContentHeight = nil
            invalidateContentLayout()
        }
    }

    var onContentHeightChange: ((CGFloat) -> Void)? {
        didSet {
            lastReportedContentHeight = nil
            setNeedsLayout()
        }
    }

    private static let outerPadding: CGFloat = 10
    private static let rowPadding: CGFloat = 6
    private static let minimumContentWidth: CGFloat = 180
    private static let imageStripHeight: CGFloat = 100
    private static let identifierPrefix = "readerAppearance.backgroundText."

    private let scrollView = ReaderBackgroundTextBodyScrollView()
    private let contentView = UIView()
    private let nameTitleLabel = UILabel()
    private let nameLabel = UILabel()
    private let darkStatusLabel = UILabel()
    private let underlineLabel = UILabel()
    private let alphaLabel = UILabel()
    private let imageLabel = UILabel()
    private lazy var darkStatusRow = ReaderBackgroundTextBodySwitchRow(label: darkStatusLabel, toggle: darkStatusSwitch)
    private lazy var underlineRow = ReaderBackgroundTextBodySwitchRow(label: underlineLabel, toggle: underlineSwitch)
    private var lastReportedContentHeight: CGFloat?
    private var isBusy = false
    private let transferActivity = UIActivityIndicatorView(style: .medium)

    private static let secondaryText = UIColor { traits in
        let primary = ReaderSearchChromePalette.foreground.resolvedColor(with: traits)
        // BgTextConfigDialog.getSecondaryTextColor(light): #8A000000 or white.
        return primary.cgColor.alpha < 1 ? UIColor(white: 0, alpha: 138.0 / 255) : .white
    }

    func setTransferBusy(_ busy: Bool, exporting: Bool) {
        let button = exporting ? exportButton : importButton
        if busy {
            button.addSubview(transferActivity)
            transferActivity.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                transferActivity.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                transferActivity.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.imageView?.alpha = 0
            transferActivity.startAnimating()
        } else {
            transferActivity.stopAnimating()
            transferActivity.removeFromSuperview()
            button.imageView?.alpha = 1
        }
    }

    private var buttons: [UIButton] {
        [
            editNameButton, restoreButton, textColorButton, backgroundColorButton,
            importButton, exportButton, deleteButton,
        ]
    }

    private var labels: [UILabel] {
        [nameTitleLabel, nameLabel, darkStatusLabel, underlineLabel, alphaLabel, imageLabel]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureContent()
        configureAccessibility()
        updateFonts()
        updatePalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHidden: Bool {
        didSet { if isHidden { cancelPendingTracking() } }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelPendingTracking() } }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { cancelPendingTracking() }
        super.willMove(toWindow: newWindow)
    }

    /// Discard in-flight touches/drafts; never emit valueChanged or persist preferences.
    func cancelPendingTracking() {
        darkStatusRow.cancelPendingTracking()
        underlineRow.cancelPendingTracking()
        darkStatusSwitch.cancelPendingTracking()
        underlineSwitch.cancelPendingTracking()
        (alphaSlider as? ReaderBackgroundTextBodyAlphaSlider)?.cancelPendingTracking()
        imageStrip.cancelPendingTracking()
        for button in buttons {
            let enabled = button.isEnabled
            button.isEnabled = false
            button.cancelTracking(with: nil)
            button.isHighlighted = false
            button.isEnabled = enabled
        }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        if scrollView.isTracking || scrollView.isDragging {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
        }
    }

    private var allowsInteraction: Bool {
        guard !isBusy, canInteract?() != false, let window,
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

    /// Programmatic control updates never send actions or persist preferences.
    func apply(name: String, style: ReaderStylePreferences, isBusy: Bool) {
        self.isBusy = isBusy
        if isBusy { cancelPendingTracking() }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "文字" : name
        nameLabel.text = displayName
        nameLabel.accessibilityValue = displayName
        editNameButton.accessibilityValue = displayName
        darkStatusSwitch.setOn(style.darkStatusIcon, animated: false)
        underlineSwitch.setOn(style.underline, animated: false)
        (alphaSlider as? ReaderBackgroundTextBodyAlphaSlider)?.applyValue(Float(min(max(style.backgroundAlpha, 0), 100)))

        let defaults = AndroidReaderStyleScale.defaultColors(for: style.backgroundMode)
        textColorButton.accessibilityValue = style.textColorHex ?? defaults.text
        backgroundColorButton.accessibilityValue = style.backgroundColorHex ?? defaults.background
        for button in buttons { button.isEnabled = !isBusy }
        darkStatusRow.isEnabled = !isBusy
        underlineRow.isEnabled = !isBusy && isUnderlineAvailable
        alphaSlider.isEnabled = !isBusy
        imageStrip.configure(selectedPath: style.backgroundImagePath, enabled: !isBusy)
        updatePalette()
        invalidateContentLayout()
    }

    func apply(palette _: ReaderMenuPalette) {
        // Keep the host API, but this dialog never follows the reader's page/menu palette.
        updatePalette()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: layoutContent(width: contentWidth(for: bounds.width), applyFrames: false))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : bounds.width
        return CGSize(
            width: max(0, width),
            height: layoutContent(width: contentWidth(for: width), applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 0 else { return }
        let width = contentWidth(for: bounds.width)
        let height = layoutContent(width: width, applyFrames: true)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        scrollView.contentSize = contentView.bounds.size

        // A short host scrolls the full body; its viewport never changes this measurement.
        if lastReportedContentHeight != height {
            lastReportedContentHeight = height
            onContentHeightChange?(height)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFonts()
            lastReportedContentHeight = nil
            invalidateContentLayout()
        }
        updatePalette()
    }

    private func configureContent() {
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.alwaysBounceVertical = false
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        for label in labels {
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = false
            contentView.addSubview(label)
        }
        nameTitleLabel.text = "样式名称："
        nameLabel.text = "文字"
        darkStatusLabel.text = "深色状态栏图标"
        underlineLabel.text = "文字下划线"
        alphaLabel.text = "背景透明度"
        imageLabel.text = "背景图片"
        for button in buttons {
            contentView.addSubview(button)
            if let button = button as? ReaderBackgroundTextBodyTextButton {
                button.canInteract = { [weak self] in self?.allowsInteraction == true }
            } else if let button = button as? ReaderBackgroundTextBodyIconButton {
                button.canInteract = { [weak self] in self?.allowsInteraction == true }
            }
        }
        for row in [darkStatusRow, underlineRow] {
            contentView.addSubview(row)
            row.canInteract = { [weak self] in self?.allowsInteraction == true }
        }
        darkStatusSwitch.canInteract = { [weak self] in self?.allowsInteraction == true }
        underlineSwitch.canInteract = { [weak self] in self?.allowsInteraction == true && self?.isUnderlineAvailable == true }
        alphaSlider.minimumValue = 0
        alphaSlider.maximumValue = 100
        alphaSlider.isContinuous = true
        (alphaSlider as? ReaderBackgroundTextBodyAlphaSlider)?.canInteract = { [weak self] in self?.allowsInteraction == true }
        contentView.addSubview(alphaSlider)
        contentView.addSubview(imageStrip)
        imageStrip.canInteract = { [weak self] in self?.allowsInteraction == true }
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentWillDeactivate(_:)), name: name, object: nil)
        }
    }

    private func configureAccessibility() {
        accessibilityIdentifier = Self.identifierPrefix + "body"
        scrollView.accessibilityIdentifier = Self.identifierPrefix + "scrollView"
        for label in labels { label.isAccessibilityElement = false }
        nameLabel.isAccessibilityElement = true
        nameLabel.accessibilityIdentifier = Self.identifierPrefix + "name"
        nameLabel.accessibilityLabel = "样式名称"
        nameLabel.accessibilityValue = nameLabel.text

        let entries: [(UIView, String, String, String)] = [
            (editNameButton, "editNameButton", "编辑样式名称", "修改当前方案的名称"),
            (restoreButton, "restoreButton", "恢复", "选择预设布局"),
            (darkStatusRow, "darkStatusSwitch", "深色状态栏图标", "切换状态栏图标的深浅"),
            (underlineRow, "underlineSwitch", "文字下划线", "切换正文下划线"),
            (textColorButton, "textColorButton", "文字颜色", "选择正文文字颜色"),
            (backgroundColorButton, "backgroundColorButton", "背景颜色", "选择阅读背景颜色"),
            (importButton, "importButton", "导入方案", "导入阅读样式配置"),
            (exportButton, "exportButton", "导出方案", "导出当前阅读样式配置"),
            (deleteButton, "deleteButton", "删除方案", "删除当前阅读样式配置"),
            (alphaSlider, "alphaSlider", "背景透明度", "调整范围为百分之零至百分之一百"),
        ]
        for (view, identifier, title, hint) in entries {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = Self.identifierPrefix + identifier
            view.accessibilityLabel = title
            view.accessibilityHint = hint
            view.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        }
        alphaLabel.accessibilityIdentifier = Self.identifierPrefix + "alphaLabel"
        imageLabel.accessibilityIdentifier = Self.identifierPrefix + "imageLabel"
        imageStrip.accessibilityIdentifier = Self.identifierPrefix + "imageStrip"
        // Keep the strip as a container so its import and image actions stay individually reachable.
        imageStrip.isAccessibilityElement = false
        updateAccessibilityOrder()
    }

    private func updateAccessibilityOrder() {
        var elements: [UIView] = [nameLabel, editNameButton, restoreButton, darkStatusRow]
        if isUnderlineAvailable { elements.append(underlineRow) }
        elements += [textColorButton, backgroundColorButton, importButton, exportButton, deleteButton, alphaSlider, imageStrip]
        contentView.accessibilityElements = elements
    }

    private func updateFonts() {
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: traitCollection)
        for label in labels { label.font = font }
        nameTitleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 16), compatibleWith: traitCollection)
        for button in buttons { button.titleLabel?.font = font }
    }

    private func updatePalette() {
        let primary = ReaderSearchChromePalette.foreground
        let secondary = Self.secondaryText
        backgroundColor = AndroidReplicaTheme.bottomBackground
        for label in labels { label.textColor = primary }
        nameLabel.textColor = secondary
        for button in buttons {
            button.tintColor = button === editNameButton ? secondary : primary
            if let textButton = button as? ReaderBackgroundTextBodyTextButton {
                textButton.apply(foreground: primary)
            }
        }
        let accent = AndroidReplicaTheme.accent
        for toggle in [darkStatusSwitch, underlineSwitch] {
            toggle.onTintColor = accent
        }
        (alphaSlider as? ReaderBackgroundTextBodyAlphaSlider)?.applyAppearance()
        imageStrip.tintColor = primary
    }

    private func invalidateContentLayout() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func contentWidth(for width: CGFloat) -> CGFloat {
        width.isFinite ? max(Self.minimumContentWidth, width) : Self.minimumContentWidth
    }

    private func measuredSize(_ view: UIView, width: CGFloat) -> CGSize {
        let size = view.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        return CGSize(width: min(max(1, width), ceil(size.width)), height: ceil(size.height))
    }

    private func layoutContent(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let outer = Self.outerPadding
        let padding = Self.rowPadding
        let x = outer + padding
        let innerWidth = width - x * 2
        var y = outer

        func place(_ view: UIView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            if applyFrames { view.frame = CGRect(x: x, y: y, width: width, height: height) }
        }

        // Preserve the Android order, moving the actual name and actions onto more lines as needed.
        let titleSize = measuredSize(nameTitleLabel, width: innerWidth)
        let nameSize = measuredSize(nameLabel, width: innerWidth)
        let restoreSize = measuredSize(restoreButton, width: innerWidth)
        let editWidth: CGFloat = 20
        y += padding
        if titleSize.width + nameSize.width + editWidth + restoreSize.width + 24 <= innerWidth {
            let height = max(20, max(titleSize.height, max(nameSize.height, restoreSize.height)))
            place(nameTitleLabel, x: x, y: y, width: titleSize.width, height: height)
            let nameX = x + titleSize.width + padding
            place(nameLabel, x: nameX, y: y, width: nameSize.width, height: height)
            place(
                editNameButton, x: nameX + nameSize.width + padding,
                y: y + (height - 20) / 2, width: editWidth, height: 20)
            place(
                restoreButton, x: width - x - restoreSize.width, y: y,
                width: restoreSize.width, height: height)
            y += height
        } else {
            place(nameTitleLabel, x: x, y: y, width: innerWidth, height: titleSize.height)
            y += titleSize.height + padding
            let restoreFits = nameSize.width + editWidth + restoreSize.width + 18 <= innerWidth
            let nameWidth = restoreFits ? nameSize.width : innerWidth - editWidth - padding
            let height = max(
                20,
                max(
                    measuredSize(nameLabel, width: nameWidth).height,
                    restoreFits ? restoreSize.height : 0))
            place(nameLabel, x: x, y: y, width: nameWidth, height: height)
            place(
                editNameButton, x: x + nameWidth + padding,
                y: y + (height - 20) / 2, width: editWidth, height: 20)
            if restoreFits {
                place(
                    restoreButton, x: width - x - restoreSize.width, y: y,
                    width: restoreSize.width, height: height)
            }
            y += height
            if !restoreFits {
                y += padding * 2
                place(
                    restoreButton, x: width - x - restoreSize.width, y: y,
                    width: restoreSize.width, height: restoreSize.height)
                y += restoreSize.height
            }
        }
        y += padding

        // ThemeSwitch wraps its 27dp artwork/14sp text in 6dp padding, not a 48dp row.
        for row in (isUnderlineAvailable ? [darkStatusRow, underlineRow] : [darkStatusRow]) {
            let rowWidth = width - outer * 2
            let height = row.sizeThatFits(CGSize(width: rowWidth, height: .greatestFiniteMagnitude)).height
            place(row, x: outer, y: y, width: rowWidth, height: height)
            y += height
        }

        // Each Android color/action child has its own 6pt horizontal margin.
        let colorX = x + padding
        let colorWidth = innerWidth - padding * 2
        let gap = padding * 2
        let colors = [textColorButton, backgroundColorButton]
        let actions = [importButton, exportButton, deleteButton]
        let naturalColorWidth = colors.map { measuredSize($0, width: colorWidth).width }.max() ?? 0
        let actionWidth: CGFloat = 36
        y += padding
        if naturalColorWidth * 2 + actionWidth * 3 + gap * 4 <= colorWidth {
            let buttonWidth = (colorWidth - actionWidth * 3 - gap * 4) / 2
            let height = max(36, colors.map { measuredSize($0, width: buttonWidth).height }.max() ?? 0)
            for (index, button) in colors.enumerated() {
                place(
                    button, x: colorX + CGFloat(index) * (buttonWidth + gap), y: y,
                    width: buttonWidth, height: height)
            }
            let actionX = colorX + (buttonWidth + gap) * 2
            for (index, button) in actions.enumerated() {
                place(
                    button, x: actionX + CGFloat(index) * (actionWidth + gap),
                    y: y + (height - 36) / 2, width: actionWidth, height: 36)
            }
            y += height
        } else {
            let separateColors = naturalColorWidth * 2 + gap > colorWidth
            let buttonWidth = separateColors ? colorWidth : (colorWidth - gap) / 2
            let height = colors.map { measuredSize($0, width: buttonWidth).height }.max() ?? 36
            for (index, button) in colors.enumerated() {
                place(
                    button, x: colorX + (separateColors ? 0 : CGFloat(index) * (buttonWidth + gap)),
                    y: y + (separateColors ? CGFloat(index) * (height + gap) : 0),
                    width: buttonWidth, height: height)
            }
            y += separateColors ? height * 2 + gap : height
            y += gap
            for (index, button) in actions.enumerated() {
                place(
                    button, x: colorX + CGFloat(index) * (actionWidth + gap), y: y,
                    width: actionWidth, height: 36)
            }
            y += 36
        }
        y += padding

        let alphaHeight = measuredSize(alphaLabel, width: innerWidth).height
        place(alphaLabel, x: x, y: y, width: innerWidth, height: alphaHeight)
        y += alphaHeight
        // The XML's 6dp SeekBar padding replaces AppCompat's 16dp horizontal default.
        place(alphaSlider, x: outer, y: y, width: width - outer * 2, height: 30)
        y += 30
        let imageHeight = measuredSize(imageLabel, width: innerWidth).height
        place(imageLabel, x: x, y: y, width: innerWidth, height: imageHeight)
        y += imageHeight
        place(imageStrip, x: outer, y: y, width: width - outer * 2, height: Self.imageStripHeight)
        return ceil(y + Self.imageStripHeight + outer)
    }
}

private final class ReaderBackgroundTextBodyTextButton: UIButton {
    var canInteract: (() -> Bool)?
    private let outlined: Bool
    private var foreground: UIColor = .label

    init(title: String, outlined: Bool = false) {
        self.outlined = outlined
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.numberOfLines = 0
        titleLabel?.lineBreakMode = .byCharWrapping
        titleLabel?.textAlignment = .center
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.adjustsFontSizeToFitWidth = false
        layer.cornerRadius = 1
        layer.borderWidth = outlined ? 1 : 0
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool { didSet { refreshAppearance() } }
    override var isHighlighted: Bool { didSet { refreshAppearance() } }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearance()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard canInteract?() != false else { return false }
        return super.beginTracking(touch, with: event)
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard isEnabled, !isHidden, canInteract?() != false else { return }
        super.sendAction(action, to: target, for: event)
    }

    func apply(foreground: UIColor) {
        self.foreground = foreground
        refreshAppearance()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleSize =
            titleLabel?.sizeThatFits(
                CGSize(width: max(1, size.width - (outlined ? 12 : 0)), height: .greatestFiniteMagnitude)) ?? .zero
        let padding: CGFloat = outlined ? 12 : 0
        return CGSize(width: ceil(titleSize.width) + padding, height: ceil(titleSize.height) + padding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel?.frame = outlined ? bounds.insetBy(dx: 6, dy: 6) : bounds
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func refreshAppearance() {
        let color = isEnabled ? foreground : (outlined ? UIColor(white: 158.0 / 255, alpha: 1) : foreground.withAlphaComponent(0.38))
        setTitleColor(color, for: .normal)
        setTitleColor(color, for: .disabled)
        if outlined { layer.borderColor = color.resolvedColor(with: traitCollection).cgColor }
        backgroundColor =
            isHighlighted && outlined
            ? UIColor(white: traitCollection.userInterfaceStyle == .dark ? 1 : 0, alpha: 48.0 / 255) : .clear
    }
}

private final class ReaderBackgroundTextBodyIconButton: UIButton {
    var canInteract: (() -> Bool)?
    private let pointSize: CGFloat

    init(asset: String, pointSize: CGFloat = 36) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        setImage(UIImage(named: asset)?.withRenderingMode(.alwaysTemplate), for: .normal)
        imageView?.contentMode = .scaleAspectFit
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(x: contentRect.midX - pointSize / 2, y: contentRect.midY - pointSize / 2, width: pointSize, height: pointSize)
    }

    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.38 } }
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? tintColor.withAlphaComponent(0.12) : .clear } }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard canInteract?() != false else { return false }
        return super.beginTracking(touch, with: event)
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard isEnabled, !isHidden, canInteract?() != false else { return }
        super.sendAction(action, to: target, for: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.insetBy(dx: -4, dy: -4).contains(point)
    }
}

private final class ReaderBackgroundTextBodyScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class ReaderBackgroundTextBodySwitchRow: UIControl {
    var canInteract: (() -> Bool)?
    private let label: UILabel
    private let toggle: ReaderAndroidSwitchControl
    private var trackingTouch: UITouch?
    private var touchOrigin = CGPoint.zero

    init(label: UILabel, toggle: ReaderAndroidSwitchControl) {
        self.label = label
        self.toggle = toggle
        super.init(frame: .zero)
        addSubview(label)
        addSubview(toggle)
        label.isAccessibilityElement = false
        toggle.isAccessibilityElement = false
        toggle.accessibilityElementsHidden = true
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet {
            toggle.isEnabled = isEnabled
            if !isEnabled { cancelPendingTracking() }
        }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { toggle.accessibilityTraits }
        set {}
    }

    override var accessibilityValue: String? {
        get { toggle.accessibilityValue }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard allowsInteraction, trackingTouch == nil else { return false }
        return toggle.accessibilityActivate()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let toggleSize = toggle.sizeThatFits(.zero)
        let labelWidth = max(1, size.width - 12 - toggleSize.width - 6)
        let textHeight = label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(width: size.width, height: ceil(max(textHeight, toggleSize.height)) + 12)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let toggleSize = toggle.sizeThatFits(.zero)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let labelWidth = max(0, bounds.width - 12 - toggleSize.width - 6)
        label.frame = CGRect(
            x: isRTL ? 6 + toggleSize.width + 6 : 6, y: 6,
            width: labelWidth, height: max(0, bounds.height - 12))
        toggle.frame = CGRect(
            x: isRTL ? 6 : bounds.width - 6 - toggleSize.width,
            y: bounds.midY - toggleSize.height / 2,
            width: toggleSize.width, height: toggleSize.height)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingTouch == nil, allowsInteraction else { return false }
        trackingTouch = touch
        touchOrigin = touch.location(in: self)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        guard trackingTouch === touch, allowsInteraction,
            abs(point.x - touchOrigin.x) <= 8, abs(point.y - touchOrigin.y) <= 8
        else {
            cancelPendingTracking()
            return false
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let accepted =
            touch.map {
                trackingTouch === $0 && allowsInteraction && bounds.contains($0.location(in: self))
            } ?? false
        trackingTouch = nil
        super.endTracking(touch, with: event)
        if accepted { _ = toggle.accessibilityActivate() }
    }

    override func cancelTracking(with event: UIEvent?) {
        trackingTouch = nil
        super.cancelTracking(with: event)
    }

    func cancelPendingTracking() {
        trackingTouch = nil
        isHighlighted = false
        super.cancelTracking(with: nil)
    }

    private var allowsInteraction: Bool {
        isEnabled && !isHidden && isUserInteractionEnabled && canInteract?() != false
    }
}

private final class ReaderBackgroundTextBodyAlphaSlider: UISlider {
    var canInteract: (() -> Bool)? {
        didSet { if !allowsInteraction { cancelPendingTracking() } }
    }
    private var authoritativeValue: Float = 0
    private var trackingTouch: UITouch?
    private var isAccessibilityAdjusting = false
    private var isCancelling = false

    override var alignmentRectInsets: UIEdgeInsets { .zero }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    func applyValue(_ value: Float) {
        let value = min(max(value, minimumValue), maximumValue)
        if trackingTouch != nil, value != self.value.rounded() { cancelPendingTracking() }
        authoritativeValue = value
        super.setValue(value, animated: false)
    }

    func applyAppearance() {
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        let inactive = ReaderSearchChromePalette.foreground.resolvedColor(with: traitCollection).withAlphaComponent(0.3)
        let disabled = UIColor(
            white: traitCollection.userInterfaceStyle == .dark ? 1 : 0,
            alpha: traitCollection.userInterfaceStyle == .dark ? 77.0 / 255 : 67.0 / 255)
        func track(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            }.resizableImage(withCapInsets: .zero)
        }
        func thumb(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { _ in
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12, height: 12)).fill()
            }
        }
        // Same 2dp/12dp artwork as AndroidReaderStyleSliderRow's compact SeekBar.
        for state in [UIControl.State.normal, .highlighted] {
            setMinimumTrackImage(track(accent), for: state)
            setMaximumTrackImage(track(inactive), for: state)
            setThumbImage(thumb(accent), for: state)
        }
        setMinimumTrackImage(track(disabled), for: .disabled)
        setMaximumTrackImage(track(inactive), for: .disabled)
        setThumbImage(thumb(disabled), for: .disabled)
    }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let inset = min(6, max(0, bounds.width / 2))
        return CGRect(
            x: bounds.minX + inset, y: bounds.midY - 1,
            width: max(0, bounds.width - inset * 2), height: 2)
    }

    override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
        let fraction = maximumValue > minimumValue ? CGFloat((value - minimumValue) / (maximumValue - minimumValue)) : 0
        let progress = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - fraction : fraction
        return CGRect(x: rect.minX + rect.width * min(1, max(0, progress)) - 6, y: rect.midY - 6, width: 12, height: 12)
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { cancelPendingTracking() } }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingTouch == nil, allowsInteraction else { return false }
        trackingTouch = touch
        guard super.beginTracking(touch, with: event), allowsInteraction else {
            cancelPendingTracking()
            return false
        }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingTouch === touch, allowsInteraction else {
            cancelPendingTracking()
            return false
        }
        let accepted = super.continueTracking(touch, with: event)
        if !accepted || !allowsInteraction {
            cancelPendingTracking()
            return false
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let touch, trackingTouch === touch, allowsInteraction else {
            cancelPendingTracking()
            return
        }
        super.endTracking(touch, with: event)
        trackingTouch = nil
    }

    override func cancelTracking(with event: UIEvent?) { cancelPendingTracking() }

    func cancelPendingTracking() {
        guard !isCancelling else { return }
        isCancelling = true
        trackingTouch = nil
        isAccessibilityAdjusting = false
        super.cancelTracking(with: nil)
        super.setValue(authoritativeValue, animated: false)
        isHighlighted = false
        isCancelling = false
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard !isCancelling, allowsInteraction, trackingTouch != nil || isAccessibilityAdjusting else { return }
        super.sendAction(action, to: target, for: event)
    }

    override var accessibilityValue: String? {
        get { "\(Int(value.rounded()))%" }
        set {}
    }

    override func accessibilityIncrement() { adjust(by: 1) }
    override func accessibilityDecrement() { adjust(by: -1) }

    private func adjust(by delta: Float) {
        guard allowsInteraction, trackingTouch == nil else { return }
        let next = min(max(value.rounded() + delta, minimumValue), maximumValue)
        guard next != value else { return }
        isAccessibilityAdjusting = true
        defer { isAccessibilityAdjusting = false }
        super.setValue(next, animated: false)
        sendActions(for: .valueChanged)
    }

    private var allowsInteraction: Bool {
        isEnabled && !isHidden && isUserInteractionEnabled && canInteract?() != false
    }
}
