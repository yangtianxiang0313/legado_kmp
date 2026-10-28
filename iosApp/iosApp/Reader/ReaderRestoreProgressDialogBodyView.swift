import UIKit

/// AndroidAlertBuilder / applyTint and AppCompat 1.7.1 abc_alert_dialog_*_material.
@MainActor
final class ReaderRestoreProgressDialogBodyView: UIView {
    var onDecision: ((Bool) -> Void)?
    var accessibilityHeading: UIView { titleLabel }

    var isEditingEnabled = false {
        didSet {
            scrollView.isUserInteractionEnabled = isEditingEnabled
            cancelControl.isEnabled = isEditingEnabled && !cancelControl.isHidden
            confirmControl.isEnabled = isEditingEnabled
        }
    }

    private struct Metrics {
        let titleHeight: CGFloat
        let messageHeight: CGFloat
        let cancelWidth: CGFloat
        let confirmWidth: CGFloat
        let cancelHeight: CGFloat
        let confirmHeight: CGFloat
        let stackedActions: Bool

        var headerHeight: CGFloat { 18 + titleHeight + 8 }
        var messagePanelHeight: CGFloat { max(48, messageHeight) }
        var footerHeight: CGFloat {
            4 + (stackedActions ? confirmHeight + cancelHeight : max(cancelHeight, confirmHeight)) + 4
        }
        var totalHeight: CGFloat { headerHeight + messagePanelHeight + footerHeight }
    }

    private let titleLabel = AndroidExploreTextLabel()
    private let messageLabel = AndroidExploreTextLabel()
    private let scrollView = ReaderRestoreProgressDialogScrollView()
    private let scrollContent = UIView()
    private let actionsView = UIView()
    private let cancelControl = ReaderRestoreProgressDialogAction(title: "否")
    private let confirmControl: ReaderRestoreProgressDialogAction
    private var scrollsChrome = false
    private let accessibilityIdentifierPrefix: String
    private let actionLayout: ReaderRestoreProgressDialogViewController.ActionLayout

    init(
        title: String, message: String, confirmTitle: String = "是",
        accessibilityIdentifierPrefix: String = "reader.restoreProgress",
        actionLayout: ReaderRestoreProgressDialogViewController.ActionLayout = .yesNo
    ) {
        self.accessibilityIdentifierPrefix = accessibilityIdentifierPrefix
        self.actionLayout = actionLayout
        confirmControl = ReaderRestoreProgressDialogAction(title: actionLayout == .yesNo ? confirmTitle : "重试")
        super.init(frame: .zero)
        // applyTint uses ThemeStore.backgroundColor / accentColor and a 3dp filletBackground.
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        configure(titleLabel, text: title, identifier: "title")
        configure(messageLabel, text: message, identifier: "message")
        titleLabel.accessibilityTraits = .header
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "\(accessibilityIdentifierPrefix).content"
        cancelControl.isHidden = actionLayout == .retry
        cancelControl.accessibilityIdentifier = actionLayout == .yesNo ? "\(accessibilityIdentifierPrefix).no" : nil
        confirmControl.accessibilityIdentifier = "\(accessibilityIdentifierPrefix).\(actionLayout == .yesNo ? "yes" : "retry")"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(actionsView)
        scrollView.addSubview(scrollContent)
        scrollContent.addSubview(messageLabel)
        actionsView.addSubview(cancelControl)
        actionsView.addSubview(confirmControl)
        actionsView.accessibilityElements =
            actionLayout == .yesNo
            ? [cancelControl, confirmControl] : [confirmControl]
        applyFonts(traits: traitCollection)
        cancelControl.isEnabled = false
        confirmControl.isEnabled = false
        scrollView.isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traits)
        messageLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traits)
        let actionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traits)
        cancelControl.apply(font: actionFont)
        confirmControl.apply(font: actionFont)
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: metrics(width: size.width).totalHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0, bounds.height > 0 else { return }
        let values = metrics(width: width)
        let textInset = min(24, max(0, (width - 1) / 2))
        let textWidth = max(1, width - textInset * 2)
        // Normally only the message scrolls, like AlertDialog's contentPanel. Tiny windows
        // scroll the entire dialog rather than sacrifice the title or 48pt action targets.
        let shouldScrollChrome = values.headerHeight + values.footerHeight + 48 > bounds.height
        let previousOffset = shouldScrollChrome == scrollsChrome ? scrollView.contentOffset.y : 0
        scrollsChrome = shouldScrollChrome
        let chromeParent = scrollsChrome ? scrollContent : self
        if titleLabel.superview !== chromeParent { chromeParent.addSubview(titleLabel) }
        if actionsView.superview !== chromeParent { chromeParent.addSubview(actionsView) }
        titleLabel.frame = CGRect(x: textInset, y: 18, width: textWidth, height: values.titleHeight)

        let messageY: CGFloat
        let footerY: CGFloat
        let scrollHeight: CGFloat
        let contentHeight: CGFloat
        if scrollsChrome {
            messageY = values.headerHeight
            footerY = messageY + values.messagePanelHeight
            scrollHeight = bounds.height
            contentHeight = values.totalHeight
            scrollView.frame = bounds
            scrollContent.accessibilityElements = [titleLabel, messageLabel, actionsView]
            accessibilityElements = [scrollView]
        } else {
            messageY = 0
            footerY = bounds.height - values.footerHeight
            scrollHeight = max(0, footerY - values.headerHeight)
            contentHeight = values.messagePanelHeight
            scrollView.frame = CGRect(x: 0, y: values.headerHeight, width: width, height: scrollHeight)
            scrollContent.accessibilityElements = [messageLabel]
            accessibilityElements = [titleLabel, scrollView, actionsView]
        }
        messageLabel.frame = CGRect(
            x: textInset, y: messageY, width: textWidth, height: values.messageHeight)
        actionsView.frame = CGRect(x: 0, y: footerY, width: width, height: values.footerHeight)
        arrangeActions(width: width, values: values)
        scrollContent.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = scrollContent.bounds.size
        scrollView.isScrollEnabled = contentHeight > scrollHeight
        let offset = CGPoint(x: 0, y: min(max(0, previousOffset), max(0, contentHeight - scrollHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
    }

    private func configure(_ label: UILabel, text: String, identifier: String) {
        label.text = text
        label.textColor = AndroidReplicaTheme.primaryText
        label.textAlignment = .natural
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = false
        label.accessibilityIdentifier = "\(accessibilityIdentifierPrefix).\(identifier)"
    }

    private func metrics(width: CGFloat) -> Metrics {
        let textInset = min(24, max(0, (width - 1) / 2))
        let textSize = CGSize(width: max(1, width - textInset * 2), height: .greatestFiniteMagnitude)
        let actionInset = min(12, max(0, (width - 1) / 2))
        let actionWidth = max(1, width - actionInset * 2)
        let cancelWidth = cancelControl.isHidden ? 0 : cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        let stacked = actionLayout == .yesNo && cancelWidth + confirmWidth > actionWidth
        let cancelSize = CGSize(width: stacked ? actionWidth : cancelWidth, height: .greatestFiniteMagnitude)
        let confirmSize = CGSize(width: stacked ? actionWidth : min(confirmWidth, actionWidth), height: .greatestFiniteMagnitude)
        // Include TextView's font padding before rounding the complete text block up.
        return Metrics(
            titleHeight: ceil(titleLabel.sizeThatFits(textSize).height),
            messageHeight: ceil(messageLabel.sizeThatFits(textSize).height),
            cancelWidth: cancelWidth, confirmWidth: confirmWidth,
            cancelHeight: cancelControl.isHidden ? 0 : cancelControl.sizeThatFits(cancelSize).height,
            confirmHeight: confirmControl.sizeThatFits(confirmSize).height,
            stackedActions: stacked)
    }

    private func arrangeActions(width: CGFloat, values: Metrics) {
        // abc_alert_dialog_button_bar_material: 12dp sides, 4dp top/bottom, no inter-button gap.
        let inset = min(12, max(0, (width - 1) / 2))
        let actionWidth = max(1, width - inset * 2)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if actionLayout == .retry {
            // AppCompat's alertDialogCenterButtons=false leaves the sole neutral action at start.
            let retryWidth = min(values.confirmWidth, actionWidth)
            confirmControl.frame = CGRect(
                x: isRTL ? width - inset - retryWidth : inset, y: 4,
                width: retryWidth, height: values.confirmHeight)
            cancelControl.frame = .zero
            actionsView.accessibilityElements = [confirmControl]
            return
        }
        if values.stackedActions {
            // AppCompat ButtonBarLayout reverses children when stacked: positive above negative.
            confirmControl.frame = CGRect(x: inset, y: 4, width: actionWidth, height: values.confirmHeight)
            cancelControl.frame = CGRect(
                x: inset, y: 4 + values.confirmHeight, width: actionWidth, height: values.cancelHeight)
            actionsView.accessibilityElements = [confirmControl, cancelControl]
        } else {
            let height = max(values.cancelHeight, values.confirmHeight)
            let confirmX = isRTL ? inset : width - inset - values.confirmWidth
            let cancelX = isRTL ? confirmX + values.confirmWidth : confirmX - values.cancelWidth
            confirmControl.frame = CGRect(x: confirmX, y: 4, width: values.confirmWidth, height: height)
            cancelControl.frame = CGRect(x: cancelX, y: 4, width: values.cancelWidth, height: height)
            actionsView.accessibilityElements = [cancelControl, confirmControl]
        }
    }

    @objc private func cancel() {
        guard isEditingEnabled else { return }
        onDecision?(false)
    }

    @objc private func confirm() {
        guard isEditingEnabled else { return }
        onDecision?(true)
    }
}

@MainActor
private final class ReaderRestoreProgressDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

@MainActor
private final class ReaderRestoreProgressDialogAction: UIControl {
    private let label = AndroidExploreTextLabel()
    private let pressedBackground = UIView()
    // btn_default_mtrl_shape: 4/6dp drawable insets plus 8/4dp shape padding.
    private let contentInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    init(title: String) {
        super.init(frame: .zero)
        label.text = title.uppercased(with: Locale.current)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        pressedBackground.isUserInteractionEnabled = false
        pressedBackground.isAccessibilityElement = false
        pressedBackground.layer.cornerRadius = 2
        addSubview(pressedBackground)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHighlighted = false }
            updateAppearance()
        }
    }

    override var isHighlighted: Bool { didSet { updateAppearance() } }

    var preferredWidth: CGFloat {
        max(
            64,
            ceil(
                label.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                ).width + contentInsets.left + contentInsets.right))
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textHeight = ceil(
            label.sizeThatFits(
                CGSize(width: max(1, size.width - horizontalInset(for: size.width) * 2), height: .greatestFiniteMagnitude)
            ).height)
        return CGSize(width: size.width, height: max(48, ceil(textHeight + contentInsets.top + contentInsets.bottom)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = horizontalInset(for: bounds.width)
        label.frame = CGRect(
            x: inset, y: contentInsets.top, width: max(1, bounds.width - inset * 2),
            height: max(0, bounds.height - contentInsets.top - contentInsets.bottom))
        // Material's ripple mask is inset, not the entire rectangular touch target.
        pressedBackground.frame = bounds.insetBy(
            dx: min(4, bounds.width / 2), dy: min(6, bounds.height / 2))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, isUserInteractionEnabled, window != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func horizontalInset(for width: CGFloat) -> CGFloat {
        min(contentInsets.left, max(0, (width - 1) / 2))
    }

    private func updateAppearance() {
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        // applyTint's Selector has no disabled override: disabled text stays accent-colored.
        let pressed = isEnabled && isHighlighted
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        if pressed, accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            // DialogExtensions.applyTint -> ColorUtils.darkenColor (HSV value * 0.9).
            label.textColor = UIColor(hue: hue, saturation: saturation, brightness: brightness * 0.9, alpha: alpha)
        } else {
            label.textColor = accent
        }
        pressedBackground.backgroundColor = pressed ? AndroidReplicaTheme.activeIndicator : .clear
    }
}
