import UIKit

/// ContentEditDialog.editTitle / dialog_edit_text.xml and AppCompat alert chrome at 5f5d314.
@MainActor
final class ReaderChapterTitleDialogBodyView: UIView {
    var onConfirm: (() -> Void)?

    let editor = UITextView()
    var rawText: String { editor.text ?? "" }
    var accessibilityHeading: UIView { titleLabel }

    private struct Metrics {
        let titleHeight: CGFloat
        let editorHeight: CGFloat
        let errorHeight: CGFloat
        let actionWidth: CGFloat
        let actionHeight: CGFloat

        // AlertController hides titleDividerNoCustom when dialog_edit_text is supplied.
        var headerHeight: CGFloat { 18 + titleHeight }
        var formHeight: CGFloat { max(48, editorHeight + (errorHeight > 0 ? errorHeight + 8 : 0)) }
        var footerHeight: CGFloat { actionHeight + 8 }
        var totalHeight: CGFloat { headerHeight + formHeight + footerHeight }
    }

    private let titleLabel = AndroidExploreTextLabel()
    private let underline = UIView()
    private let errorLabel = UILabel()
    private let scrollView = ReaderChapterTitleDialogScrollView()
    private let scrollContent = UIView()
    private let actionsView = UIView()
    private let confirmControl = ReaderChapterTitleDialogConfirmControl()
    private var scrollsChrome = false
    private var needsCaretReveal = false
    private var needsErrorReveal = false
    private var lastViewportSize: CGSize = .zero

    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        BookshelfLayoutDialogStyle.configure(titleLabel, text: "编辑", color: AndroidReplicaTheme.primaryText)
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.chapterTitleDialog.title"
        BookshelfLayoutDialogStyle.configure(errorLabel, text: "", color: .systemRed)
        errorLabel.adjustsFontForContentSizeCategory = false
        errorLabel.lineBreakMode = .byCharWrapping
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "reader.chapterTitleDialog.error"

        // Seed once. Return, paste and IME input remain multiline and are never normalized.
        editor.text = text
        editor.backgroundColor = .clear
        editor.textColor = AndroidReplicaTheme.primaryText
        editor.tintColor = AndroidReplicaTheme.accent
        editor.isScrollEnabled = false
        editor.scrollsToTop = false
        editor.textContainer.lineFragmentPadding = 0
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
        editor.accessibilityLabel = "编辑"
        editor.accessibilityIdentifier = "reader.chapterTitleDialog.input"
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
        scrollView.accessibilityIdentifier = "reader.chapterTitleDialog.content"
        confirmControl.accessibilityIdentifier = "reader.chapterTitleDialog.confirm"
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        actionsView.accessibilityElements = [confirmControl]
        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(actionsView)
        scrollView.addSubview(scrollContent)
        for child in [editor, underline, errorLabel] { scrollContent.addSubview(child) }
        actionsView.addSubview(confirmControl)
        applyFonts(traits: traitCollection)
        setInteraction(editable: false, confirmEnabled: false, saving: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traits)
        let font = ReaderAndroidDefaultFont.scaledFont(size: 18, textStyle: .body, compatibleWith: traits)
        editor.font = font
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        editor.textContainerInset = UIEdgeInsets(
            top: 10 + padding.top, left: 4, bottom: 7 + padding.bottom, right: 4)
        errorLabel.font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        confirmControl.apply(
            font: ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traits))
        updateEditorFocus()
        revealCaretOnNextLayout()
    }

    func setInteraction(editable: Bool, confirmEnabled: Bool, saving: Bool) {
        if editor.isEditable != editable {
            editor.isEditable = editable
            updateEditorFocus()
        }
        let selectable = !saving
        if editor.isSelectable != selectable { editor.isSelectable = selectable }
        if confirmControl.isEnabled != confirmEnabled { confirmControl.isEnabled = confirmEnabled }
        let saveStatus = saving ? "正在保存" : nil
        if confirmControl.accessibilityValue != saveStatus { confirmControl.accessibilityValue = saveStatus }
    }

    func updateEditorFocus() {
        // AutoCompleteTextView.applyTint tints its entire background, unlike ThemeEditText's state list.
        underline.backgroundColor = AndroidReplicaTheme.accent
        underline.alpha = editor.isEditable ? 1 : (traitCollection.userInterfaceStyle == .dark ? 0.30 : 0.26)
        setNeedsLayout()
    }

    func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        needsErrorReveal = message != nil
        setNeedsLayout()
    }

    func revealCaretOnNextLayout() {
        needsCaretReveal = true
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
        let titleInset = min(24, max(0, (width - 1) / 2))
        let inputInset = min(16, max(0, (width - 1) / 2))
        let inputWidth = max(1, width - inputInset * 2)
        // Normally only the custom input scrolls; tiny keyboard/AX viewports scroll all chrome.
        let shouldScrollChrome = values.headerHeight + values.footerHeight + 48 > bounds.height
        let previousOffset = shouldScrollChrome == scrollsChrome ? scrollView.contentOffset.y : 0
        scrollsChrome = shouldScrollChrome
        let chromeParent = scrollsChrome ? scrollContent : self
        if titleLabel.superview !== chromeParent { chromeParent.addSubview(titleLabel) }
        if actionsView.superview !== chromeParent { chromeParent.addSubview(actionsView) }
        titleLabel.frame = CGRect(
            x: titleInset, y: 18, width: max(1, width - titleInset * 2), height: values.titleHeight)

        let inputY = scrollsChrome ? values.headerHeight : 0
        let viewportHeight =
            scrollsChrome ? bounds.height : max(0, bounds.height - values.headerHeight - values.footerHeight)
        let contentHeight = scrollsChrome ? values.totalHeight : values.formHeight
        scrollView.frame = CGRect(
            x: 0, y: scrollsChrome ? 0 : values.headerHeight, width: width, height: viewportHeight)
        editor.frame = CGRect(x: inputInset, y: inputY, width: inputWidth, height: values.editorHeight)
        let lineHeight: CGFloat = editor.isEditable && editor.isFirstResponder ? 2 : 1
        underline.frame = CGRect(
            x: inputInset + 4, y: editor.frame.maxY - 7 - lineHeight,
            width: max(0, inputWidth - 8), height: lineHeight)
        errorLabel.frame = CGRect(
            x: inputInset, y: editor.frame.maxY + 4, width: inputWidth, height: values.errorHeight)
        actionsView.frame = CGRect(
            x: 0, y: scrollsChrome ? values.headerHeight + values.formHeight : bounds.height - values.footerHeight,
            width: width, height: values.footerHeight)
        let actionInset = min(12, max(0, (width - 1) / 2))
        confirmControl.frame = CGRect(
            x: effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? actionInset : width - actionInset - values.actionWidth, y: 4,
            width: values.actionWidth, height: values.actionHeight)
        scrollContent.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = scrollContent.bounds.size
        scrollView.isScrollEnabled = contentHeight > viewportHeight
        let offset = CGPoint(x: 0, y: min(max(0, previousOffset), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        var formElements: [Any] = [editor]
        if !errorLabel.isHidden { formElements.append(errorLabel) }
        scrollContent.accessibilityElements = scrollsChrome ? [titleLabel] + formElements + [actionsView] : formElements
        accessibilityElements = scrollsChrome ? [scrollView] : [titleLabel, scrollView, actionsView]
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsCaretReveal = true
        }
        revealPendingTarget()
    }

    private func metrics(width: CGFloat) -> Metrics {
        let width = max(1, width)
        let titleInset = min(24, max(0, (width - 1) / 2))
        let inputInset = min(16, max(0, (width - 1) / 2))
        let titleSize = CGSize(width: max(1, width - titleInset * 2), height: .greatestFiniteMagnitude)
        let inputSize = CGSize(width: max(1, width - inputInset * 2), height: .greatestFiniteMagnitude)
        let actionInset = min(12, max(0, (width - 1) / 2))
        let actionWidth = min(confirmControl.preferredWidth, max(1, width - actionInset * 2))
        return Metrics(
            titleHeight: ceil(titleLabel.sizeThatFits(titleSize).height),
            editorHeight: ceil(editor.sizeThatFits(inputSize).height),
            errorHeight: errorLabel.isHidden ? 0 : ceil(errorLabel.sizeThatFits(inputSize).height),
            actionWidth: actionWidth,
            actionHeight: confirmControl.sizeThatFits(
                CGSize(width: actionWidth, height: .greatestFiniteMagnitude)
            ).height)
    }

    private func revealPendingTarget() {
        if needsErrorReveal, !errorLabel.isHidden {
            needsErrorReveal = false
            needsCaretReveal = false
            reveal(errorLabel.frame)
            return
        }
        guard needsCaretReveal else { return }
        needsCaretReveal = false
        guard editor.isFirstResponder, let selection = editor.selectedTextRange else { return }
        editor.layoutIfNeeded()
        let caret = editor.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        reveal(editor.convert(caret, to: scrollContent).insetBy(dx: 0, dy: -8))
    }

    private func reveal(_ rect: CGRect) {
        var target = rect
        target.size.height = min(target.height, scrollView.bounds.height)
        scrollView.scrollRectToVisible(target, animated: false)
    }

    @objc private func confirm() {
        guard confirmControl.isEnabled else { return }
        onConfirm?()
    }
}

@MainActor
private final class ReaderChapterTitleDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

@MainActor
private final class ReaderChapterTitleDialogConfirmControl: UIControl {
    private let label = AndroidExploreTextLabel()

    var preferredWidth: CGFloat {
        let size = label.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return max(64, ceil(size.width) + 16)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.text = "确定"
        label.textColor = AndroidReplicaTheme.accent
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet {
            label.alpha = isEnabled ? 1 : 0.38
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = label.sizeThatFits(CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude)).height
        return CGSize(width: size.width, height: max(48, ceil(height) + 8))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}
