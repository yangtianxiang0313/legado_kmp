import UIKit

/// Share ThemeEditText's 18sp editor, 12sp floating hint and AppCompat underline metrics.
final class ReaderHardwareKeyDialogField: UIView {
    let textField: ReaderHardwareKeyDialogCaptureTextField
    private let themeEditField: BookInfoEditField

    init(title: String) {
        let textField = ReaderHardwareKeyDialogCaptureTextField()
        self.textField = textField
        themeEditField = BookInfoEditField(title: title, editor: textField)
        super.init(frame: .zero)
        textField.backgroundColor = .clear
        textField.accessibilityLabel = title
        textField.clearButtonMode = .never
        textField.returnKeyType = .done
        textField.keyboardType = .asciiCapable
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themeEditField.onMetricsChange = { [weak self] in
            self?.invalidateIntrinsicContentSize()
            self?.setNeedsLayout()
        }
        addSubview(themeEditField)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("Use init(title:)")
    }

    override var intrinsicContentSize: CGSize {
        themeEditField.intrinsicContentSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        themeEditField.sizeThatFits(size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        themeEditField.frame = bounds
    }
}

/// Multiline content determines the height instead of a fixed UIButton title rect.
final class ReaderHardwareKeyDialogActionButton: UIButton {
    private let captionLabel = AndroidExploreTextLabel()

    init(title: String) {
        super.init(frame: .zero)
        accessibilityLabel = title
        captionLabel.text = title
        captionLabel.textColor = AndroidReplicaTheme.primaryText
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 0
        captionLabel.lineBreakMode = .byCharWrapping
        captionLabel.adjustsFontForContentSizeCategory = false
        captionLabel.isAccessibilityElement = false
        captionLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.isUserInteractionEnabled = false
        addSubview(captionLabel)
        // selector_fillet_btn_bg uses 16dp corners and btn_bg_press[_2], not menu colors.
        layer.cornerRadius = 16
        clipsToBounds = true
        backgroundColor = ExploreAndroidGraphics.kindBackground
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyFont()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("Use init(title:)")
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor =
                isHighlighted ? ExploreAndroidGraphics.kindPressedBackground : ExploreAndroidGraphics.kindBackground
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if captionLabel.bounds.width > 0, captionLabel.preferredMaxLayoutWidth != captionLabel.bounds.width {
            captionLabel.preferredMaxLayoutWidth = captionLabel.bounds.width
            captionLabel.invalidateIntrinsicContentSize()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFont()
    }

    func applyFont() {
        captionLabel.font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        captionLabel.textColor = AndroidReplicaTheme.primaryText
        captionLabel.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

final class ReaderHardwareKeyDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIButton || super.touchesShouldCancel(in: view)
    }
}

final class ReaderHardwareKeyDialogCaptureTextField: UITextField {
    var onCaptureToken: ((String) -> Void)?
    var onCancel: (() -> Void)?

    // Reset and captured tokens also update BookInfoEditField's hint, without rewriting the draft.
    override var text: String? {
        didSet { sendActions(for: .editingChanged) }
    }

    override var attributedText: NSAttributedString? {
        didSet { sendActions(for: .editingChanged) }
    }

    private var editorInsets: UIEdgeInsets {
        let padding = AndroidExploreTextMetrics.padding(
            font: font
                ?? ReaderAndroidDefaultFont.scaledFont(
                    size: 18, textStyle: .body, compatibleWith: traitCollection),
            scale: traitCollection.displayScale)
        // abc_edit_text_material: 10/4/7dp inset plus the nine-patch's 4dp bottom content padding.
        return UIEdgeInsets(top: 10 + padding.top, left: 4, bottom: 11 + padding.bottom, right: 4)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        super.textRect(forBounds: bounds.inset(by: editorInsets))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        super.editingRect(forBounds: bounds.inset(by: editorInsets))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        if presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            onCancel?()
            return
        }
        for press in presses {
            guard let token = Self.token(for: press) else { continue }
            onCaptureToken?(token)
            unhandled.remove(press)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    private static func token(for press: UIPress) -> String? {
        guard let key = press.key else { return nil }
        // Keep the iOS HID -> named-token format used by the reader and its existing preferences.
        let keyName = keyName(for: Int(key.keyCode.rawValue), fallback: key.charactersIgnoringModifiers)
        guard let keyName else { return nil }
        let modifiers = modifierNames(for: key.modifierFlags)
        return (modifiers + [keyName]).joined(separator: "+")
    }

    private static func keyName(for code: Int, fallback: String) -> String? {
        switch code {
        case 40:
            return "Enter"
        case 41, 42, 76:
            // Escape cancels above; Backspace and forward Delete edit the draft normally.
            return nil
        case 43:
            return "Tab"
        case 44:
            return "Space"
        case 75:
            return "PageUp"
        case 78:
            return "PageDown"
        case 79:
            return "RightArrow"
        case 80:
            return "LeftArrow"
        case 81:
            return "DownArrow"
        case 82:
            return "UpArrow"
        default:
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 1,
                trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                return nil
            }
            return trimmed.uppercased()
        }
    }

    private static func modifierNames(for flags: UIKeyModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) {
            names.append("Command")
        }
        if flags.contains(.shift) {
            names.append("Shift")
        }
        if flags.contains(.control) {
            names.append("Control")
        }
        if flags.contains(.alternate) {
            names.append("Option")
        }
        return names
    }
}
