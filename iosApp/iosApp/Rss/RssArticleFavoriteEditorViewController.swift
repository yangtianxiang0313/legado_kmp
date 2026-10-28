import UIKit
import shared

@MainActor
final class RssArticleFavoriteEditorViewController: UITableViewController, UITextFieldDelegate,
    UIAdaptivePresentationControllerDelegate, NavigationBackActionHandling
{
    var onSave: ((String, String) async throws -> Void)? {
        didSet {
            if isViewLoaded { updateControls() }
        }
    }

    var onDelete: (() async throws -> Void)? {
        didSet {
            guard isViewLoaded else { return }
            tableView.reloadData()
            updateControls()
        }
    }

    var groups: [String] {
        didSet {
            if isViewLoaded { updateGroupMenu() }
        }
    }

    private let titleField = UITextField()
    private let groupField = UITextField()
    private let titleCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let groupCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let deleteCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let groupMenuButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var isSubmitting = false
    private var didCompleteOperation = false
    private var isClosing = false
    private var originalPopGestureEnabled: Bool?
    private var pendingFailure: (title: String, message: String)?

    init(star: RssStar, groups: [String] = []) {
        self.groups = groups
        super.init(style: .insetGrouped)
        title = "编辑收藏"
        modalPresentationStyle = .formSheet
        titleField.text = star.title
        groupField.text = star.group
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("Use init(star:groups:)") }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "rss.favorite.editor"
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.accessibilityLabel = L10n.Common.cancel
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "rss.favorite.cancel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "保存"
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "rss.favorite.save"

        configureField(titleField, cell: titleCell, label: "标题", identifier: "rss.favorite.title")
        configureField(groupField, cell: groupCell, label: "分组", identifier: "rss.favorite.group")
        titleField.returnKeyType = .next
        groupField.returnKeyType = .done
        groupField.addTarget(self, action: #selector(groupDidChange), for: .editingChanged)

        groupMenuButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        groupMenuButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
        groupMenuButton.showsMenuAsPrimaryAction = true
        groupMenuButton.accessibilityLabel = "选择分组"
        groupMenuButton.accessibilityIdentifier = "rss.favorite.groups"
        groupMenuButton.addInteraction(UIToolTipInteraction(defaultToolTip: "选择分组"))
        updateGroupMenu()

        deleteCell.textLabel?.text = "删除收藏"
        deleteCell.textLabel?.textColor = .systemRed
        deleteCell.textLabel?.font = .preferredFont(forTextStyle: .body)
        deleteCell.textLabel?.adjustsFontForContentSizeCategory = true
        deleteCell.textLabel?.numberOfLines = 0
        deleteCell.imageView?.image = UIImage(systemName: "trash")
        deleteCell.imageView?.tintColor = .systemRed
        deleteCell.accessibilityTraits.insert(.button)
        deleteCell.accessibilityIdentifier = "rss.favorite.delete"
        activityIndicator.accessibilityIdentifier = "rss.favorite.progress"
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        presentationController?.delegate = self
        navigationController?.presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if didCompleteOperation {
            closeEditor()
        } else {
            showPendingFailure()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { onDelete == nil ? 2 : 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "标题"
        case 1: return "分组"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0: return titleCell
        case 1: return groupCell
        default: return deleteCell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2, canStartOperation, let onDelete else { return }
        performOperation(failureTitle: "删除失败", progressLabel: "正在删除收藏", operation: onDelete)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard canStartOperation else { return false }
        if textField === titleField {
            groupField.becomeFirstResponder()
        } else {
            save()
        }
        return false
    }

    func interceptNavigationBackGesture() -> Bool { isSubmitting || didCompleteOperation || isClosing }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !isSubmitting && !didCompleteOperation && !isClosing
    }

    override func accessibilityPerformEscape() -> Bool {
        guard !isSubmitting, !didCompleteOperation, !isClosing else { return false }
        cancel()
        return true
    }

    private func configureField(_ field: UITextField, cell: UITableViewCell, label: String, identifier: String) {
        cell.selectionStyle = .none
        field.delegate = self
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = label
        field.accessibilityIdentifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    @objc private func groupDidChange() { updateGroupMenu() }

    private func updateGroupMenu() {
        var seen = Set<String>()
        let options = groups.filter { seen.insert($0).inserted }
        groupCell.accessoryView = options.isEmpty ? nil : groupMenuButton
        groupMenuButton.menu = UIMenu(
            children: options.map { group in
                UIAction(title: group.isEmpty ? "未分组" : group, state: groupField.text == group ? .on : .off) {
                    [weak self] _ in
                    guard let self, self.canStartOperation else { return }
                    self.groupField.text = group
                    self.updateGroupMenu()
                }
            })
    }

    private var canStartOperation: Bool {
        !isSubmitting && !didCompleteOperation && !isClosing && viewIfLoaded?.window != nil
            && !isBeingDismissed && !isMovingFromParent && navigationController?.isBeingDismissed != true
    }

    @objc private func cancel() {
        guard !isSubmitting, !didCompleteOperation, !isClosing else { return }
        closeEditor()
    }

    @objc private func save() {
        guard canStartOperation, let onSave else { return }
        view.endEditing(true)
        let title = titleField.text ?? ""
        let group = groupField.text ?? ""
        performOperation(failureTitle: "保存失败", progressLabel: "正在保存收藏") {
            try await onSave(title, group)
        }
    }

    private func performOperation(
        failureTitle: String, progressLabel: String, operation: @escaping () async throws -> Void
    ) {
        guard canStartOperation else { return }
        view.endEditing(true)
        pendingFailure = nil
        activityIndicator.accessibilityLabel = progressLabel
        setSubmitting(true)
        // Accepted writes finish independently of presentation; never report success for a missing callback.
        Task { @MainActor [weak self] in
            do {
                try await operation()
                guard let self else { return }
                self.didCompleteOperation = true
                self.setSubmitting(false)
                self.closeEditor()
            } catch {
                guard let self else { return }
                self.setSubmitting(false)
                self.pendingFailure = (failureTitle, error.userFacingMessage)
                self.showPendingFailure()
            }
        }
    }

    private func setSubmitting(_ submitting: Bool) {
        isSubmitting = submitting
        isModalInPresentation = submitting
        navigationController?.isModalInPresentation = submitting
        if let gesture = navigationController?.interactivePopGestureRecognizer {
            if submitting {
                originalPopGestureEnabled = gesture.isEnabled
                gesture.isEnabled = false
            } else if let original = originalPopGestureEnabled {
                gesture.isEnabled = original
                originalPopGestureEnabled = nil
            }
        }
        navigationItem.titleView = submitting ? activityIndicator : nil
        if submitting { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        updateControls()
    }

    private func updateControls() {
        let enabled = !isSubmitting && !didCompleteOperation && !isClosing
        navigationItem.leftBarButtonItem?.isEnabled = enabled
        navigationItem.rightBarButtonItem?.isEnabled = enabled && onSave != nil
        titleField.isEnabled = enabled
        groupField.isEnabled = enabled
        groupMenuButton.isEnabled = enabled
        tableView.isUserInteractionEnabled = enabled
        deleteCell.isUserInteractionEnabled = enabled && onDelete != nil
        deleteCell.contentView.alpha = enabled ? 1 : 0.5
    }

    private func closeEditor() {
        guard !isSubmitting, !isClosing, viewIfLoaded?.window != nil, presentedViewController == nil,
            !isBeingDismissed, navigationController?.isBeingDismissed != true
        else { return }
        if let navigation = navigationController, navigation.topViewController !== self { return }
        isClosing = true
        updateControls()
        view.endEditing(true)
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func showPendingFailure() {
        guard let failure = pendingFailure, viewIfLoaded?.window != nil, presentedViewController == nil,
            !isBeingDismissed, navigationController?.isBeingDismissed != true
        else { return }
        pendingFailure = nil
        let alert = UIAlertController(title: failure.title, message: failure.message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "rss.favorite.error"
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
        present(alert, animated: true)
    }
}
