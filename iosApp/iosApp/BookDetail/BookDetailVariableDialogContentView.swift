import UIKit

/// dialog_variable.xml / ToolbarTitle / shape_card_view at Legado 5f5d314.
@MainActor
final class BookDetailVariableDialogContentView: UIView {
    var onSave: (() -> Void)?

    let variableEditor = UITextView()
    var variable: String { variableEditor.text ?? "" }
    var accessibilityHeading: UIView { titleLabel }
    var errorFrame: CGRect? { errorLabel.isHidden ? nil : errorLabel.frame }

    private let toolbar = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let saveButton = UIButton(type: .custom)
    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private let variableLabel = AndroidExploreTextLabel()
    private let editorUnderline = UIView()
    private let errorLabel = AndroidExploreTextLabel()
    private let commentScrollView = UIScrollView()
    private let commentLabel = AndroidExploreTextLabel()
    private let commentView = UITextView()

    init(title: String, variable: String?, comment: String) {
        super.init(frame: .zero)
        // background_card is a resource color, not the configurable page background.
        backgroundColor = UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 48.0 / 255 : 245.0 / 255, alpha: 1)
        }
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.text = title
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookDetail.variableDialog.title"

        saveButton.configuration = nil
        saveButton.automaticallyUpdatesConfiguration = false
        saveButton.setImage(
            UIImage(named: "EditorAndroidSave")?.withRenderingMode(.alwaysTemplate), for: .normal)
        saveButton.tintColor = AndroidReplicaTheme.toolbarText
        saveButton.imageView?.contentMode = .center
        saveButton.contentEdgeInsets = .zero
        saveButton.accessibilityLabel = "保存"
        saveButton.accessibilityIdentifier = "bookDetail.variableDialog.save"
        saveButton.addInteraction(UIToolTipInteraction(defaultToolTip: "保存"))
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        busyIndicator.color = AndroidReplicaTheme.toolbarText
        busyIndicator.hidesWhenStopped = true
        busyIndicator.isUserInteractionEnabled = false
        busyIndicator.isAccessibilityElement = false
        saveButton.addSubview(busyIndicator)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(saveButton)

        configureLabel(variableLabel, text: "variable", color: AndroidReplicaTheme.accent)
        configureLabel(commentLabel, text: "变量说明(variableComment)", color: AndroidReplicaTheme.accent)
        variableLabel.accessibilityIdentifier = "bookDetail.variableDialog.variableLabel"
        commentLabel.accessibilityIdentifier = "bookDetail.variableDialog.commentLabel"
        configureTextView(variableEditor)
        variableEditor.text = variable ?? ""
        variableEditor.textColor = AndroidReplicaTheme.primaryText
        variableEditor.tintColor = AndroidReplicaTheme.accent
        variableEditor.autocorrectionType = .no
        variableEditor.autocapitalizationType = .none
        variableEditor.spellCheckingType = .no
        variableEditor.smartQuotesType = .no
        variableEditor.smartDashesType = .no
        variableEditor.smartInsertDeleteType = .no
        variableEditor.textContentType = nil
        variableEditor.keyboardType = .default
        variableEditor.returnKeyType = .default
        variableEditor.enablesReturnKeyAutomatically = false
        variableEditor.allowsEditingTextAttributes = false
        variableEditor.accessibilityLabel = "variable"
        variableEditor.accessibilityIdentifier = "bookDetail.variableDialog.variable"
        editorUnderline.backgroundColor = AndroidReplicaTheme.secondaryText
        editorUnderline.isUserInteractionEnabled = false
        editorUnderline.isAccessibilityElement = false

        configureLabel(errorLabel, text: "", color: .systemRed)
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "bookDetail.variableDialog.error"
        configureTextView(commentView)
        commentView.isEditable = false
        commentView.text = comment
        commentView.textColor = AndroidReplicaTheme.secondaryText
        commentView.tintColor = AndroidReplicaTheme.accent
        commentView.accessibilityIdentifier = "bookDetail.variableDialog.comment"
        commentScrollView.contentInsetAdjustmentBehavior = .never
        commentScrollView.alwaysBounceVertical = false
        commentScrollView.alwaysBounceHorizontal = false
        commentScrollView.showsHorizontalScrollIndicator = false
        commentScrollView.scrollsToTop = false
        commentScrollView.delaysContentTouches = false
        commentScrollView.accessibilityIdentifier = "bookDetail.variableDialog.commentContent"
        commentScrollView.addSubview(commentLabel)
        commentScrollView.addSubview(commentView)
        for child in [toolbar, variableLabel, variableEditor, editorUnderline, errorLabel, commentScrollView] {
            addSubview(child)
        }
        accessibilityElements = [titleLabel, saveButton, variableLabel, variableEditor, errorLabel, commentLabel, commentView]
        applyFonts(traits: traitCollection)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traits)
        let editorFont = ReaderAndroidDefaultFont.scaledFont(size: 18, textStyle: .body, compatibleWith: traits)
        applyTextMetrics(
            to: variableEditor, font: editorFont,
            // AppCompat 1.7.1 abc_edit_text_material: 4/10/7dp inset, plus 4dp nine-patch bottom padding.
            insets: UIEdgeInsets(top: 10, left: 4, bottom: 11, right: 4), traits: traits)
        let smallFont = AndroidExploreTextMetrics.font(compatibleWith: traits)
        for label in [variableLabel, errorLabel, commentLabel] { label.font = smallFont }
        applyTextMetrics(
            to: commentView, font: smallFont,
            insets: UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), traits: traits)
        updateEditorFocus()
    }

    func setInteraction(editable: Bool, saveEnabled: Bool, saving: Bool) {
        if variableEditor.isEditable != editable { variableEditor.isEditable = editable }
        variableEditor.isUserInteractionEnabled = editable
        saveButton.isEnabled = saveEnabled
        saveButton.imageView?.isHidden = saving
        saveButton.accessibilityValue = saving ? "正在保存" : nil
        saving ? busyIndicator.startAnimating() : busyIndicator.stopAnimating()
        updateEditorFocus()
    }

    func updateEditorFocus() {
        let enabled = variableEditor.isEditable
        // ThemeEditText.applyTint uses TintHelper's state list, not AutoCompleteTextView's flat tint.
        editorUnderline.backgroundColor =
            enabled
            ? (variableEditor.isFirstResponder ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText)
            : UIColor { traits in
                let dark = traits.userInterfaceStyle == .dark
                return UIColor(white: dark ? 1 : 0, alpha: (dark ? 77.0 : 97.0) / 255)
            }
        // The disabled nine-patch has its own alpha in addition to the state-list color alpha.
        editorUnderline.alpha = enabled ? 1 : disabledAlpha
        variableEditor.textColor =
            enabled
            ? AndroidReplicaTheme.primaryText
            : UIColor { traits in
                let dark = traits.userInterfaceStyle == .dark
                return UIColor(white: dark ? 1 : 0, alpha: dark ? 0.30 : (222.0 / 255) * 0.26)
            }
        setNeedsLayout()
    }

    func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width, maximumHeight: size.height, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, maximumHeight: bounds.height, applyFrames: true)
        busyIndicator.center = CGPoint(x: saveButton.bounds.midX, y: saveButton.bounds.midY)
    }

    private func configureLabel(_ label: UILabel, text: String, color: UIColor) {
        label.text = text
        label.textColor = color
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = false
    }

    private func configureTextView(_ textView: UITextView) {
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        // Reopen the file-backed font on trait changes; UIKit scaling can substitute its face.
        textView.adjustsFontForContentSizeCategory = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.dataDetectorTypes = []
        textView.scrollsToTop = false
    }

    private var disabledAlpha: CGFloat { traitCollection.userInterfaceStyle == .dark ? 0.30 : 0.26 }

    private func applyTextMetrics(
        to textView: UITextView, font: UIFont, insets: UIEdgeInsets, traits: UITraitCollection
    ) {
        // Do not rebuild attributedText: the draft, marked text and native selection belong to UITextView.
        if textView.font != font { textView.font = font }
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        let inset = UIEdgeInsets(
            top: insets.top + padding.top, left: insets.left,
            bottom: insets.bottom + padding.bottom, right: insets.right)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
    }

    private func textHeight(_ textView: UITextView, width: CGFloat) -> CGFloat {
        let inset = textView.textContainerInset
        let naturalLine = (textView.font?.lineHeight ?? 0) + inset.top + inset.bottom
        return ceil(
            max(
                naturalLine,
                textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    private func arrange(width: CGFloat, maximumHeight: CGFloat, applyFrames: Bool) -> CGFloat {
        let width = max(1, width)
        var y = arrangeToolbar(width: width, applyFrames: applyFrames)
        y = arrangeLabel(variableLabel, width: width, top: y, applyFrames: applyFrames)
        let editorHeight = textHeight(variableEditor, width: width)
        if applyFrames {
            variableEditor.frame = CGRect(x: 0, y: y, width: width, height: editorHeight)
            let inset = min(4, width / 2)
            let lineHeight: CGFloat = variableEditor.isEditable && variableEditor.isFirstResponder ? 2 : 1
            // Both mdpi nine-patches start their stroke 9dp above the view bottom (1/2dp thick).
            editorUnderline.frame = CGRect(
                x: inset, y: y + editorHeight - 9, width: width - inset * 2, height: lineHeight)
        }
        y += editorHeight
        if !errorLabel.isHidden {
            y = arrangeLabel(errorLabel, width: width, top: y, applyFrames: applyFrames)
        }
        let commentTop = arrangeLabel(commentLabel, width: width, top: 0, applyFrames: applyFrames)
        let commentHeight = textHeight(commentView, width: width)
        let commentContentHeight = commentTop + commentHeight
        let inset = commentView.textContainerInset
        let minimumCommentHeight = commentTop + ceil((commentView.font?.lineHeight ?? 0) + inset.top + inset.bottom)
        // dialog_variable nests only the comment block. Keep one natural line reachable; the outer
        // scroll view handles a keyboard/AX viewport too small for the toolbar and multiline draft.
        let commentViewportHeight = min(commentContentHeight, max(minimumCommentHeight, maximumHeight - y))
        if applyFrames {
            commentScrollView.frame = CGRect(x: 0, y: y, width: width, height: commentViewportHeight)
            commentView.frame = CGRect(x: 0, y: commentTop, width: width, height: commentHeight)
            commentScrollView.contentSize = CGSize(width: width, height: commentContentHeight)
            commentScrollView.isScrollEnabled = commentContentHeight > commentViewportHeight
            let offset = CGPoint(
                x: 0,
                y: min(max(0, commentScrollView.contentOffset.y), max(0, commentContentHeight - commentViewportHeight)))
            if commentScrollView.contentOffset != offset { commentScrollView.contentOffset = offset }
        }
        return y + commentViewportHeight
    }

    private func arrangeToolbar(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let saveWidth = min(48, width)
        // Toolbar contentInsetStart=16dp plus titleMarginStart/End=4dp; no navigation icon.
        let inset = min(20, max(0, width - saveWidth))
        let titleWidth = max(0, width - inset - saveWidth - 4)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            ).height)
        let height = max(56, titleHeight + 8)
        if applyFrames {
            toolbar.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
            titleLabel.frame = CGRect(
                x: isRTL ? min(width, saveWidth + 4) : inset,
                y: (height - titleHeight) / 2, width: titleWidth, height: titleHeight)
            saveButton.frame = CGRect(
                x: isRTL ? 0 : width - saveWidth, y: 4,
                width: saveWidth, height: 48)
        }
        return height
    }

    private func arrangeLabel(_ label: UILabel, width: CGFloat, top: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(3, max(0, (width - 1) / 2))
        let textWidth = max(1, width - inset * 2)
        let height = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        if applyFrames {
            label.frame = CGRect(x: inset, y: top + 3, width: textWidth, height: height)
        }
        return top + height + 6
    }

    @objc private func save() {
        guard saveButton.isEnabled else { return }
        onSave?()
    }
}
