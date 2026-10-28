import UIKit

@MainActor
final class ReaderCharsetDialogContentView: UIView, UIGestureRecognizerDelegate {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onLayoutChange: (() -> Void)?

    let editor = UITextView()
    var rawText: String { editor.text ?? "" }
    var accessibilityHeading: UIView { titleLabel }

    // AppConst.charsets order is also the stable accessibility index after filtering.
    private static let charsets = ["UTF-8", "GB2312", "GB18030", "GBK", "Unicode", "UTF-16", "UTF-16LE", "ASCII"]
    // abc_edit_text_material adds 10/4/7dp; its nine-patch contributes another 4dp below the text.
    private static let inputInsets = UIEdgeInsets(top: 10, left: 4, bottom: 11, right: 4)
    private let titleLabel = AndroidExploreTextLabel()
    private let placeholderLabel = AndroidExploreTextLabel()
    private let underline = UIView()
    private let scrollView = ReaderCharsetDialogScrollView()
    private let formView = UIView()
    private let suggestionsView = UIView()
    private let footerView = UIView()
    private let cancelControl = BookshelfLayoutDialogAction(title: "取消")
    // AlertBuilder.okButton uses android.R.string.ok, not the app's "确认" resource.
    private let confirmControl = BookshelfLayoutDialogAction(title: "确定")
    private let suggestionControls: [ReaderCharsetSuggestionControl]
    private var visibleIndices: [Int] = []
    private var offersSuggestions = false
    private var needsCaretReveal = false
    private var lastViewportSize: CGSize = .zero
    private var isInteractionEnabled = false

    init(charset: String) {
        suggestionControls = Self.charsets.map { ReaderCharsetSuggestionControl(title: $0) }
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        BookshelfLayoutDialogStyle.configure(titleLabel, text: "设置编码", color: AndroidReplicaTheme.primaryText)
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.charset.title"
        BookshelfLayoutDialogStyle.configure(placeholderLabel, text: "charset", color: AndroidReplicaTheme.secondaryText)
        placeholderLabel.lineBreakMode = .byCharWrapping
        placeholderLabel.isAccessibilityElement = false
        editor.text = charset
        editor.backgroundColor = .clear
        editor.textColor = AndroidReplicaTheme.primaryText
        editor.tintColor = AndroidReplicaTheme.accent
        editor.isScrollEnabled = false
        editor.scrollsToTop = false
        editor.textContainerInset = Self.inputInsets
        editor.textContainer.lineFragmentPadding = 0
        editor.textContainer.maximumNumberOfLines = 0
        editor.textContainer.lineBreakMode = .byWordWrapping
        editor.contentInsetAdjustmentBehavior = .never
        editor.adjustsFontForContentSizeCategory = false
        editor.textAlignment = .natural
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContentType = nil
        editor.keyboardType = .default
        editor.returnKeyType = .default
        editor.allowsEditingTextAttributes = false
        editor.dataDetectorTypes = []
        editor.accessibilityLabel = "charset"
        editor.accessibilityIdentifier = "reader.charset.input"
        let inputTap = UITapGestureRecognizer(target: self, action: #selector(showSuggestions))
        inputTap.delegate = self
        inputTap.cancelsTouchesInView = false
        inputTap.delaysTouchesEnded = false
        editor.addGestureRecognizer(inputTap)
        underline.isUserInteractionEnabled = false
        underline.isAccessibilityElement = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.keyboardDismissMode = .interactive
        suggestionsView.accessibilityIdentifier = "reader.charset.suggestions"
        suggestionsView.isHidden = true
        cancelControl.accessibilityIdentifier = "reader.charset.cancel"
        confirmControl.accessibilityIdentifier = "reader.charset.confirm"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        addSubview(scrollView)
        scrollView.addSubview(formView)
        for child in [titleLabel, editor, placeholderLabel, underline, suggestionsView] { formView.addSubview(child) }
        for control in [cancelControl, confirmControl] { footerView.addSubview(control) }
        for (index, control) in suggestionControls.enumerated() {
            control.tag = index
            control.isHidden = true
            control.accessibilityIdentifier = "reader.charset.suggestion.\(index)"
            control.addTarget(self, action: #selector(selectSuggestion(_:)), for: .touchUpInside)
            suggestionsView.addSubview(control)
        }
        refreshInput()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = BookshelfLayoutDialogStyle.font(size: 20, weight: .medium, style: .headline, traits: traits)
        let inputFont = BookshelfLayoutDialogStyle.font(size: 18, traits: traits)
        editor.font = inputFont
        placeholderLabel.font = inputFont
        let padding = AndroidExploreTextMetrics.padding(font: inputFont, scale: traits.displayScale)
        editor.textContainerInset = UIEdgeInsets(
            top: Self.inputInsets.top + padding.top, left: Self.inputInsets.left,
            bottom: Self.inputInsets.bottom + padding.bottom, right: Self.inputInsets.right)
        let suggestionFont = BookshelfLayoutDialogStyle.font(size: 14, traits: traits)
        for control in suggestionControls { control.apply(font: suggestionFont) }
        let actionFont = BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits)
        cancelControl.apply(font: actionFont)
        confirmControl.apply(font: actionFont)
        revealCaretOnNextLayout()
    }

    func setInteraction(enabled: Bool) {
        isInteractionEnabled = enabled
        editor.isUserInteractionEnabled = enabled
        cancelControl.isEnabled = enabled
        confirmControl.isEnabled = enabled
        for control in suggestionControls { control.isEnabled = enabled && editor.markedTextRange == nil }
        updateUnderline()
    }

    func beginEditing() {
        offersSuggestions = true
        refreshInput()
    }

    func endEditing() {
        offersSuggestions = false
        refreshInput()
    }

    func inputDidChange() {
        offersSuggestions = editor.isFirstResponder
        refreshInput()
    }

    func refreshInput() {
        placeholderLabel.isHidden = !rawText.isEmpty
        updateUnderline()
        // Do not replace text, selection or marked text when an IME is composing.
        let indices =
            offersSuggestions && editor.markedTextRange == nil
            ? Self.charsets.indices.filter {
                rawText.isEmpty || Self.charsets[$0].range(of: rawText, options: .caseInsensitive) != nil
            } : []
        if visibleIndices != indices {
            visibleIndices = indices
            for (index, control) in suggestionControls.enumerated() { control.isHidden = !indices.contains(index) }
            suggestionsView.isHidden = indices.isEmpty
            suggestionsView.accessibilityElements = indices.map { suggestionControls[$0] }
            onLayoutChange?()
        }
        setNeedsLayout()
    }

    private func updateUnderline() {
        // TintHelper tints the drawable, retaining the bitmap and disabled-state alpha.
        let defaultAlpha: CGFloat = 222 / 255
        let disabledAlpha: CGFloat = ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0.30 : 0.26
        underline.backgroundColor = AndroidReplicaTheme.accent
        underline.alpha =
            isInteractionEnabled ? (editor.isFirstResponder ? 1 : defaultAlpha) : defaultAlpha * disabledAlpha
    }

    func revealCaretOnNextLayout() {
        needsCaretReveal = true
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: ceil(
                arrangeForm(width: size.width, applyFrames: false)
                    + arrangeActions(width: size.width, applyFrames: false)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let formHeight = arrangeForm(width: width, applyFrames: true)
        let footerHeight = arrangeActions(width: width, applyFrames: true)
        // Keep actions visible unless the keyboard/AX viewport needs all chrome to scroll.
        let pinsFooter = bounds.height >= footerHeight + min(48, editor.bounds.height)
        let footerParent = pinsFooter ? self : formView
        if footerView.superview !== footerParent { footerParent.addSubview(footerView) }
        footerView.frame = CGRect(
            x: 0, y: pinsFooter ? bounds.height - footerHeight : formHeight, width: width, height: footerHeight)
        let viewportHeight = max(0, bounds.height - (pinsFooter ? footerHeight : 0))
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        let contentHeight = formHeight + (pinsFooter ? 0 : footerHeight)
        formView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = formView.bounds.size
        scrollView.isScrollEnabled = contentHeight > viewportHeight
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        var elements: [Any] = [titleLabel, editor]
        if !visibleIndices.isEmpty { elements.append(suggestionsView) }
        if !pinsFooter { elements.append(footerView) }
        formView.accessibilityElements = elements
        accessibilityElements = pinsFooter ? [scrollView, footerView] : [scrollView]
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsCaretReveal = true
        }
        revealPendingCaret()
    }

    private func arrangeForm(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let titleInset = min(24, max(0, (width - 1) / 2))
        let titleWidth = max(1, width - titleInset * 2)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let inputInset = min(16, max(0, (width - 1) / 2))
        let inputWidth = max(1, width - inputInset * 2)
        let hintWidth = max(1, inputWidth - Self.inputInsets.left - Self.inputInsets.right)
        let hintHeight = placeholderLabel.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude))
            .height
        let measured = editor.sizeThatFits(CGSize(width: inputWidth, height: .greatestFiniteMagnitude))
        // The hint already includes font padding; round only after adding the complete background padding.
        let inputHeight = ceil(max(hintHeight + Self.inputInsets.top + Self.inputInsets.bottom, measured.height))
        let inputY = 18 + titleHeight
        var suggestionY: CGFloat = 0
        for index in visibleIndices {
            let control = suggestionControls[index]
            let height = control.sizeThatFits(CGSize(width: inputWidth, height: .greatestFiniteMagnitude)).height
            if applyFrames { control.frame = CGRect(x: 0, y: suggestionY, width: inputWidth, height: height) }
            suggestionY += height
        }
        if applyFrames {
            titleLabel.frame = CGRect(x: titleInset, y: 18, width: titleWidth, height: titleHeight)
            editor.frame = CGRect(x: inputInset, y: inputY, width: inputWidth, height: inputHeight)
            placeholderLabel.frame = CGRect(
                x: inputInset + Self.inputInsets.left, y: inputY + Self.inputInsets.top,
                width: hintWidth, height: hintHeight)
            let lineHeight: CGFloat = isInteractionEnabled && editor.isFirstResponder ? 2 : 1
            // Both nine-patches start the stroke 9dp above the bottom; focus grows it downward to 2dp.
            underline.frame = CGRect(
                x: inputInset + Self.inputInsets.left, y: inputY + inputHeight - 9,
                width: max(0, inputWidth - Self.inputInsets.left - Self.inputInsets.right), height: lineHeight)
            suggestionsView.frame = CGRect(x: inputInset, y: inputY + inputHeight, width: inputWidth, height: suggestionY)
        }
        // abc_alert_dialog_material's customPanel, not EditText, has the 48dp minimum.
        return inputY + max(48, inputHeight + suggestionY)
    }

    private func arrangeActions(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(12, max(0, (width - 32) / 2))
        let availableWidth = max(1, width - inset * 2)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let cancelWidth = cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        if cancelWidth + confirmWidth <= availableWidth {
            let height = max(
                cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude)).height,
                confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames {
                let confirmX = isRTL ? inset : width - inset - confirmWidth
                let cancelX = isRTL ? confirmX + confirmWidth : confirmX - cancelWidth
                confirmControl.frame = CGRect(x: confirmX, y: 4, width: confirmWidth, height: height)
                cancelControl.frame = CGRect(x: cancelX, y: 4, width: cancelWidth, height: height)
                footerView.accessibilityElements = [cancelControl, confirmControl]
            }
            return height + 8
        }
        // AppCompat ButtonBarLayout places the positive action first when stacked.
        var y: CGFloat = 4
        for control in [confirmControl, cancelControl] {
            let controlWidth = min(availableWidth, control.preferredWidth)
            let height = control.sizeThatFits(CGSize(width: controlWidth, height: .greatestFiniteMagnitude)).height
            if applyFrames {
                control.frame = CGRect(x: isRTL ? inset : width - inset - controlWidth, y: y, width: controlWidth, height: height)
            }
            y += height
        }
        if applyFrames { footerView.accessibilityElements = [confirmControl, cancelControl] }
        return y + 4
    }

    private func revealPendingCaret() {
        guard needsCaretReveal else { return }
        needsCaretReveal = false
        guard editor.isFirstResponder, let selection = editor.selectedTextRange else { return }
        editor.layoutIfNeeded()
        let caret = editor.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        var target = editor.convert(caret, to: formView).insetBy(dx: 0, dy: -8)
        target.size.height = min(target.height, scrollView.bounds.height)
        scrollView.scrollRectToVisible(target, animated: false)
    }

    @objc private func showSuggestions() {
        guard isInteractionEnabled, editor.markedTextRange == nil else { return }
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
        offersSuggestions = true
        refreshInput()
        onLayoutChange?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer.view === editor
    }

    @objc private func selectSuggestion(_ control: ReaderCharsetSuggestionControl) {
        guard isInteractionEnabled, editor.markedTextRange == nil, visibleIndices.contains(control.tag) else { return }
        editor.text = Self.charsets[control.tag]
        editor.selectedRange = NSRange(location: (rawText as NSString).length, length: 0)
        offersSuggestions = false
        refreshInput()
        revealCaretOnNextLayout()
        onLayoutChange?()
    }

    @objc private func cancel() {
        guard isInteractionEnabled else { return }
        onCancel?()
    }

    @objc private func confirm() {
        guard isInteractionEnabled else { return }
        onConfirm?()
    }
}

private final class ReaderCharsetDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class ReaderCharsetSuggestionControl: UIControl {
    private let label = AndroidExploreTextLabel()

    init(title: String) {
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(label, text: title, color: AndroidReplicaTheme.primaryText)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            label.alpha = isEnabled ? 1 : 0.5
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = label.sizeThatFits(CGSize(width: max(1, size.width - 12), height: .greatestFiniteMagnitude)).height
        // MyAdapter uses item_1line_text_and_del.xml: 6dp padding and no minimum row height.
        return CGSize(width: size.width, height: ceil(height + 12))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 6, y: 6, width: max(0, bounds.width - 12), height: max(0, bounds.height - 12))
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}
