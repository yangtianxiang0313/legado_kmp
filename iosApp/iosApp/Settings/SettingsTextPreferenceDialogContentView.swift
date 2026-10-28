import UIKit

/// preference_dialog_edittext (Preference 1.2.1) / dialog_edit_text at Legado 5f5d314.
@MainActor
final class SettingsTextPreferenceDialogContentView: UIView {
    struct EditingState {
        let selection: NSRange
        let wasFirstResponder: Bool
        let contentOffset: CGPoint
    }

    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?

    let editor: UITextView = SettingsPreferenceSecureTextView()
    var rawText: String { editor.text ?? "" }
    var accessibilityHeading: UIView { titleLabel }
    let usesUserAgentLayout: Bool

    private let titleLabel = AndroidExploreTextLabel()
    private let placeholderLabel = AndroidExploreTextLabel()
    private let statusLabel = AndroidExploreTextLabel()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let underline = UIView()
    private let scrollView = SettingsPreferenceDialogScrollView()
    private let formView = UIView()
    private let footerView = UIView()
    private let cancelControl = BookshelfLayoutDialogAction(title: "取消")
    private let submitControl = BookshelfLayoutDialogAction(title: "确定")
    private var needsCaretReveal = false
    private var needsStatusReveal = false
    private var lastViewportSize: CGSize = .zero

    init(
        titleText: String, value: String?, placeholder: String, isSecure: Bool,
        keyboardType: UIKeyboardType, usesUserAgentLayout: Bool
    ) {
        self.usesUserAgentLayout = usesUserAgentLayout
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        BookshelfLayoutDialogStyle.configure(titleLabel, text: titleText, color: AndroidReplicaTheme.primaryText)
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "settings.textPreferenceDialog.title"
        BookshelfLayoutDialogStyle.configure(
            placeholderLabel, text: placeholder, color: AndroidReplicaTheme.secondaryText)
        placeholderLabel.lineBreakMode = .byCharWrapping
        placeholderLabel.isAccessibilityElement = false
        BookshelfLayoutDialogStyle.configure(statusLabel, text: "", color: .systemRed)
        statusLabel.lineBreakMode = .byCharWrapping
        statusLabel.accessibilityIdentifier = "settings.textPreferenceDialog.status"
        statusLabel.isHidden = true
        progress.hidesWhenStopped = true
        progress.color = AndroidReplicaTheme.accent
        progress.isAccessibilityElement = false
        editor.isSecureTextEntry = isSecure
        editor.text = value ?? ""
        editor.backgroundColor = .clear
        editor.textColor = AndroidReplicaTheme.primaryText
        editor.tintColor = AndroidReplicaTheme.accent
        editor.isScrollEnabled = false
        editor.scrollsToTop = false
        editor.contentInsetAdjustmentBehavior = .never
        editor.textContainer.lineFragmentPadding = 0
        editor.textContainer.maximumNumberOfLines = 0
        editor.textContainer.lineBreakMode = .byWordWrapping
        editor.adjustsFontForContentSizeCategory = false
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContentType = isSecure ? .password : nil
        editor.keyboardType = keyboardType
        editor.returnKeyType = .default
        editor.enablesReturnKeyAutomatically = false
        editor.allowsEditingTextAttributes = false
        editor.dataDetectorTypes = []
        editor.accessibilityLabel = titleText
        editor.accessibilityHint = placeholder.isEmpty ? nil : placeholder
        editor.accessibilityIdentifier = "settings.textPreferenceDialog.input"
        // Preference binds selection at the end; UA's setText alone leaves it at the beginning.
        editor.selectedRange = NSRange(location: usesUserAgentLayout ? 0 : rawText.utf16.count, length: 0)
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
        scrollView.accessibilityIdentifier = "settings.textPreferenceDialog.content"
        cancelControl.accessibilityIdentifier = "settings.textPreferenceDialog.cancel"
        submitControl.accessibilityIdentifier = "settings.textPreferenceDialog.submit"
        for control in [cancelControl, submitControl] { control.isExclusiveTouch = true }
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        submitControl.addTarget(self, action: #selector(submit), for: .touchUpInside)
        addSubview(scrollView)
        scrollView.addSubview(formView)
        for child in [titleLabel, editor, placeholderLabel, underline] {
            formView.addSubview(child)
        }
        for child in [statusLabel, progress, cancelControl, submitControl] { footerView.addSubview(child) }
        updateEditorFocus()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = BookshelfLayoutDialogStyle.font(
            size: 20, weight: .medium, style: .headline, traits: traits)
        let inputFont = BookshelfLayoutDialogStyle.font(size: 18, traits: traits)
        if editor.font != inputFont { editor.font = inputFont }
        placeholderLabel.font = inputFont
        let padding = AndroidExploreTextMetrics.padding(font: inputFont, scale: traits.displayScale)
        // AppCompat 1.7.1 res/drawable-v21/abc_edit_text_material.xml:
        // top=10, left/right=4, bottom=7. Both mdpi abc_textfield_*_mtrl_alpha.9.png
        // content markers add only bottom=4 (not horizontal padding): top/left/bottom/right=10/4/11/4.
        // Preference's AppCompatEditText and UA's AutoComplete share this background; neither
        // their styles nor ThemeEditText disables includeFontPadding or swaps these axes.
        let insets = UIEdgeInsets(top: 10 + padding.top, left: 4, bottom: 11 + padding.bottom, right: 4)
        if editor.textContainerInset != insets { editor.textContainerInset = insets }
        statusLabel.font = BookshelfLayoutDialogStyle.font(size: 14, traits: traits)
        let actionFont = BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits)
        cancelControl.apply(font: actionFont)
        submitControl.apply(font: actionFont)
        backgroundColor = AndroidReplicaTheme.background
        editor.textColor = AndroidReplicaTheme.primaryText
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        placeholderLabel.textColor = AndroidReplicaTheme.secondaryText
        updateEditorFocus()
        revealCaretOnNextLayout()
    }

    func captureEditingState() -> EditingState {
        EditingState(
            selection: editor.selectedRange, wasFirstResponder: editor.isFirstResponder,
            contentOffset: scrollView.contentOffset)
    }

    func restoreEditingState(_ state: EditingState) {
        // Never reassign text (especially secure text), or disturb an active IME composition.
        guard editor.isEditable, editor.markedTextRange == nil else { return }
        if state.wasFirstResponder { editor.becomeFirstResponder() }
        let count = rawText.utf16.count
        let start = min(state.selection.location, count)
        editor.selectedRange = NSRange(location: start, length: min(state.selection.length, count - start))
        scrollView.setContentOffset(state.contentOffset, animated: false)
        updateEditorFocus()
        revealCaretOnNextLayout()
    }

    func setInteraction(editable: Bool, cancelEnabled: Bool, submitEnabled: Bool, busy: Bool) {
        if editor.isEditable != editable { editor.isEditable = editable }
        if cancelControl.isEnabled != cancelEnabled { cancelControl.isEnabled = cancelEnabled }
        if submitControl.isEnabled != submitEnabled { submitControl.isEnabled = submitEnabled }
        if busy {
            progress.startAnimating()
            statusLabel.text = "保存中"
            statusLabel.textColor = AndroidReplicaTheme.secondaryText
            statusLabel.isHidden = false
        } else {
            progress.stopAnimating()
        }
        updateEditorFocus()
    }

    func showStatus(_ message: String?) {
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = message == nil
        needsStatusReveal = message != nil
        setNeedsLayout()
    }

    func updateEditorFocus() {
        placeholderLabel.isHidden =
            (placeholderLabel.text ?? "").isEmpty || !rawText.isEmpty
            || editor.markedTextRange != nil
        let defaultAlpha: CGFloat = 222 / 255
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let disabledAlpha: CGFloat = isNight ? 0.30 : 0.26
        if usesUserAgentLayout {
            // AutoComplete is not AppCompatEditText: setTintAuto takes the flat background branch.
            underline.backgroundColor = AndroidReplicaTheme.accent
        } else if !editor.isEditable {
            // TintHelper.setTint(AppCompatEditText): ate_text_disabled_light/dark.
            underline.backgroundColor = UIColor(white: isNight ? 1 : 0, alpha: isNight ? 77 / 255 : 97 / 255)
        } else if editor.isFirstResponder {
            underline.backgroundColor = AndroidReplicaTheme.accent
        } else {
            // ate_control_normal_light=#8A000000, dark=#B3FFFFFF.
            underline.backgroundColor = UIColor(white: isNight ? 1 : 0, alpha: isNight ? 179 / 255 : 138 / 255)
        }
        underline.alpha =
            editor.isEditable ? (editor.isFirstResponder ? 1 : defaultAlpha) : defaultAlpha * disabledAlpha
        setNeedsLayout()
    }

    func revealCaretOnNextLayout() {
        needsCaretReveal = true
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: arrangeForm(width: size.width, applyFrames: false)
                + arrangeActions(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let formHeight = arrangeForm(width: width, applyFrames: true)
        let footerHeight = arrangeActions(width: width, applyFrames: true)
        let pinsFooter = bounds.height >= footerHeight + min(48, editor.bounds.height)
        let footerParent = pinsFooter ? self : formView
        if footerView.superview !== footerParent { footerParent.addSubview(footerView) }
        footerView.frame = CGRect(
            x: 0, y: pinsFooter ? bounds.height - footerHeight : formHeight,
            width: width, height: footerHeight)
        let viewportHeight = max(0, bounds.height - (pinsFooter ? footerHeight : 0))
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        formView.frame = CGRect(x: 0, y: 0, width: width, height: formHeight + (pinsFooter ? 0 : footerHeight))
        scrollView.contentSize = formView.bounds.size
        scrollView.isScrollEnabled = formView.bounds.height > viewportHeight
        let offset = CGPoint(
            x: 0,
            y: min(max(0, scrollView.contentOffset.y), max(0, formView.bounds.height - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        var elements: [Any] = [titleLabel, editor]
        if !pinsFooter { elements.append(footerView) }
        formView.accessibilityElements = elements
        accessibilityElements = pinsFooter ? [scrollView, footerView] : [scrollView]
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsCaretReveal = true
        }
        if needsStatusReveal, !statusLabel.isHidden, viewportHeight > 0 {
            needsStatusReveal = false
            if pinsFooter {
                revealPendingCaret()
            } else {
                needsCaretReveal = false
                let target = footerView.convert(statusLabel.frame, to: formView)
                scrollView.scrollRectToVisible(target.insetBy(dx: 0, dy: -4), animated: false)
            }
        } else {
            revealPendingCaret()
        }
    }

    private func arrangeForm(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let titleInset = min(24, max(0, (width - 1) / 2))
        let titleWidth = max(1, width - titleInset * 2)
        let titleHeight = pixelCeil(
            titleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            ).height)
        let inputInset = min(usesUserAgentLayout ? 16 : 20, max(0, (width - 1) / 2))
        let inputWidth = max(1, width - inputInset * 2)
        let insets = editor.textContainerInset
        let hintWidth = max(1, inputWidth - insets.left - insets.right)
        let hintHeight = pixelCeil(
            placeholderLabel.sizeThatFits(
                CGSize(width: hintWidth, height: .greatestFiniteMagnitude)
            ).height)
        let measured = editor.sizeThatFits(CGSize(width: inputWidth, height: .greatestFiniteMagnitude)).height
        let lineHeight = (editor.font?.lineHeight ?? 22) + insets.top + insets.bottom
        let inputHeight = pixelCeil(max(usesUserAgentLayout ? 0 : 48, measured, lineHeight, hintHeight + 21))
        // Preference inflates with a nil parent, and AlertController installs fresh LayoutParams:
        // its root's XML 48dp top/bottom margins do not survive. No titleDividerNoCustom gap either.
        let inputY = 18 + titleHeight
        if applyFrames {
            titleLabel.frame = CGRect(x: titleInset, y: 18, width: titleWidth, height: titleHeight)
            editor.frame = CGRect(x: inputInset, y: inputY, width: inputWidth, height: inputHeight)
            placeholderLabel.frame = CGRect(
                x: inputInset + insets.left, y: inputY + 10,
                width: hintWidth, height: hintHeight)
            underline.frame = CGRect(
                x: inputInset + 4, y: inputY + inputHeight - 9,
                width: max(0, inputWidth - 8), height: editor.isEditable && editor.isFirstResponder ? 2 : 1)
        }
        return inputY + max(48, inputHeight)
    }

    private func arrangeStatus(width: CGFloat, applyFrames: Bool) -> CGFloat {
        if !statusLabel.isHidden {
            let inset = min(24, max(0, (width - 1) / 2))
            let spinnerWidth: CGFloat = progress.isAnimating ? 28 : 0
            let statusWidth = max(1, width - inset * 2 - spinnerWidth)
            let statusHeight = pixelCeil(
                statusLabel.sizeThatFits(
                    CGSize(width: statusWidth, height: .greatestFiniteMagnitude)
                ).height)
            let rowHeight = max(statusHeight, progress.isAnimating ? 20 : 0)
            if applyFrames {
                let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                statusLabel.frame = CGRect(
                    x: inset + (rtl ? 0 : spinnerWidth), y: 4,
                    width: statusWidth, height: rowHeight)
                progress.frame = CGRect(
                    x: rtl ? width - inset - 20 : inset,
                    y: 4 + (rowHeight - 20) / 2, width: 20, height: 20)
            }
            return rowHeight + 8
        }
        return 0
    }

    private func arrangeActions(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let statusHeight = arrangeStatus(width: width, applyFrames: applyFrames)
        let statusElements: [Any] = statusLabel.isHidden ? [] : [statusLabel]
        let inset = min(12, max(0, (width - 32) / 2))
        let available = max(1, width - inset * 2)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let cancelWidth = pixelCeil(cancelControl.preferredWidth)
        let submitWidth = pixelCeil(submitControl.preferredWidth)
        if cancelWidth + submitWidth <= available {
            let height = pixelCeil(
                max(
                    cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude)).height,
                    submitControl.sizeThatFits(CGSize(width: submitWidth, height: .greatestFiniteMagnitude)).height))
            if applyFrames {
                let submitX = rtl ? inset : width - inset - submitWidth
                submitControl.frame = CGRect(x: submitX, y: statusHeight + 4, width: submitWidth, height: height)
                cancelControl.frame = CGRect(
                    x: rtl ? submitX + submitWidth : submitX - cancelWidth,
                    y: statusHeight + 4, width: cancelWidth, height: height)
                footerView.accessibilityElements = statusElements + [cancelControl, submitControl]
            }
            return statusHeight + height + 8
        }
        // ButtonBarLayout reverses its children in the stacked arrangement: positive first.
        var y: CGFloat = statusHeight + 4
        for control in [submitControl, cancelControl] {
            let controlWidth = min(available, pixelCeil(control.preferredWidth))
            let height = pixelCeil(
                control.sizeThatFits(
                    CGSize(width: controlWidth, height: .greatestFiniteMagnitude)
                ).height)
            if applyFrames {
                control.frame = CGRect(
                    x: rtl ? inset : width - inset - controlWidth, y: y,
                    width: controlWidth, height: height)
            }
            y += height
        }
        if applyFrames { footerView.accessibilityElements = statusElements + [submitControl, cancelControl] }
        return y + 4
    }

    private func pixelCeil(_ value: CGFloat) -> CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return ceil(value * scale) / scale
    }

    private func revealPendingCaret() {
        guard needsCaretReveal, scrollView.bounds.height > 0 else { return }
        needsCaretReveal = false
        guard editor.isFirstResponder, let selection = editor.selectedTextRange else { return }
        editor.layoutIfNeeded()
        let caret = editor.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        var target = editor.convert(caret, to: formView).insetBy(dx: 0, dy: -8)
        target.size.height = min(target.height, scrollView.bounds.height)
        scrollView.scrollRectToVisible(target, animated: false)
    }

    @objc private func cancel() {
        guard cancelControl.isEnabled else { return }
        onCancel?()
    }

    @objc private func submit() {
        guard submitControl.isEnabled else { return }
        onSubmit?()
    }
}

private final class SettingsPreferenceSecureTextView: UITextView {
    override var accessibilityValue: String? {
        get {
            guard isSecureTextEntry else { return super.accessibilityValue }
            return (text ?? "").isEmpty ? "未输入密码" : "已输入密码"
        }
        set { if !isSecureTextEntry { super.accessibilityValue = newValue } }
    }

    override var accessibilityAttributedValue: NSAttributedString? {
        get { isSecureTextEntry ? nil : super.accessibilityAttributedValue }
        set { if !isSecureTextEntry { super.accessibilityAttributedValue = newValue } }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if isSecureTextEntry,
            action != #selector(paste(_:)), action != #selector(select(_:)),
            action != #selector(selectAll(_:)), action != #selector(delete(_:))
        {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

private final class SettingsPreferenceDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is BookshelfLayoutDialogAction || super.touchesShouldCancel(in: view)
    }
}
