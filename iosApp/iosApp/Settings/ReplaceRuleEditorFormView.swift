import UIKit

// Field order and 10dp content padding: 5f5d314 activity_replace_edit.xml.
final class ReplaceRuleEditorFormView: UIScrollView, UITextViewDelegate {
    var onChange: (() -> Void)?
    var onHelp: (() -> Void)?

    private let stack = UIStackView()
    private let nameField = ReplaceRuleEditorInput(title: "替换规则名称", identifier: "name")
    private let groupField = ReplaceRuleEditorInput(title: "分组", identifier: "group")
    private let patternField = ReplaceRuleEditorInput(title: "替换规则", identifier: "pattern")
    private let replacementField = ReplaceRuleEditorInput(title: "替换为", identifier: "replacement")
    private let scopeField = ReplaceRuleEditorInput(title: "替换范围，选填书名或者书源 URL", identifier: "scope")
    private let excludeField = ReplaceRuleEditorInput(title: "排除范围，选填书名或者书源 URL", identifier: "excludeScope")
    private let timeoutField = ReplaceRuleEditorInput(title: "超时毫秒数", identifier: "timeout")
    private let regexCheck = ReplaceRuleEditorCheckBox(title: "使用正则表达式")
    private let titleCheck = ReplaceRuleEditorCheckBox(title: "作用于标题")
    private let contentCheck = ReplaceRuleEditorCheckBox(title: "作用于正文")
    private let helpButton = UIButton(type: .custom)
    private weak var activeTextView: UITextView?
    private var lastViewportSize = CGSize.zero
    private var selectionRevealScheduled = false

    private var fields: [ReplaceRuleEditorInput] {
        [nameField, groupField, patternField, replacementField, scopeField, excludeField, timeoutField]
    }

    var draft: ReplaceRuleEditorDraft {
        var result = ReplaceRuleEditorDraft(rule: nil)
        result.name = nameField.textView.text
        result.group = groupField.textView.text
        result.pattern = patternField.textView.text
        result.replacement = replacementField.textView.text
        result.scope = scopeField.textView.text
        result.excludeScope = excludeField.textView.text
        result.timeout = timeoutField.textView.text
        result.isRegex = regexCheck.isSelected
        result.scopeTitle = titleCheck.isSelected
        result.scopeContent = contentCheck.isSelected
        return result
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        delaysContentTouches = false
        accessibilityIdentifier = "replaceRule.editor.form"

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -10),
            stack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -20),
        ])

        let keyboardBar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        keyboardBar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                image: UIImage(systemName: "keyboard.chevron.compact.down"),
                style: .plain, target: self, action: #selector(dismissKeyboard)
            ),
        ]
        keyboardBar.items?.last?.accessibilityLabel = "收起键盘"
        for field in fields {
            field.textView.delegate = self
            field.textView.inputAccessoryView = RestoredKeyboardAccessory(textView: field.textView)
        }
        timeoutField.textView.keyboardType = .numberPad
        timeoutField.textView.accessibilityHint = "毫秒"
        for check in [regexCheck, titleCheck, contentCheck] {
            check.addAction(UIAction { [weak self] _ in self?.onChange?() }, for: .valueChanged)
        }
        regexCheck.accessibilityIdentifier = "replaceRule.editor.isRegex"
        titleCheck.accessibilityIdentifier = "replaceRule.editor.scopeTitle"
        contentCheck.accessibilityIdentifier = "replaceRule.editor.scopeContent"
        helpButton.setImage(ReplaceRuleEditorIcons.help, for: .normal)
        helpButton.tintColor = AndroidReplicaTheme.primaryText
        helpButton.accessibilityLabel = "帮助"
        helpButton.accessibilityIdentifier = "replaceRule.editor.regexHelp"
        helpButton.addInteraction(UIToolTipInteraction(defaultToolTip: "正则教程"))
        helpButton.addAction(UIAction { [weak self] _ in self?.onHelp?() }, for: .touchUpInside)
        helpButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        helpButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let regexRow = UIStackView(arrangedSubviews: [regexCheck, helpButton])
        regexRow.axis = .horizontal
        regexRow.alignment = .center
        regexCheck.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let scopeRow = UIStackView(arrangedSubviews: [titleCheck, contentCheck, UIView()])
        scopeRow.axis = .horizontal
        scopeRow.alignment = .center
        scopeRow.spacing = 10
        for child in [
            nameField, groupField, patternField, regexRow, replacementField,
            scopeRow, scopeField, excludeField, timeoutField,
        ] {
            stack.addArrangedSubview(child)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func populate(_ draft: ReplaceRuleEditorDraft) {
        nameField.textView.text = draft.name
        groupField.textView.text = draft.group
        patternField.textView.text = draft.pattern
        replacementField.textView.text = draft.replacement
        scopeField.textView.text = draft.scope
        excludeField.textView.text = draft.excludeScope
        timeoutField.textView.text = draft.timeout
        regexCheck.isSelected = draft.isRegex
        titleCheck.isSelected = draft.scopeTitle
        contentCheck.isSelected = draft.scopeContent
        for field in fields { field.refreshAppearance() }
        setNeedsLayout()
    }

    func setEditable(_ editable: Bool) {
        for field in fields { field.textView.isEditable = editable }
        for control in [regexCheck, titleCheck, contentCheck, helpButton] { control.isEnabled = editable }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = frameLayoutGuide.layoutFrame.width - 20
        // Keep both independent checkboxes reachable at narrow widths / large text sizes.
        if let row = titleCheck.superview as? UIStackView {
            let required = titleCheck.intrinsicContentSize.width + contentCheck.intrinsicContentSize.width + 20
            let axis: NSLayoutConstraint.Axis = required > width ? .vertical : .horizontal
            if row.axis != axis {
                row.axis = axis
                row.alignment = axis == .vertical ? .leading : .center
            }
        }
        if lastViewportSize != bounds.size {
            lastViewportSize = bounds.size
            revealSelection()
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        activeTextView = textView
        fields.first(where: { $0.textView === textView })?.refreshAppearance()
        revealSelection()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        fields.first(where: { $0.textView === textView })?.refreshAppearance()
        if activeTextView === textView { activeTextView = nil }
    }

    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        fields.first(where: { $0.textView === textView })?.refreshAppearance()
        onChange?()
        revealSelection()
    }

    func textViewDidChangeSelection(_: UITextView) {
        revealSelection()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        revealSelection()
    }

    private func revealSelection() {
        guard !selectionRevealScheduled else { return }
        selectionRevealScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionRevealScheduled = false
            guard let textView = self.activeTextView,
                let range = textView.selectedTextRange
            else { return }
            self.layoutIfNeeded()
            let caret = textView.caretRect(for: range.end).insetBy(dx: -6, dy: -12)
            self.scrollRectToVisible(textView.convert(caret, to: self), animated: false)
        }
    }

    @objc private func dismissKeyboard() { endEditing(true) }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class ReplaceRuleEditorInput: UIView {
    let textView = ReplaceRuleEditorGrowingTextView()
    private let hintLabel = UILabel()
    private let placeholderLabel = UILabel()
    private let underline = UIView()
    private var underlineHeight: NSLayoutConstraint!
    private var placeholderMinimumHeight: NSLayoutConstraint!

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        hintLabel.text = title
        hintLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12))
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.numberOfLines = 0
        hintLabel.isAccessibilityElement = false
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = title
        textView.accessibilityIdentifier = "replaceRule.editor.\(identifier)"
        placeholderLabel.text = title
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        for child in [hintLabel, textView, placeholderLabel, underline] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        underlineHeight = underline.heightAnchor.constraint(equalToConstant: 1)
        placeholderMinimumHeight = textView.heightAnchor.constraint(
            greaterThanOrEqualTo: placeholderLabel.heightAnchor, constant: 12)
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 2),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 6),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            underline.topAnchor.constraint(equalTo: textView.bottomAnchor),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underlineHeight,
            underline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func refreshAppearance() {
        let floats = textView.isFirstResponder || !textView.text.isEmpty
        hintLabel.alpha = floats ? 1 : 0
        placeholderLabel.isHidden = floats
        placeholderMinimumHeight.isActive = !floats
        hintLabel.textColor = AndroidReplicaTheme.accent
        placeholderLabel.textColor = AndroidReplicaTheme.accent
        underline.backgroundColor =
            textView.isFirstResponder
            ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText.withAlphaComponent(0.5)
        underlineHeight.constant = textView.isFirstResponder ? 2 : 1
        textView.invalidateIntrinsicContentSize()
    }
}

private final class ReplaceRuleEditorGrowingTextView: UITextView {
    private var measuredWidth: CGFloat = 0

    override var text: String! {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 36)
        }
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(36, ceil(fitting.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

private final class ReplaceRuleEditorCheckBox: UIControl {
    private let imageView = UIImageView()
    private let label = UILabel()

    override var isSelected: Bool { didSet { refresh() } }

    override var intrinsicContentSize: CGSize {
        let size = label.intrinsicContentSize
        return CGSize(width: 32 + size.width + 4, height: max(48, size.height + 12))
    }

    init(title: String) {
        super.init(frame: .zero)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        isAccessibilityElement = true
        accessibilityLabel = title
        label.text = title
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = AndroidReplicaTheme.primaryText
        imageView.contentMode = .center
        for child in [imageView, label] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.isUserInteractionEnabled = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.isSelected.toggle()
                self.sendActions(for: .valueChanged)
            }, for: .touchUpInside)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func refresh() {
        imageView.image = isSelected ? ReplaceRuleEditorIcons.checked : ReplaceRuleEditorIcons.unchecked
        imageView.tintColor = isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        accessibilityValue = isSelected ? "已选中" : "未选中"
    }
}
