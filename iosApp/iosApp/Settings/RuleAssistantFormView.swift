import UIKit
import shared

final class RuleAssistantFormView: UIScrollView {
    var onChange: (() -> Void)?
    var onGenerate: (() -> Void)?
    var onPreview: (() -> Void)?
    var onWritingTools: (() -> Void)?
    var onConfirmationChange: (() -> Void)?

    let mode = UISegmentedControl(items: [
        ruleAssistantString("apple", "Apple 智能"), ruleAssistantString("templates", "常用模板"),
    ])
    let request = RuleAssistantInput(title: ruleAssistantString("request", "处理要求"), identifier: "request", height: 90)
    let sample = RuleAssistantInput(title: ruleAssistantString("sample", "样例正文"), identifier: "sample", height: 150)
    let protectedText = RuleAssistantInput(
        title: ruleAssistantString("protected", "需要保留的文本"), identifier: "protected", height: 90)
    let matchText = RuleAssistantInput(title: ruleAssistantString("match", "匹配文字"), identifier: "match", height: 64)
    let replacement = RuleAssistantInput(
        title: ruleAssistantString("replacement", "替换为"), identifier: "replacement", height: 64)
    private let stack = UIStackView()
    private let aiStack = UIStackView()
    private let modelStatus = UILabel()
    private let operationButton = UIButton(type: .system)
    private let generateButton = UIButton(type: .system)
    private let previewButton = UIButton(type: .system)
    private let writingToolsButton = UIButton(type: .system)
    private let resultStack = UIStackView()
    private let summary = UILabel()
    private let output = RuleAssistantInput(
        title: ruleAssistantString("output", "替换后"), identifier: "output", height: 150)
    private let advancedButton = UIButton(type: .system)
    private let expression = RuleAssistantInput(
        title: ruleAssistantString("expression", "表达式"), identifier: "expression", height: 72)
    private let confirmationRow = UIStackView()
    private let confirmation = UISwitch()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var modelAvailable = false
    private(set) var operation = RuleAssistantOperation.replaceLiteral

    var plan: RuleAssistantPlan {
        RuleAssistantPlan(
            operation: operation, text: operation == .collapseBlankLines ? "" : matchText.text,
            replacement: operation == .replaceLiteral ? replacement.text : "")
    }

    var deletionConfirmed: Bool { confirmation.isOn }

    init(scope: String, excludeScope: String, sampleText: String, replacementText: String) {
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -32),
        ])
        for section in [aiStack, resultStack] {
            section.axis = .vertical
            section.spacing = 12
        }
        for label in [modelStatus, summary] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textColor = AndroidReplicaTheme.secondaryText
        }
        configureButton(
            generateButton, title: ruleAssistantString("generate", "生成草稿"), image: "wand.and.stars",
            identifier: "generate")
        configureButton(previewButton, title: ruleAssistantString("preview", "预览"), image: "eye", identifier: "preview")
        configureButton(
            writingToolsButton, title: ruleAssistantString("writing_tools", "系统写作工具"), image: "pencil.and.outline",
            identifier: "writingTools")
        generateButton.addAction(UIAction { [weak self] _ in self?.onGenerate?() }, for: .touchUpInside)
        previewButton.addAction(UIAction { [weak self] _ in self?.onPreview?() }, for: .touchUpInside)
        writingToolsButton.addAction(UIAction { [weak self] _ in self?.onWritingTools?() }, for: .touchUpInside)
        mode.selectedSegmentIndex = 1
        mode.accessibilityIdentifier = "ruleAssistant.mode"
        mode.addAction(
            UIAction { [weak self] _ in
                self?.updateMode()
                self?.onChange?()
            }, for: .valueChanged)
        for input in [request, sample, protectedText, matchText, replacement] {
            input.onChange = { [weak self] in self?.onChange?() }
            input.onBeginEditing = { [weak self, weak input] in
                guard let self, let input else { return }
                self.scrollRectToVisible(input.convert(input.bounds, to: self).insetBy(dx: 0, dy: -12), animated: true)
            }
        }
        sample.text = sampleText
        matchText.text = sampleText.contains("\n") || sampleText.utf16.count > 512 ? "" : sampleText
        replacement.text = replacementText
        for child in [modelStatus, request, generateButton, writingToolsButton] { aiStack.addArrangedSubview(child) }
        operationButton.accessibilityIdentifier = "ruleAssistant.operation"
        operationButton.showsMenuAsPrimaryAction = true
        operationButton.contentHorizontalAlignment = .leading
        operationButton.titleLabel?.numberOfLines = 0
        operationButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        operationButton.titleLabel?.adjustsFontForContentSizeCategory = true
        operationButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        updateOperationMenu()
        output.textView.isEditable = false
        expression.textView.isEditable = false
        expression.textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        configureButton(
            advancedButton, title: ruleAssistantString("advanced", "表达式"), image: "chevron.down", identifier: "advanced"
        )
        advancedButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.expression.isHidden.toggle()
                self.advancedButton.configuration?.image = UIImage(
                    systemName: self.expression.isHidden ? "chevron.down" : "chevron.up")
            }, for: .touchUpInside)
        let confirmationLabel = UILabel()
        confirmationLabel.text = ruleAssistantString("confirm_deletion", "确认样例中超过一半的内容被删除")
        confirmationLabel.font = .preferredFont(forTextStyle: .body)
        confirmationLabel.adjustsFontForContentSizeCategory = true
        confirmationLabel.textColor = AndroidReplicaTheme.primaryText
        confirmationLabel.numberOfLines = 0
        confirmationRow.axis = .horizontal
        confirmationRow.spacing = 12
        confirmationRow.alignment = .center
        confirmationRow.addArrangedSubview(confirmationLabel)
        confirmationRow.addArrangedSubview(confirmation)
        confirmation.accessibilityLabel = confirmationLabel.text
        confirmation.accessibilityIdentifier = "ruleAssistant.confirmDeletion"
        confirmation.addAction(UIAction { [weak self] _ in self?.onConfirmationChange?() }, for: .valueChanged)
        for child in [summary, output, confirmationRow, advancedButton, expression] {
            resultStack.addArrangedSubview(child)
        }
        let scopeLabel = UILabel()
        scopeLabel.font = .preferredFont(forTextStyle: .footnote)
        scopeLabel.adjustsFontForContentSizeCategory = true
        scopeLabel.textColor = AndroidReplicaTheme.secondaryText
        scopeLabel.numberOfLines = 0
        scopeLabel.text =
            scope.isEmpty
            ? ruleAssistantString("scope_all", "当前草稿范围：全部书籍")
            : ruleAssistantString("scope_selected", "当前草稿范围（书名或书源）：") + scope
        if !excludeScope.isEmpty {
            scopeLabel.text =
                (scopeLabel.text ?? "") + "\n" + ruleAssistantString("scope_excluded", "排除范围：") + excludeScope
        }
        activity.hidesWhenStopped = true
        for child in [
            mode, aiStack, sample, protectedText, operationButton, matchText, replacement,
            previewButton, activity, resultStack, scopeLabel,
        ] { stack.addArrangedSubview(child) }
        clearPreview()
        updateMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func setCapability(
        _ capability: RuleAssistantModelService.Capability, writingToolsAvailable: Bool, initial: Bool = false
    ) {
        modelAvailable = capability.available
        modelStatus.text = capability.message
        generateButton.isEnabled = capability.available
        writingToolsButton.isHidden = !writingToolsAvailable
        if initial { mode.selectedSegmentIndex = capability.available || writingToolsAvailable ? 0 : 1 }
        updateMode()
    }

    func setPlan(_ plan: RuleAssistantPlan) {
        operation = plan.operation
        matchText.text = plan.text
        replacement.text = plan.replacement
        updateOperationMenu()
        clearPreview()
    }

    func setBusy(_ busy: Bool) {
        for input in [request, sample, protectedText, matchText, replacement] { input.textView.isEditable = !busy }
        for control in [mode, operationButton, previewButton, writingToolsButton] { control.isEnabled = !busy }
        generateButton.isEnabled = busy || modelAvailable
        generateButton.configuration?.title =
            busy
            ? ruleAssistantString("stop", "停止处理") : ruleAssistantString("generate", "生成草稿")
        generateButton.configuration?.image = UIImage(systemName: busy ? "stop.circle" : "wand.and.stars")
        if busy { activity.startAnimating() } else { activity.stopAnimating() }
    }

    func clearPreview() {
        resultStack.isHidden = true
        confirmation.isOn = false
        expression.isHidden = true
        advancedButton.configuration?.image = UIImage(systemName: "chevron.down")
        sample.textView.textStorage.removeAttribute(
            .backgroundColor, range: NSRange(location: 0, length: sample.textView.textStorage.length))
        var typingAttributes = sample.textView.typingAttributes
        typingAttributes.removeValue(forKey: .backgroundColor)
        sample.textView.typingAttributes = typingAttributes
    }

    func showPreview(_ preview: RuleAssistantPreview) {
        clearPreview()
        resultStack.isHidden = false
        let count = preview.matches.count
        let protectedCount = Int(preview.protectedMatchCount)
        summary.text = String(format: ruleAssistantString("matches", "命中 %d 处 · 保留文本命中 %d 处"), count, protectedCount)
        if count == 0 {
            summary.text = ruleAssistantString("no_matches", "样例中没有匹配内容，尚不能应用")
        } else if protectedCount > 0 {
            summary.text = ruleAssistantString("protected_changed", "需要保留的文本也被匹配，请调整规则")
        } else if preview.output.utf16.elementsEqual(sample.text.utf16) {
            summary.text = ruleAssistantString("unchanged_output", "样例内容没有变化，尚不能应用")
        }
        summary.textColor = count == 0 || protectedCount > 0 ? .systemRed : AndroidReplicaTheme.secondaryText
        output.text = preview.output.isEmpty ? ruleAssistantString("empty_output", "（空文本）") : preview.output
        expression.text = preview.pattern
        confirmationRow.isHidden = !preview.requiresDeletionConfirmation
        for match in preview.matches {
            let range = NSRange(location: Int(match.start), length: Int(match.length))
            guard NSMaxRange(range) <= sample.textView.textStorage.length else { continue }
            sample.textView.textStorage.addAttribute(
                .backgroundColor, value: AndroidReplicaTheme.accent.withAlphaComponent(0.2), range: range)
        }
        setNeedsLayout()
    }

    private func updateMode() { aiStack.isHidden = mode.selectedSegmentIndex != 0 }

    private func updateOperationMenu() {
        operationButton.setTitle(operation.title + "  ", for: .normal)
        operationButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        operationButton.tintColor = AndroidReplicaTheme.accent
        operationButton.menu = UIMenu(
            children: RuleAssistantOperation.allCases.map { item in
                UIAction(title: item.title, state: operation == item ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.operation = item
                    self.updateOperationMenu()
                    self.onChange?()
                }
            })
        matchText.isHidden = operation == .collapseBlankLines
        replacement.isHidden = operation != .replaceLiteral
    }

    private func configureButton(_ button: UIButton, title: String, image: String, identifier: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 8
        configuration.baseForegroundColor = AndroidReplicaTheme.accent
        configuration.titleLineBreakMode = .byWordWrapping
        button.configuration = configuration
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityIdentifier = "ruleAssistant.\(identifier)"
    }
}

final class RuleAssistantInput: UIView, UITextViewDelegate {
    let textView = UITextView()
    var onChange: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var text: String {
        get { textView.text ?? "" }
        set { textView.text = newValue }
    }

    init(title: String, identifier: String, height: CGFloat) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = AndroidReplicaTheme.secondaryText
        textView.delegate = self
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.tintColor = AndroidReplicaTheme.accent
        textView.layer.borderWidth = 1 / UIScreen.main.scale
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.cornerRadius = 4
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = title
        textView.accessibilityIdentifier = "ruleAssistant.\(identifier)"
        if #available(iOS 18.0, *) { textView.writingToolsBehavior = .none }
        for child in [label, textView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.heightAnchor.constraint(equalToConstant: height),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func textViewDidChange(_ textView: UITextView) { onChange?() }
    func textViewDidBeginEditing(_ textView: UITextView) { onBeginEditing?() }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        textView.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }
}
