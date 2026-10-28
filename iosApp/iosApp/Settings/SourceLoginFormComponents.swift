import UIKit
import shared

@MainActor
final class SourceLoginInputView: UIStackView, UITextFieldDelegate {
    private let field = UITextField()
    private let textView = UITextView()
    private let label = UILabel()
    private let underline = UIView()
    private let password: Bool
    var onReturn: (() -> Void)?

    var value: String {
        get { password ? field.text ?? "" : textView.text ?? "" }
        set {
            if password { field.text = newValue } else { textView.text = newValue }
        }
    }

    var returnKeyType: UIReturnKeyType {
        get { field.returnKeyType }
        set { field.returnKeyType = newValue }
    }

    init(name: String, value: String, password: Bool) {
        self.password = password
        super.init(frame: .zero)
        axis = .vertical
        spacing = 3
        label.text = name
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addArrangedSubview(label)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 14))
        if password {
            field.text = value
            field.accessibilityLabel = name
            field.font = font
            field.adjustsFontForContentSizeCategory = true
            field.borderStyle = .none
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.returnKeyType = .next
            field.delegate = self
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            addArrangedSubview(field)
        } else {
            // item_source_edit.xml uses textMultiLine; Return must not submit the form.
            textView.text = value
            textView.accessibilityLabel = name
            textView.font = font
            textView.adjustsFontForContentSizeCategory = true
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
            textView.textContainer.lineFragmentPadding = 0
            textView.autocorrectionType = .no
            textView.autocapitalizationType = .none
            textView.spellCheckingType = .no
            textView.smartQuotesType = .no
            textView.smartDashesType = .no
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            addArrangedSubview(textView)
        }
        underline.heightAnchor.constraint(equalToConstant: 1).isActive = true
        addArrangedSubview(underline)
        applyPalette()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func applyPalette() {
        label.textColor = AndroidReplicaTheme.accent
        field.textColor = AndroidReplicaTheme.primaryText
        field.tintColor = AndroidReplicaTheme.accent
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        underline.backgroundColor = AndroidReplicaTheme.divider
    }

    func commitEditing() {
        if password { field.unmarkText() } else { textView.unmarkText() }
    }

    func focus() {
        if password { field.becomeFirstResponder() } else { textView.becomeFirstResponder() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return true
    }
}

@MainActor
final class SourceLoginFormScrollView: UIScrollView {
    override var contentSize: CGSize {
        didSet {
            if contentSize.height != oldValue.height { invalidateIntrinsicContentSize() }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }
}

/// Android applies FlexChildStyle only to buttons. Text/password inputs remain full-width rows.
@MainActor
final class SourceLoginButtonFlowView: UIView {
    private struct Item {
        let button: UIButton
        let grow: CGFloat
        let shrink: CGFloat
        let basis: CGFloat
        let wrapBefore: Bool
        let alignment: String
    }

    private var items: [Item] = []
    private let gap: CGFloat = 8
    private var measuredWidth: CGFloat = 0

    func add(row: SourceLoginRow, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = row.name
        configuration.baseForegroundColor = AndroidReplicaTheme.primaryText
        configuration.background.backgroundColor = AndroidReplicaTheme.menuBackground
        configuration.background.cornerRadius = 16
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
            return attributes
        }
        button.configuration = configuration
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = AndroidReplicaTheme.primaryText
            button.configuration?.background.backgroundColor =
                button.isHighlighted
                ? AndroidReplicaTheme.activeIndicator : AndroidReplicaTheme.menuBackground
        }
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = row.name
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        let style = row.style
        items.append(
            Item(
                button: button,
                grow: Self.number(style?.layout_flexGrow ?? 0, fallback: 0),
                shrink: Self.number(style?.layout_flexShrink ?? 1, fallback: 1),
                basis: Self.number(style?.layout_flexBasisPercent ?? -1, fallback: -1),
                wrapBefore: style?.layout_wrapBefore ?? false,
                alignment: style?.layout_alignSelf ?? "auto"))
        addSubview(button)
        invalidateIntrinsicContentSize()
    }

    func setEnabled(_ enabled: Bool) {
        for item in items { item.button.isEnabled = enabled }
    }

    func applyPalette() {
        for item in items { item.button.setNeedsUpdateConfiguration() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: arrange(width: max(bounds.width, 1), apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        _ = arrange(width: max(bounds.width, 1), apply: true)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyPalette()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var lines: [[(Item, CGFloat)]] = []
        var line: [(Item, CGFloat)] = []
        var occupied: CGFloat = 0
        for item in items {
            let natural = item.button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).width
            let basis = item.basis >= 0 ? width * min(item.basis, 1) : natural
            let itemWidth = min(width, max(44, basis)) + 6
            if !line.isEmpty && (item.wrapBefore || occupied + gap + itemWidth > width) {
                lines.append(line)
                line = []
                occupied = 0
            }
            if !line.isEmpty { occupied += gap }
            line.append((item, itemWidth))
            occupied += itemWidth
        }
        if !line.isEmpty { lines.append(line) }
        var y: CGFloat = 0
        for line in lines {
            let available = max(0, width - CGFloat(line.count - 1) * gap - CGFloat(line.count) * 6)
            let total = line.reduce(CGFloat.zero) { $0 + $1.1 - 6 }
            let growth = line.reduce(CGFloat.zero) { $0 + max(0, $1.0.grow) }
            let shrink = line.reduce(CGFloat.zero) { $0 + max(0, $1.0.shrink) * ($1.1 - 6) }
            let sizes = line.map { item, outerBasis -> CGSize in
                let basis = outerBasis - 6
                let extra = total < available && growth > 0 ? (available - total) * max(0, item.grow) / growth : 0
                let reduction =
                    total > available && shrink > 0 ? (total - available) * max(0, item.shrink) * basis / shrink : 0
                let itemWidth = min(max(0, width - 6), max(44, basis + extra - reduction))
                let height = item.button.sizeThatFits(CGSize(width: itemWidth, height: .greatestFiniteMagnitude)).height
                return CGSize(width: itemWidth, height: max(44, height))
            }
            let height = (sizes.map(\.height).max() ?? 44) + 6
            var x: CGFloat = 3
            for (index, entry) in line.enumerated() {
                let size = sizes[index]
                let offset: CGFloat
                switch entry.0.alignment {
                case "flex_end": offset = height - size.height - 3
                case "center", "auto": offset = (height - size.height) / 2
                default: offset = 3
                }
                if apply {
                    entry.0.button.frame = CGRect(
                        x: x, y: y + offset, width: size.width,
                        height: entry.0.alignment == "stretch" ? height - 6 : size.height)
                }
                x += size.width + 6 + gap
            }
            y += height + gap
        }
        return max(0, y - gap)
    }

    private static func number(_ value: Float, fallback: CGFloat) -> CGFloat {
        value.isFinite ? CGFloat(value) : fallback
    }
}
