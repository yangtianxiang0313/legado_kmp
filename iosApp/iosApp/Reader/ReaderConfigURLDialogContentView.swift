import UIKit

@MainActor
final class ReaderConfigURLDialogContentView: UIView {
    enum Configuration {
        // BgTextConfigDialog.importNetConfigAlert / ivEdit and ThemeConfigFragment.alertSaveTheme.
        case url
        case rename(name: String)
        case themeName(name: String)

        var title: String {
            switch self {
            case .url: return "输入地址"
            case .rename: return "样式名称："
            case .themeName: return "主题名称"
            }
        }

        var hint: String? {
            switch self {
            case .url: return nil
            case .rename, .themeName: return "name"
            }
        }

        var initialText: String {
            switch self {
            case .url: return ""
            case .rename(let name), .themeName(let name): return name
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .url: return "reader.configURLDialog"
            case .rename: return "readerAppearance.backgroundText.renameDialog"
            case .themeName: return "settings.theme.nameDialog"
            }
        }

        var fieldAccessibilityIdentifier: String {
            switch self {
            case .url: return "reader.configURLDialog.input"
            case .rename: return "readerAppearance.backgroundText.renameField"
            case .themeName: return "settings.theme.nameDialog.input"
            }
        }
    }

    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?

    let editor = UITextView()
    var rawText: String { editor.text ?? "" }
    var accessibilityHeading: UIView { titleLabel }
    var dialogAccessibilityIdentifier: String { configuration.accessibilityIdentifier }

    private let configuration: Configuration
    private let titleLabel = AndroidExploreTextLabel()
    private let placeholderLabel = AndroidExploreTextLabel()
    private let underline = UIView()
    private let scrollView = ReaderConfigURLDialogScrollView()
    private let formView = UIView()
    private let footerView = UIView()
    private let cancelControl = BookshelfLayoutDialogAction(title: "取消")
    // AlertBuilder.okButton uses android.R.string.ok (zh-CN: 确定), not the app's R.string.ok (确认).
    private let submitControl = BookshelfLayoutDialogAction(title: "确定")
    private var needsCaretReveal = false
    private var lastViewportSize: CGSize = .zero

    override convenience init(frame: CGRect) {
        self.init(frame: frame, configuration: .url)
    }

    init(frame: CGRect, configuration: Configuration) {
        self.configuration = configuration
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        BookshelfLayoutDialogStyle.configure(
            titleLabel, text: configuration.title, color: AndroidReplicaTheme.primaryText)
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.accessibilityTraits = .header
        let identifier = configuration.accessibilityIdentifier
        titleLabel.accessibilityIdentifier = "\(identifier).title"
        BookshelfLayoutDialogStyle.configure(
            placeholderLabel, text: configuration.hint ?? "", color: AndroidReplicaTheme.secondaryText)
        placeholderLabel.lineBreakMode = .byCharWrapping
        placeholderLabel.isAccessibilityElement = false
        // Seed once, before editing; never replace text or selection during IME composition.
        editor.text = configuration.initialText
        editor.backgroundColor = .clear
        editor.textColor = AndroidReplicaTheme.primaryText
        editor.tintColor = AndroidReplicaTheme.accent
        editor.isScrollEnabled = false
        editor.scrollsToTop = false
        editor.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 11, right: 4)
        editor.textContainer.lineFragmentPadding = 0
        // dialog_edit_text.xml does not impose singleLine, maxLines or a length limit.
        editor.textContainer.maximumNumberOfLines = 0
        editor.textContainer.lineBreakMode = .byWordWrapping
        editor.contentInsetAdjustmentBehavior = .never
        editor.adjustsFontForContentSizeCategory = false
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContentType = nil
        editor.keyboardType = .default
        editor.returnKeyType = .default
        editor.enablesReturnKeyAutomatically = false
        editor.allowsEditingTextAttributes = false
        editor.dataDetectorTypes = []
        // URL input has no hint; both name editors use the literal Android hint "name".
        editor.accessibilityLabel = configuration.hint ?? configuration.title
        editor.accessibilityIdentifier = configuration.fieldAccessibilityIdentifier
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
        scrollView.accessibilityIdentifier = "\(identifier).content"
        cancelControl.accessibilityIdentifier = "\(identifier).cancel"
        submitControl.accessibilityIdentifier = "\(identifier).submit"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        submitControl.addTarget(self, action: #selector(submit), for: .touchUpInside)
        addSubview(scrollView)
        scrollView.addSubview(formView)
        for child in [titleLabel, editor, placeholderLabel, underline] { formView.addSubview(child) }
        for control in [cancelControl, submitControl] { footerView.addSubview(control) }
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
        // abc_edit_text_material: 4/10/7 inset + the nine-patch's 4dp bottom content padding.
        let inputInsets = UIEdgeInsets(
            top: 10 + padding.top, left: 4, bottom: 11 + padding.bottom, right: 4)
        if editor.textContainerInset != inputInsets { editor.textContainerInset = inputInsets }
        let actionFont = BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits)
        cancelControl.apply(font: actionFont)
        submitControl.apply(font: actionFont)
        revealCaretOnNextLayout()
    }

    func setInteraction(editable: Bool, submitEnabled: Bool) {
        if editor.isEditable != editable {
            editor.isEditable = editable
            updateEditorFocus()
        }
        if cancelControl.isEnabled != editable { cancelControl.isEnabled = editable }
        if submitControl.isEnabled != submitEnabled { submitControl.isEnabled = submitEnabled }
    }

    func updateEditorFocus() {
        placeholderLabel.isHidden = configuration.hint == nil || !rawText.isEmpty || editor.markedTextRange != nil
        // AutoCompleteTextView.applyTint tints every enabled background state with the accent.
        let defaultAlpha: CGFloat = 222 / 255
        let disabledAlpha: CGFloat = ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0.30 : 0.26
        underline.backgroundColor = AndroidReplicaTheme.accent
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
        // Keep actions reachable; a very short keyboard/AX viewport scrolls all chrome together.
        let pinsFooter = bounds.height >= footerHeight + min(48, editor.bounds.height)
        let footerParent = pinsFooter ? self : formView
        if footerView.superview !== footerParent { footerParent.addSubview(footerView) }
        footerView.frame = CGRect(
            x: 0, y: pinsFooter ? bounds.height - footerHeight : formHeight,
            width: width, height: footerHeight)
        let viewportHeight = max(0, bounds.height - (pinsFooter ? footerHeight : 0))
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        let contentHeight = formHeight + (pinsFooter ? 0 : footerHeight)
        formView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = formView.bounds.size
        scrollView.isScrollEnabled = contentHeight > viewportHeight
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        formView.accessibilityElements = pinsFooter ? [titleLabel, editor] : [titleLabel, editor, footerView]
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
        let titleHeight = roundUpToPixel(
            titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let inputInset = min(16, max(0, (width - 1) / 2))
        let inputWidth = max(1, width - inputInset * 2)
        let inputInsets = editor.textContainerInset
        let hintWidth = max(1, inputWidth - inputInsets.left - inputInsets.right)
        let hintHeight =
            configuration.hint == nil
            ? 0
            : roundUpToPixel(
                placeholderLabel.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude)).height)
        let measured = editor.sizeThatFits(CGSize(width: inputWidth, height: .greatestFiniteMagnitude))
        let minimumTextHeight = (editor.font?.lineHeight ?? 22) + inputInsets.top + inputInsets.bottom
        let inputHeight = roundUpToPixel(max(max(minimumTextHeight, hintHeight + 21), measured.height))
        // A custom view leaves titleDividerNoCustom hidden; neither XML adds a vertical form gap.
        let inputY = 18 + titleHeight
        if applyFrames {
            titleLabel.frame = CGRect(x: titleInset, y: 18, width: titleWidth, height: titleHeight)
            editor.frame = CGRect(x: inputInset, y: inputY, width: inputWidth, height: inputHeight)
            placeholderLabel.frame = CGRect(
                x: inputInset + inputInsets.left, y: inputY + 10, width: hintWidth, height: hintHeight)
            let lineHeight: CGFloat = editor.isEditable && editor.isFirstResponder ? 2 : 1
            // Both mdpi nine-patches start their line 2dp above the inner bottom (outer inset: 7dp).
            underline.frame = CGRect(
                x: inputInset + 4, y: inputY + inputHeight - 9,
                width: max(0, inputWidth - 8), height: lineHeight)
        }
        // The 48dp minimum belongs to customPanel, not to the EditText itself.
        return inputY + max(48, inputHeight)
    }

    private func arrangeActions(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(12, max(0, (width - 32) / 2))
        let availableWidth = max(1, width - inset * 2)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let cancelWidth = roundUpToPixel(cancelControl.preferredWidth)
        let submitWidth = roundUpToPixel(submitControl.preferredWidth)
        if cancelWidth + submitWidth <= availableWidth {
            let height = roundUpToPixel(
                max(
                    cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude)).height,
                    submitControl.sizeThatFits(CGSize(width: submitWidth, height: .greatestFiniteMagnitude)).height))
            if applyFrames {
                let submitX = isRTL ? inset : width - inset - submitWidth
                let cancelX = isRTL ? submitX + submitWidth : submitX - cancelWidth
                submitControl.frame = CGRect(x: submitX, y: 4, width: submitWidth, height: height)
                cancelControl.frame = CGRect(x: cancelX, y: 4, width: cancelWidth, height: height)
                footerView.accessibilityElements = [cancelControl, submitControl]
            }
            return height + 8
        }
        // AppCompat ButtonBarLayout reverses its children when stacked: positive first.
        var y: CGFloat = 4
        for control in [submitControl, cancelControl] {
            let controlWidth = min(availableWidth, roundUpToPixel(control.preferredWidth))
            let height = roundUpToPixel(
                control.sizeThatFits(CGSize(width: controlWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames {
                control.frame = CGRect(
                    x: isRTL ? inset : width - inset - controlWidth, y: y, width: controlWidth, height: height)
            }
            y += height
        }
        if applyFrames { footerView.accessibilityElements = [submitControl, cancelControl] }
        return y + 4
    }

    private func roundUpToPixel(_ value: CGFloat) -> CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return ceil(value * scale) / scale
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

    @objc private func cancel() {
        guard cancelControl.isEnabled else { return }
        onCancel?()
    }

    @objc private func submit() {
        guard submitControl.isEnabled else { return }
        onSubmit?()
    }
}

private final class ReaderConfigURLDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is BookshelfLayoutDialogAction || super.touchesShouldCancel(in: view)
    }
}
