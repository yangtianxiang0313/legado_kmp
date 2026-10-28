import UIKit

@MainActor
final class CacheExportOptionsViewController: UITableViewController, UITextFieldDelegate {
    private enum Section: Int, CaseIterable {
        case chapters, format, content, fileNames
    }

    private let format: CacheExportFormat
    private let onExport: (CacheExportOptions) -> Void
    private var draft: CacheExportOptions
    private var selectsChapters: Bool
    private var splitsEPUB: Bool
    private var hasFinished = false
    private var hasDeliveredExport = false
    private var isVisible = false
    private var previousNavigationBarHidden: Bool?
    private var controlCells: [ObjectIdentifier: CacheExportOptionsControlCell] = [:]

    private let scopeField = UITextField()
    private let countField = UITextField()
    private let fileNameEditor = UITextView()
    private let splitFileNameEditor = UITextView()
    private let splitSwitch = UISwitch()
    private let titleSwitch = UISwitch()
    private let replaceSwitch = UISwitch()
    private let charsetButton = UIButton(type: .system)

    private lazy var cancelButton = UIBarButtonItem(
        title: "取消", style: .plain, target: self, action: #selector(cancel))
    private lazy var exportButton = UIBarButtonItem(
        title: "导出", style: .done, target: self, action: #selector(confirmExport))
    private lazy var keyboardToolbar: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finishEditing)),
        ]
        toolbar.sizeToFit()
        return toolbar
    }()

    // The owner presents this in a navigation controller and owns persistence and export work.
    init(
        options: CacheExportOptions, format: CacheExportFormat,
        onExport: @escaping (CacheExportOptions) -> Void
    ) {
        draft = options
        draft.charset = CacheExportOptions.supportedCharset(options.charset)
        self.format = format
        self.onExport = onExport
        selectsChapters = !options.chapterScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        splitsEPUB = format == .epub && options.chaptersPerFile > 0
        super.init(style: .insetGrouped)
        title = "导出设置"
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = exportButton
        tableView.accessibilityIdentifier = "cache.export.options"
        cancelButton.accessibilityIdentifier = "cache.export.options.cancel"
        exportButton.accessibilityIdentifier = "cache.export.options.export"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.keyboardDismissMode = .interactive

        configure(scopeField, title: "章节范围", identifier: "chapterScope")
        scopeField.placeholder = "1-5,8,10-18"
        scopeField.keyboardType = .numbersAndPunctuation
        scopeField.text = draft.chapterScope
        configure(countField, title: "每卷章数", identifier: "chaptersPerFile")
        countField.keyboardType = .numberPad
        countField.text = draft.chaptersPerFile > 0 ? String(draft.chaptersPerFile) : ""

        configure(fileNameEditor, title: "文件名 JS", identifier: "fileNameScript")
        fileNameEditor.text = draft.fileNameScript
        configure(splitFileNameEditor, title: "分卷文件名 JS", identifier: "splitFileNameScript")
        splitFileNameEditor.text = draft.splitFileNameScript

        configure(splitSwitch, title: "EPUB 分卷", identifier: "splitEPUB", value: splitsEPUB)
        splitSwitch.addTarget(self, action: #selector(splitChanged), for: .valueChanged)
        configure(titleSwitch, title: "章节标题", identifier: "includeChapterTitle", value: draft.includeChapterTitle)
        configure(replaceSwitch, title: "替换净化", identifier: "useReplaceRules", value: draft.useReplaceRules)
        configureCharsetButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController?.isNavigationBarHidden
        }
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            view.endEditing(true)
            if let previousNavigationBarHidden {
                navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .chapters: return "章节"
        case .format: return format.title
        case .content: return "正文"
        case .fileNames: return "文件名"
        case nil: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .chapters: return selectsChapters ? 3 : 2
        case .format: return format == .epub && splitsEPUB ? 2 : 1
        case .content: return 2
        case .fileNames: return format == .txt ? 1 : 2
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .chapters:
            if indexPath.row < 2 {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                let selected = (indexPath.row == 1) == selectsChapters
                cell.textLabel?.text = indexPath.row == 0 ? "全部章节" : "指定章节"
                cell.textLabel?.font = .preferredFont(forTextStyle: .body)
                cell.textLabel?.adjustsFontForContentSizeCategory = true
                cell.textLabel?.numberOfLines = 0
                cell.textLabel?.lineBreakMode = .byWordWrapping
                cell.accessoryType = selected ? .checkmark : .none
                cell.accessibilityTraits = selected ? [.button, .selected] : .button
                cell.accessibilityIdentifier = "cache.export.options.\(indexPath.row == 0 ? "allChapters" : "selectedChapters")"
                return cell
            }
            return controlCell(title: "章节范围", control: scopeField)
        case .format:
            if format == .txt { return controlCell(title: "字符集", control: charsetButton) }
            if indexPath.row == 0 { return controlCell(title: "EPUB 分卷", control: splitSwitch, inline: true) }
            return controlCell(title: "每卷章数", control: countField)
        case .content:
            return indexPath.row == 0
                ? controlCell(title: "章节标题", control: titleSwitch, inline: true)
                : controlCell(title: "替换净化", control: replaceSwitch, inline: true)
        case .fileNames:
            return indexPath.row == 0
                ? controlCell(title: "文件名 JS (name, author)", control: fileNameEditor)
                : controlCell(title: "分卷文件名 JS (name, author, epubIndex)", control: splitFileNameEditor)
        case nil:
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canInteract, indexPath.section == Section.chapters.rawValue, indexPath.row < 2 else { return }
        let selected = indexPath.row == 1
        guard selectsChapters != selected else { return }
        scopeField.resignFirstResponder()
        selectsChapters = selected
        tableView.reloadSections(IndexSet(integer: Section.chapters.rawValue), with: .none)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        cancel()
        return true
    }

    private func configure(_ field: UITextField, title: String, identifier: String) {
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = title
        field.accessibilityIdentifier = "cache.export.options.\(identifier)"
        field.delegate = self
        field.inputAccessoryView = keyboardToolbar
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configure(_ editor: UITextView, title: String, identifier: String) {
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .clear
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.spellCheckingType = .no
        editor.accessibilityLabel = title
        editor.accessibilityIdentifier = "cache.export.options.\(identifier)"
        editor.inputAccessoryView = keyboardToolbar
    }

    private func configure(_ control: UISwitch, title: String, identifier: String, value: Bool) {
        control.isOn = value
        control.accessibilityLabel = title
        control.accessibilityIdentifier = "cache.export.options.\(identifier)"
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureCharsetButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 8
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byCharWrapping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .body)
            return attributes
        }
        charsetButton.configuration = configuration
        charsetButton.contentHorizontalAlignment = .leading
        charsetButton.titleLabel?.adjustsFontForContentSizeCategory = true
        charsetButton.titleLabel?.numberOfLines = 0
        charsetButton.accessibilityLabel = "字符集"
        charsetButton.accessibilityIdentifier = "cache.export.options.charset"
        charsetButton.showsMenuAsPrimaryAction = true
        charsetButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateCharsetMenu()
    }

    private func updateCharsetMenu() {
        charsetButton.configuration?.title = draft.charset
        charsetButton.accessibilityValue = draft.charset
        charsetButton.menu = UIMenu(
            options: .singleSelection,
            children: CacheExportOptions.charsets.map { charset in
                UIAction(title: charset, state: charset == draft.charset ? .on : .off) { [weak self] _ in
                    guard let self, self.canInteract else { return }
                    self.draft.charset = charset
                    self.updateCharsetMenu()
                }
            })
    }

    private func controlCell(title: String, control: UIView, inline: Bool = false) -> UITableViewCell {
        let key = ObjectIdentifier(control)
        if let cell = controlCells[key] { return cell }
        let cell = CacheExportOptionsControlCell(title: title, control: control, inline: inline)
        controlCells[key] = cell
        return cell
    }

    @objc private func splitChanged() {
        guard canInteract else { return }
        countField.resignFirstResponder()
        splitsEPUB = splitSwitch.isOn
        tableView.reloadSections(IndexSet(integer: Section.format.rawValue), with: .none)
    }

    @objc private func finishEditing() { view.endEditing(true) }

    private var canInteract: Bool {
        !hasFinished && isVisible && viewIfLoaded?.window != nil && !isBeingDismissed
            && navigationController?.isBeingDismissed != true
    }

    private var dismissalTarget: UIViewController? {
        if let navigationController, navigationController.presentingViewController != nil {
            return navigationController
        }
        return presentingViewController != nil ? self : nil
    }

    @objc private func cancel() {
        guard canInteract else { return }
        hasFinished = true
        view.endEditing(true)
        if let dismissalTarget {
            dismissalTarget.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func confirmExport() {
        guard canInteract, presentedViewController == nil, let dismissalTarget else { return }
        view.endEditing(true)
        var options = draft
        options.chapterScope = ""
        options.chaptersPerFile = 0
        if selectsChapters {
            let scope = (scopeField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !scope.isEmpty else {
                showError("请输入章节范围", field: scopeField, at: IndexPath(row: 2, section: Section.chapters.rawValue))
                return
            }
            guard scope.utf16.count <= CacheExportOptions.maximumChapterScopeLength else {
                showError(
                    "章节范围不能超过 \(CacheExportOptions.maximumChapterScopeLength) 个字符", field: scopeField,
                    at: IndexPath(row: 2, section: Section.chapters.rawValue))
                return
            }
            options.chapterScope = scope
        }
        if format == .epub && splitsEPUB {
            let count = (countField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !count.isEmpty, count.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let number = Int32(count), number > 0
            else {
                showError(
                    "每卷章数须为 1 至 \(Int32.max) 的整数", field: countField,
                    at: IndexPath(row: 1, section: Section.format.rawValue))
                return
            }
            options.chaptersPerFile = Int(number)
        }
        options.includeChapterTitle = titleSwitch.isOn
        options.useReplaceRules = replaceSwitch.isOn
        options.fileNameScript = fileNameEditor.text ?? ""
        options.splitFileNameScript = splitFileNameEditor.text ?? ""
        for (script, editor, row, title) in [
            (options.fileNameScript, fileNameEditor, 0, "文件名 JS"),
            (options.splitFileNameScript, splitFileNameEditor, 1, "分卷文件名 JS"),
        ] {
            guard script.utf8.count <= CacheExportOptions.maximumFileNameScriptLength else {
                showError(
                    "\(title) 不能超过 16 KiB", field: editor,
                    at: IndexPath(row: row, section: Section.fileNames.rawValue))
                return
            }
        }
        // Shared code remains authoritative for chapter syntax, bounds and JavaScript evaluation.
        hasFinished = true
        exportButton.isEnabled = false
        cancelButton.isEnabled = false
        tableView.isUserInteractionEnabled = false
        dismissalTarget.isModalInPresentation = true
        dismissalTarget.dismiss(animated: true) { [self, dismissalTarget] in
            guard !hasDeliveredExport, dismissalTarget.presentingViewController == nil, viewIfLoaded?.window == nil
            else { return }
            hasDeliveredExport = true
            onExport(options)
        }
    }

    private func showError(_ message: String, field: UIView, at indexPath: IndexPath) {
        let alert = UIAlertController(title: "导出设置", message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "确定", style: .default) { [weak self, weak field] _ in
                guard let self, self.canInteract else { return }
                self.tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
                field?.becomeFirstResponder()
            })
        present(alert, animated: true)
    }
}

@MainActor
private final class CacheExportOptionsControlCell: UITableViewCell {
    private var editorHeight: NSLayoutConstraint?

    init(title: String, control: UIView, inline: Bool) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = inline ? .horizontal : .vertical
        stack.alignment = inline ? .center : .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        if let editor = control as? UITextView {
            editorHeight = editor.heightAnchor.constraint(equalToConstant: editorHeightValue)
            editorHeight?.isActive = true
        } else if !inline {
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        editorHeight?.constant = editorHeightValue
    }

    private var editorHeightValue: CGFloat {
        max(110, UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection).lineHeight * 4)
    }
}
