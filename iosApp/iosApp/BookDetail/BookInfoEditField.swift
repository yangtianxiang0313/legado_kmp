import UIKit

private enum BookInfoEditInputMetrics {
    // AppCompat's 10/4/7dp insets include another 4dp of nine-patch content padding below the text.
    static let drawableInsets = UIEdgeInsets(top: 10, left: 4, bottom: 11, right: 4)
    static let underlineBottomInset: CGFloat = 7
    static let underlineHeight: CGFloat = 2

    static func textInsets(font: UIFont, scale: CGFloat) -> UIEdgeInsets {
        // TextView includes font-wide top/bottom, not only the face's ascent/descent.
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
        return UIEdgeInsets(
            top: drawableInsets.top + padding.top, left: drawableInsets.left,
            bottom: drawableInsets.bottom + padding.bottom, right: drawableInsets.right)
    }

    static func minimumEditorHeight(font: UIFont, scale: CGFloat) -> CGFloat {
        let insets = textInsets(font: font, scale: scale)
        let scale = max(1, scale)
        return ceil((font.lineHeight + insets.top + insets.bottom) * scale) / scale
    }
}

@MainActor
final class BookInfoEditField: UIView {
    let editor: UIView
    var onMetricsChange: (() -> Void)?

    private let hintLabel = UILabel()
    private let underline = UIView()
    private var expandedFont = UIFont.systemFont(ofSize: 18)
    private var collapsedFont = UIFont.systemFont(ofSize: 12)
    private var isHintCollapsed = false

    init(title: String, editor: UIView) {
        self.editor = editor
        super.init(frame: .zero)
        hintLabel.text = title
        hintLabel.numberOfLines = 1
        hintLabel.adjustsFontSizeToFitWidth = false
        hintLabel.isAccessibilityElement = false
        hintLabel.isUserInteractionEnabled = false
        addSubview(editor)
        addSubview(hintLabel)
        addSubview(underline)
        underline.isUserInteractionEnabled = false

        if let field = editor as? UITextField {
            field.borderStyle = .none
            field.placeholder = nil
            field.adjustsFontSizeToFitWidth = false
            field.textAlignment = .natural
            field.addTarget(
                self, action: #selector(editorChanged),
                for: [
                    .editingChanged, .editingDidBegin, .editingDidEnd,
                ])
            (field as? BookInfoEditTextField)?.onContentChange = { [weak self] in
                self?.editorContentChanged()
            }
        }
        if let textView = editor as? BookInfoEditGrowingTextView {
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.contentInsetAdjustmentBehavior = .never
            textView.textContainerInset = BookInfoEditInputMetrics.drawableInsets
            textView.textContainer.lineFragmentPadding = 0
            textView.textAlignment = .natural
            textView.onContentChange = { [weak self] in self?.editorContentChanged() }
            for name in [UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(editorChanged), name: name, object: textView)
            }
        }
        refreshAppearanceAndFields()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // AppCompat's MediumInverse editor is 18sp; Design.Hint inherits the 12sp Caption.
    func refreshAppearanceAndFields() {
        expandedFont = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .body, compatibleWith: traitCollection)
        collapsedFont = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        if let field = editor as? UITextField {
            field.font = expandedFont
            field.adjustsFontForContentSizeCategory = false
            field.textColor = field.isEnabled ? AndroidReplicaTheme.primaryText : disabledTextColor
        }
        if let textView = editor as? UITextView {
            if textView.font != expandedFont { textView.font = expandedFont }
            textView.textContainerInset = BookInfoEditInputMetrics.textInsets(
                font: expandedFont, scale: traitCollection.displayScale)
            textView.adjustsFontForContentSizeCategory = false
            textView.textColor = textView.isEditable ? AndroidReplicaTheme.primaryText : disabledTextColor
        }
        editor.tintColor = AndroidReplicaTheme.accent
        updateHint()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    var minimumContentHeight: CGFloat {
        hintMargin
            + BookInfoEditInputMetrics.minimumEditorHeight(
                font: expandedFont, scale: traitCollection.displayScale)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: sizeThatFits(bounds.size).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let editorHeight: CGFloat
        if let textView = editor as? BookInfoEditGrowingTextView, size.width > 0 {
            editorHeight = textView.height(fitting: size.width)
        } else {
            editorHeight = BookInfoEditInputMetrics.minimumEditorHeight(
                font: expandedFont, scale: traitCollection.displayScale)
        }
        return CGSize(width: size.width, height: hintMargin + editorHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = BookInfoEditInputMetrics.textInsets(font: expandedFont, scale: traitCollection.displayScale)
        let width = max(0, bounds.width - insets.left - insets.right)
        let editorHeight = max(0, bounds.height - hintMargin)
        editor.frame = CGRect(x: 0, y: hintMargin, width: bounds.width, height: editorHeight)
        let font = isHintCollapsed ? collapsedFont : expandedFont
        let expandedHintY: CGFloat
        if let field = editor as? UITextField {
            expandedHintY = hintMargin + field.textRect(forBounds: field.bounds).minY
        } else {
            expandedHintY = hintMargin + insets.top
        }
        hintLabel.frame = CGRect(
            x: insets.left, y: isHintCollapsed ? 0 : expandedHintY,
            width: width, height: font.lineHeight)
        let focused = editor.isFirstResponder && editorIsEnabled
        let thickness: CGFloat = focused ? BookInfoEditInputMetrics.underlineHeight : 1
        underline.frame = CGRect(
            x: insets.left,
            y: max(
                0,
                bounds.height - BookInfoEditInputMetrics.underlineBottomInset
                    - BookInfoEditInputMetrics.underlineHeight),
            width: width, height: thickness)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearanceAndFields()
        onMetricsChange?()
    }

    private var hintMargin: CGFloat {
        // BOX_BACKGROUND_NONE truncates the collapsed ascent; only dialog_bookmark adds 3dp above it.
        let scale = max(1, traitCollection.displayScale)
        return floor(collapsedFont.ascender * scale) / scale
    }

    private var editorIsEnabled: Bool {
        if let field = editor as? UITextField { return field.isEnabled }
        if let textView = editor as? UITextView { return textView.isEditable }
        return editor.isUserInteractionEnabled
    }

    private var disabledTextColor: UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.30) : UIColor.black.withAlphaComponent(0.38)
    }

    private func updateHint() {
        let hasText: Bool
        if let field = editor as? UITextField {
            hasText = !(field.text ?? "").isEmpty
        } else if let textView = editor as? UITextView {
            hasText = !(textView.text ?? "").isEmpty
        } else {
            hasText = false
        }
        isHintCollapsed = hasText || (editorIsEnabled && editor.isFirstResponder)
        hintLabel.font = isHintCollapsed ? collapsedFont : expandedFont
        hintLabel.textAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        // Legado overrides defaultHintTextColor with a single-state accent selector.
        hintLabel.textColor = AndroidReplicaTheme.accent
        underline.backgroundColor =
            !editorIsEnabled
            ? disabledTextColor
            : (editor.isFirstResponder ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText)
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        // The default nine-patch and its disabled selector both contribute alpha.
        underline.alpha =
            editorIsEnabled
            ? (editor.isFirstResponder ? 1 : 222 / 255)
            : (222 / 255) * (isNight ? 0.30 : 0.26)
        setNeedsLayout()
    }

    @objc private func editorChanged() {
        editorContentChanged()
    }

    private func editorContentChanged() {
        updateHint()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onMetricsChange?()
    }
}

@MainActor
final class BookInfoEditTextField: UITextField {
    var onContentChange: (() -> Void)?

    override var text: String? {
        didSet { onContentChange?() }
    }

    override var attributedText: NSAttributedString? {
        didSet { onContentChange?() }
    }

    private var editorInsets: UIEdgeInsets {
        BookInfoEditInputMetrics.textInsets(
            font: font ?? .systemFont(ofSize: 18), scale: traitCollection.displayScale)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        super.textRect(forBounds: bounds.inset(by: editorInsets))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        super.editingRect(forBounds: bounds.inset(by: editorInsets))
    }
}

@MainActor
final class BookInfoEditGrowingTextView: UITextView {
    var minimumHeight: CGFloat = 0 {
        didSet { contentMetricsChanged() }
    }
    var onContentChange: (() -> Void)?

    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat?
    private var laidOutWidth: CGFloat?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isScrollEnabled = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged), name: UITextView.textDidChangeNotification, object: self)
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var text: String! {
        didSet { contentMetricsChanged() }
    }

    override var attributedText: NSAttributedString! {
        didSet { contentMetricsChanged() }
    }

    override var font: UIFont? {
        didSet {
            if font != oldValue { contentMetricsChanged() }
        }
    }

    override var textContainerInset: UIEdgeInsets {
        didSet {
            if textContainerInset != oldValue { contentMetricsChanged() }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height(fitting: bounds.width))
    }

    func height(fitting width: CGFloat) -> CGFloat {
        let naturalLine =
            (font ?? .systemFont(ofSize: 18)).lineHeight
            + textContainerInset.top + textContainerInset.bottom
        let scale = max(1, traitCollection.displayScale)
        let minimum = ceil(max(minimumHeight, naturalLine) * scale) / scale
        guard width > 0, width.isFinite else { return minimum }
        if measuredWidth == width, let measuredHeight { return measuredHeight }
        let fitting = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = max(minimum, ceil(fitting * scale) / scale)
        measuredWidth = width
        measuredHeight = height
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Exact width changes, including subpoints after rotation, alter wrapping.
        if laidOutWidth != bounds.width {
            laidOutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        contentMetricsChanged()
    }

    @objc private func textChanged() {
        contentMetricsChanged()
    }

    private func contentMetricsChanged() {
        measuredWidth = nil
        measuredHeight = nil
        invalidateIntrinsicContentSize()
        onContentChange?()
    }
}
