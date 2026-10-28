import UIKit

final class BookSourceEditorFormView: UIView, UITextViewDelegate {
    var onChange: ((BookSourceEditorField, String) -> Void)?
    var onEditing: ((UITextView) -> Void)?

    private let fields: [BookSourceEditorField]
    private let fieldStack = UIStackView()
    private var rowsByID: [String: BookSourceEditorFieldRow] = [:]
    private var fieldsByTextView: [ObjectIdentifier: BookSourceEditorField] = [:]
    private var isPopulating = false
    private lazy var presentation: AndroidSearchPresentationState = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updatePresentation()
    }

    init(tab: SourceEditorTab) {
        fields = BookSourceEditorField.fields(for: tab)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AndroidReplicaTheme.background

        fieldStack.axis = .vertical
        fieldStack.alignment = .fill
        fieldStack.spacing = 0
        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fieldStack)
        NSLayoutConstraint.activate([
            fieldStack.topAnchor.constraint(equalTo: topAnchor),
            fieldStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            fieldStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            fieldStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for field in fields {
            let row = BookSourceEditorFieldRow(field: field)
            row.textView.inputAccessoryView = RestoredKeyboardAccessory(textView: row.textView)
            row.textView.delegate = self
            rowsByID[field.id] = row
            fieldsByTextView[ObjectIdentifier(row.textView)] = field
            fieldStack.addArrangedSubview(row)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentation.update()
    }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
        updatePresentation()
    }

    private func updatePresentation() {
        for row in rowsByID.values {
            row.textView.setPresentationActive(presentation.isActive)
            row.updateEditingAppearance()
        }
    }

    @objc private func refreshPalette() {
        backgroundColor = AndroidReplicaTheme.background
        for row in rowsByID.values { row.refreshPalette() }
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        presentation.isActive && isUserInteractionEnabled
    }

    func populate(_ values: (BookSourceEditorField) -> String) {
        isPopulating = true
        defer { isPopulating = false }
        for field in fields {
            guard let row = rowsByID[field.id] else { continue }
            let value = values(field)
            if !(row.textView.text ?? "").utf16.elementsEqual(value.utf16) {
                row.textView.text = value
            }
            row.acceptPopulatedText()
            row.textView.refreshSyntaxImmediately()
            row.updateEditingAppearance()
            row.textView.invalidateIntrinsicContentSize()
        }
        fieldStack.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func textView(for id: String) -> UITextView? {
        rowsByID[id]?.textView
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let field = fieldsByTextView[ObjectIdentifier(textView)] else { return }
        rowsByID[field.id]?.updateEditingAppearance(animated: true)
        if !isPopulating { onEditing?(textView) }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard let field = fieldsByTextView[ObjectIdentifier(textView)] else { return }
        rowsByID[field.id]?.updateEditingAppearance(animated: true)
        rowsByID[field.id]?.textView.compositionDidChange()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isPopulating, let field = fieldsByTextView[ObjectIdentifier(textView)],
            let row = rowsByID[field.id], !row.textView.isApplyingTextAppearance
        else { return }
        row.updateEditingAppearance(animated: true)
        row.textView.compositionDidChange()
        guard let changedText = row.textForChangeNotification() else { return }
        textView.invalidateIntrinsicContentSize()
        fieldStack.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onChange?(field, changedText)
        onEditing?(textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isPopulating, let field = fieldsByTextView[ObjectIdentifier(textView)],
            let row = rowsByID[field.id], !row.textView.isApplyingTextAppearance
        else { return }
        row.textView.compositionDidChange()
        guard textView.isFirstResponder else { return }
        onEditing?(textView)
    }
}

private final class BookSourceEditorFieldRow: UIView {
    let textView = BookSourceEditorGrowingTextView()

    private let hintLabel = UILabel()
    private let inlineHintLabel = UILabel()
    private let underline = UIView()
    private var underlineHeight: NSLayoutConstraint!
    private var inputTop: NSLayoutConstraint!
    private var hintBaseline: NSLayoutConstraint!
    private var inlineHintBaseline: NSLayoutConstraint!
    private var isHintFloating = false
    private var lastReportedText = ""

    private var controlActivatedColor: UIColor {
        // CodeView never calls TintHelper: AppCompat's colorAccent is a resource,
        // while TextInputLayout explicitly takes its hint color from ThemeStore.
        ReaderPaletteColor.argb(
            ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0xFFD8_4315 : 0xFFAD_1457)
    }

    init(field: BookSourceEditorField) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hintLabel.text = field.title
        hintLabel.textColor = AndroidReplicaTheme.accent
        hintLabel.numberOfLines = 1
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isAccessibilityElement = false
        hintLabel.isUserInteractionEnabled = false
        hintLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        inlineHintLabel.text = field.title
        inlineHintLabel.textColor = AndroidReplicaTheme.accent
        inlineHintLabel.numberOfLines = 1
        inlineHintLabel.lineBreakMode = .byTruncatingTail
        inlineHintLabel.isAccessibilityElement = false
        inlineHintLabel.isUserInteractionEnabled = false
        inlineHintLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        textView.tintColor = controlActivatedColor
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.alwaysBounceHorizontal = false
        textView.alwaysBounceVertical = false
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.enablesReturnKeyAutomatically = false
        textView.allowsEditingTextAttributes = false
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = field.title
        textView.accessibilityIdentifier = field.identifier
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        underline.isUserInteractionEnabled = false
        for child in [textView, hintLabel, inlineHintLabel, underline] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        underlineHeight = underline.heightAnchor.constraint(equalToConstant: 1)
        inputTop = textView.topAnchor.constraint(equalTo: topAnchor)
        hintBaseline = hintLabel.firstBaselineAnchor.constraint(equalTo: topAnchor)
        inlineHintBaseline = inlineHintLabel.firstBaselineAnchor.constraint(equalTo: textView.topAnchor)
        NSLayoutConstraint.activate([
            hintBaseline,
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            inputTop,
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            inlineHintBaseline,
            inlineHintLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            inlineHintLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -4),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            underlineHeight,
            // Both mdpi nine-patches start their painted line 9dp above the bottom;
            // only the activated drawable extends its second pixel down to -7dp.
            underline.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: -9),
        ])
        updateHintFonts()
        updateEditingAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateHintFonts()
        updateEditingAppearance()
    }

    private func updateHintFonts() {
        let hintFont = BookSourceEditorTypography.hintFont(compatibleWith: traitCollection)
        let inputFont = BookSourceEditorTypography.inputFont(compatibleWith: traitCollection)
        hintLabel.font = hintFont
        inlineHintLabel.font = inputFont
        let scale = max(1, traitCollection.displayScale)
        // Material 1.13's default single-line hint reserves int(-paint.ascent()),
        // not a UILabel line box. Its StaticLayout has includePad=false in both states.
        inputTop.constant = 3 + floor(hintFont.ascender * scale) / scale
        hintBaseline.constant = 3 + hintFont.ascender
        inlineHintBaseline.constant = 10 + inputFont.ascender
    }

    func acceptPopulatedText() {
        lastReportedText = textView.textStorage.string
    }

    func textForChangeNotification() -> String? {
        let value = textView.textStorage.string
        guard !lastReportedText.utf16.elementsEqual(value.utf16) else { return nil }
        lastReportedText = value
        return value
    }

    func updateEditingAppearance(animated: Bool = false) {
        // Observe the existing disabled state for drawing only; do not change any gate.
        var isEnabled = textView.isEditable
        var ancestor: UIView? = textView
        while let view = ancestor {
            isEnabled = isEnabled && view.isUserInteractionEnabled
            ancestor = view.superview
        }
        let isEditing = isEnabled && textView.isFirstResponder
        let shouldFloat = isEditing || !textView.textStorage.string.isEmpty
        underlineHeight.constant = isEditing ? 2 : 1
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let disabledAlpha: CGFloat = isNight ? 0.30 : 0.26
        let normalAlpha: CGFloat = isNight ? 179 / 255 : 138 / 255
        // abc_tint_edittext applies disabledAlpha to colorControlNormal; the disabled
        // nine-patch applies it again. Its default bitmap alpha is already 222/255.
        let colorAlpha = isEnabled ? normalAlpha : (normalAlpha * disabledAlpha * 255).rounded() / 255
        underline.backgroundColor = isEditing ? controlActivatedColor : UIColor(white: isNight ? 1 : 0, alpha: colorAlpha)
        underline.alpha = isEditing ? 1 : (222 / 255) * (isEnabled ? 1 : disabledAlpha)

        let updateLabels = {
            self.hintLabel.alpha = shouldFloat ? 1 : 0
            self.inlineHintLabel.alpha = shouldFloat ? 0 : 1
        }
        if animated, shouldFloat != isHintFloating, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.167, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: updateLabels)
        } else {
            UIView.performWithoutAnimation(updateLabels)
        }
        isHintFloating = shouldFloat
    }

    func refreshPalette() {
        hintLabel.textColor = AndroidReplicaTheme.accent
        inlineHintLabel.textColor = AndroidReplicaTheme.accent
        textView.tintColor = controlActivatedColor
        textView.keyboardAppearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        textView.refreshSyntaxImmediately()
        updateEditingAppearance()
    }
}

private final class BookSourceEditorGrowingTextView: UITextView {
    private var measuredWidth: CGFloat = 0
    private var syntaxHighlighter: BookSourceEditorSyntaxHighlighter?
    private var inputMutationDepth = 0

    var isApplyingTextAppearance: Bool { syntaxHighlighter?.isApplyingAttributes == true }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        let inputFont = BookSourceEditorTypography.inputFont(compatibleWith: traitCollection)
        font = inputFont
        adjustsFontForContentSizeCategory = false
        updateInputPadding(font: inputFont)
        textColor = AndroidReplicaTheme.primaryText
        syntaxHighlighter = BookSourceEditorSyntaxHighlighter(textView: self, font: inputFont)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var text: String! {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        let inputFont = BookSourceEditorTypography.inputFont(compatibleWith: traitCollection)
        let scale = max(1, traitCollection.displayScale)
        let minimumHeight = ceil((inputFont.lineHeight + textContainerInset.top + textContainerInset.bottom) * scale) / scale
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: minimumHeight)
        }
        let fittingSize = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(minimumHeight, ceil(fittingSize.height * scale) / scale))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Height depends on the constrained row width, never on the code's longest line.
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let inputFont = BookSourceEditorTypography.inputFont(compatibleWith: traitCollection)
        updateInputPadding(font: inputFont)
        syntaxHighlighter?.updateFont(inputFont)
        invalidateIntrinsicContentSize()
    }

    private func updateInputPadding(font: UIFont) {
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        // abc_edit_text_material's XML insets are top/left/bottom/right=10/4/7/4;
        // its nine-patch content markers add bottom=4. TextView keeps includeFontPadding.
        // Add font-wide padding only around the complete natural TextKit layout.
        let insets = UIEdgeInsets(top: 10 + padding.top, left: 4, bottom: 11 + padding.bottom, right: 4)
        if textContainerInset != insets { textContainerInset = insets }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputMutationDepth += 1
        defer { finishInputMutation() }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func unmarkText() {
        inputMutationDepth += 1
        defer { finishInputMutation() }
        super.unmarkText()
    }

    override func insertText(_ text: String) {
        inputMutationDepth += 1
        defer { finishInputMutation() }
        super.insertText(text)
    }

    override func deleteBackward() {
        inputMutationDepth += 1
        defer { finishInputMutation() }
        super.deleteBackward()
    }

    override func replace(_ range: UITextRange, withText text: String) {
        inputMutationDepth += 1
        defer { finishInputMutation() }
        super.replace(range, withText: text)
    }

    private func finishInputMutation() {
        inputMutationDepth -= 1
        compositionDidChange()
    }

    func refreshSyntaxImmediately() {
        syntaxHighlighter?.refresh(immediately: true)
    }

    func setPresentationActive(_ active: Bool) { syntaxHighlighter?.setPresentationActive(active) }

    func compositionDidChange() {
        guard inputMutationDepth == 0 else { return }
        syntaxHighlighter?.compositionDidChange()
    }
}
