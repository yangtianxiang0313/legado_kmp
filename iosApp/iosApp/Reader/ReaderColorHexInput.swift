import CoreText
import UIKit

/// cpv_dialog_color_picker uses Android's monospace face, not the reader's body font.
enum ReaderColorMonospaceFont {
    private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "ReaderAndroidMonospace", withExtension: "ttf"),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()

    static func scaled(size: CGFloat, style: UIFont.TextStyle, traits: UITraitCollection) -> UIFont {
        let size = UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: traits)
        guard let descriptor else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as UIFont
    }
}

/// ColorPickerDialog 1.1.0's no-alpha parser, returning opaque Android ARGB.
/// Three digits mean 0R/0G/0B, not CSS shorthand; an empty string means black.
enum ReaderColorHex {
    static func parseColorString(_ text: String) -> UInt32? {
        let bytes = Array((text.hasPrefix("#") ? String(text.dropFirst()) : text).utf8)
        guard bytes.count <= 6 else { return nil }
        var value: UInt32 = 0
        var digits: [UInt32] = []
        for byte in bytes {
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 65 + 10)
            case 97...102: digit = UInt32(byte - 97 + 10)
            default: return nil
            }
            digits.append(digit)
            value = (value << 4) | digit
        }
        if digits.count == 3 { value = (digits[0] << 16) | (digits[1] << 8) | digits[2] }
        return 0xFF00_0000 | value
    }

    static func color(argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 255) / 255,
            green: CGFloat((argb >> 8) & 255) / 255,
            blue: CGFloat(argb & 255) / 255,
            alpha: CGFloat((argb >> 24) & 255) / 255)
    }

    static func hexString(color: UIColor, traits: UITraitCollection) -> String {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        let channels = [red, green, blue].map { component -> UInt32 in
            let clamped = component.isFinite ? min(1, max(0, component)) : 0
            return UInt32((clamped * 255).rounded())
        }
        return String(format: "%06X", (channels[0] << 16) | (channels[1] << 8) | channels[2])
    }
}

@MainActor
final class ReaderColorHexInput: UIView, UITextFieldDelegate {
    var onColorChange: ((UIColor) -> Void)?
    var onEditingStateChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    var canBeginEditing: (() -> Bool)?

    let editor = ReaderColorHexTextField()
    var hasMarkedText: Bool { editor.markedTextRange != nil }
    var isValidForSubmission: Bool {
        !hasMarkedText && ReaderColorHex.parseColorString(editor.text ?? "") != nil
    }

    var preferredWidth: CGFloat {
        let font = editor.font ?? ReaderColorMonospaceFont.scaled(size: 18, style: .body, traits: traitCollection)
        let hashWidth = ceil(
            hashLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width)
        let digitsWidth = ceil(("FFFFFF" as NSString).size(withAttributes: [.font: font]).width) + 8
        return hashWidth + max(110, digitsWidth)
    }

    private let hashLabel = AndroidExploreTextLabel()
    private let underline = UIView()
    private var displayColor: UIColor
    private var acceptedText = ""
    private var acceptedSelection = NSRange(location: 0, length: 0)
    private var isUpdatingText = false
    private var isProcessingText = false
    private var textRefreshScheduled = false

    init(color: UIColor) {
        displayColor = color
        super.init(frame: .zero)
        hashLabel.text = "#"
        hashLabel.textColor = AndroidReplicaTheme.primaryText
        hashLabel.isAccessibilityElement = false
        editor.delegate = self
        editor.backgroundColor = .clear
        editor.textColor = AndroidReplicaTheme.primaryText
        editor.tintColor = AndroidReplicaTheme.accent
        editor.borderStyle = .none
        editor.keyboardType = .asciiCapable
        editor.returnKeyType = .go
        editor.enablesReturnKeyAutomatically = false
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContentType = nil
        editor.clearButtonMode = .never
        editor.adjustsFontForContentSizeCategory = false
        editor.accessibilityLabel = "颜色十六进制值"
        editor.accessibilityIdentifier = "reader.colorPicker.hex"
        editor.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        underline.isUserInteractionEnabled = false
        for child in [hashLabel, editor, underline] { addSubview(child) }
        accessibilityElements = [editor]
        applyFonts(traits: traitCollection)
        showDisplayColor()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        editor.font = ReaderColorMonospaceFont.scaled(size: 18, style: .body, traits: traits)
        hashLabel.font = ReaderColorMonospaceFont.scaled(size: 14, style: .subheadline, traits: traits)
        hashLabel.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setColor(_ color: UIColor) {
        displayColor = color
        // Picker, trait and layout updates must not replace a selection or an IME composition.
        guard !editor.isFirstResponder, !hasMarkedText else { return }
        showDisplayColor()
    }

    func setInteraction(enabled: Bool) {
        if editor.isEnabled != enabled { editor.isEnabled = enabled }
    }

    func prepareForSubmission() -> Bool {
        guard isValidForSubmission else { return false }
        processCommittedText()
        return isValidForSubmission
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, preferredWidth), height: max(48, editor.sizeThatFits(size).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hashWidth = min(bounds.width, ceil(hashLabel.sizeThatFits(bounds.size).width))
        editor.frame = CGRect(x: hashWidth, y: 0, width: max(0, bounds.width - hashWidth), height: bounds.height)
        let padding = editor.androidPadding
        let editorFont = editor.font!
        let lineHeight = ceil(editorFont.lineHeight)
        let baseline =
            padding.top + max(0, (bounds.height - padding.top - padding.bottom - lineHeight) / 2)
            + editorFont.ascender
        let hashSize = hashLabel.sizeThatFits(CGSize(width: hashWidth, height: .greatestFiniteMagnitude))
        hashLabel.frame = CGRect(
            x: 0, y: baseline - hashLabel.font.ascender - hashLabel.fontPadding.top,
            width: hashWidth, height: hashSize.height)
        let thickness: CGFloat = editor.isFirstResponder ? 2 : 1
        underline.frame = CGRect(
            x: hashWidth, y: bounds.height - 9, width: max(0, bounds.width - hashWidth), height: thickness)
        let color = editor.isFirstResponder ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        underline.backgroundColor = color.withAlphaComponent(editor.isEnabled ? 1 : 0.26)
    }

    func textFieldShouldBeginEditing(_: UITextField) -> Bool {
        editor.isEnabled && (canBeginEditing?() ?? true)
    }

    func textFieldDidBeginEditing(_: UITextField) {
        rememberSelection()
        setNeedsLayout()
        onEditingStateChange?()
    }

    func textFieldDidEndEditing(_: UITextField) {
        processCommittedText()
        if !hasMarkedText { showDisplayColor() }
        setNeedsLayout()
        onEditingStateChange?()
    }

    func textFieldDidChangeSelection(_: UITextField) {
        guard !isUpdatingText else { return }
        if !hasMarkedText, editor.text == acceptedText { rememberSelection() }
        onEditingStateChange?()
        // Some input methods commit marked text via selection changes without editingChanged.
        guard !textRefreshScheduled else { return }
        textRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textRefreshScheduled = false
            self.processCommittedText()
        }
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        processCommittedText()
        guard isValidForSubmission else { return false }
        onSubmit?()
        return false
    }

    @objc private func textChanged() {
        processCommittedText()
    }

    private func processCommittedText() {
        guard !isUpdatingText, !isProcessingText else { return }
        isProcessingText = true
        defer {
            isProcessingText = false
            onEditingStateChange?()
        }
        guard !hasMarkedText else { return }
        let text = editor.text ?? ""
        guard text != acceptedText else { return }
        // Validate only committed text. UIKit owns marked text, even while it exceeds six characters.
        guard text.utf8.count <= 6, !text.hasPrefix("#"), let argb = ReaderColorHex.parseColorString(text) else {
            replaceText(acceptedText, selection: acceptedSelection)
            return
        }
        acceptedText = text
        rememberSelection()
        displayColor = ReaderColorHex.color(argb: argb)
        onColorChange?(displayColor)
    }

    private func showDisplayColor() {
        let text = ReaderColorHex.hexString(color: displayColor, traits: traitCollection)
        acceptedText = text
        acceptedSelection = NSRange(location: text.utf16.count, length: 0)
        replaceText(text, selection: acceptedSelection)
    }

    private func rememberSelection() {
        guard let range = editor.selectedTextRange else { return }
        acceptedSelection = NSRange(
            location: editor.offset(from: editor.beginningOfDocument, to: range.start),
            length: editor.offset(from: range.start, to: range.end))
    }

    private func replaceText(_ text: String, selection: NSRange) {
        guard !hasMarkedText else { return }
        isUpdatingText = true
        defer { isUpdatingText = false }
        editor.text = text
        let count = text.utf16.count
        let startOffset = min(count, max(0, selection.location))
        let endOffset = min(count, startOffset + max(0, selection.length))
        if let start = editor.position(from: editor.beginningOfDocument, offset: startOffset),
            let end = editor.position(from: editor.beginningOfDocument, offset: endOffset)
        {
            editor.selectedTextRange = editor.textRange(from: start, to: end)
        }
    }
}

final class ReaderColorHexTextField: UITextField {
    var androidPadding: UIEdgeInsets {
        let font = font ?? ReaderColorMonospaceFont.scaled(size: 18, style: .body, traits: traitCollection)
        let natural = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        // AppCompat's plain EditText background includes its nine-patch bottom content padding.
        return UIEdgeInsets(top: 10 + natural.top, left: 4, bottom: 11 + natural.bottom, right: 4)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: androidPadding) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = androidPadding
        return CGSize(width: size.width, height: ceil((font?.lineHeight ?? 0) + padding.top + padding.bottom))
    }
}
