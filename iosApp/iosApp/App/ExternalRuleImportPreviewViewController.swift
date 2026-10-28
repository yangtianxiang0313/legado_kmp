import UIKit

@MainActor
final class ExternalRuleImportPreviewViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    var onImported: (() -> Void)?
    private let document: ExternalRuleImportDocument
    private let adapter = ExternalRuleImportAdapter()
    private var selected: Set<Int>
    private var imported: Set<Int> = []
    private var saveTask: Task<Void, Never>?
    private var stopRequested = false
    private weak var expectedWindow: UIWindow?
    private weak var expectedRoot: UIViewController?
    private weak var expectedRootTop: UIViewController?
    private weak var expectedPresenter: UIViewController?
    private let statusLabel = UILabel()
    private lazy var confirmButton = UIBarButtonItem(title: "确认导入", style: .done, target: self, action: #selector(confirm))
    private lazy var cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    private lazy var selectionButton = UIBarButtonItem(
        image: UIImage(systemName: "checkmark.circle"), style: .plain, target: self, action: #selector(toggleAll))

    init(document: ExternalRuleImportDocument) {
        self.document = document
        selected = Set(document.rows.indices)
        super.init(style: .plain)
        title = "导入\(document.kind.title)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "externalRuleImport.preview"
        tableView.accessibilityIdentifier = "externalRuleImport.list"
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        confirmButton.accessibilityIdentifier = "externalRuleImport.confirm"
        cancelButton.accessibilityIdentifier = "externalRuleImport.cancel"
        selectionButton.accessibilityIdentifier = "externalRuleImport.selectAll"
        selectionButton.accessibilityLabel = "全选 / 取消全选"
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItems = [confirmButton, selectionButton]
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "externalRuleImport.status"
        statusLabel.frame = CGRect(x: 16, y: 0, width: 280, height: 44)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        header.addSubview(statusLabel)
        tableView.tableHeaderView = header
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if expectedWindow == nil, let window = view.window {
            expectedWindow = window
            expectedRoot = window.rootViewController
            expectedRootTop = (window.rootViewController as? UINavigationController)?.topViewController
            expectedPresenter = navigationController?.presentingViewController
        }
        navigationController?.presentationController?.delegate = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = max(1, tableView.bounds.width - 32)
        let height = max(44, statusLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 24)
        statusLabel.frame = CGRect(x: 16, y: 12, width: width, height: height - 24)
        if let header = tableView.tableHeaderView, abs(header.frame.height - height) > 0.5 {
            header.frame.size = CGSize(width: tableView.bounds.width, height: height)
            tableView.tableHeaderView = header
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { document.rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "rule") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "rule")
        let row = document.rows[indexPath.row]
        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.text = imported.contains(indexPath.row) ? "已导入" : row.summary
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.tintColor = AndroidReplicaTheme.accent
        cell.accessoryType = selected.contains(indexPath.row) || imported.contains(indexPath.row) ? .checkmark : .none
        cell.accessibilityIdentifier = "externalRuleImport.row.\(indexPath.row)"
        cell.accessibilityTraits = selected.contains(indexPath.row) ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canInteract, saveTask == nil, !imported.contains(indexPath.row) else { return }
        if selected.contains(indexPath.row) { selected.remove(indexPath.row) } else { selected.insert(indexPath.row) }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateControls()
    }

    private var canInteract: Bool {
        guard hasCurrentPresentation, canPerformNavigationAction,
            let root = expectedRoot, let presenter = expectedPresenter,
            root.transitionCoordinator == nil, presenter.transitionCoordinator == nil,
            !root.isBeingPresented, !root.isBeingDismissed,
            !presenter.isBeingPresented, !presenter.isBeingDismissed
        else { return false }
        return true
    }

    private var hasCurrentPresentation: Bool {
        guard let window = expectedWindow, let root = expectedRoot, let presenter = expectedPresenter,
            let navigation = navigationController, viewIfLoaded?.window === window,
            window.rootViewController === root, navigation.topViewController === self,
            navigation.presentingViewController === presenter, presenter.presentedViewController === navigation,
            !navigation.isBeingDismissed, !isBeingDismissed
        else { return false }
        if let rootNavigation = root as? UINavigationController {
            guard rootNavigation.topViewController === expectedRootTop else { return false }
        }
        return true
    }

    @objc private func toggleAll() {
        guard canInteract, saveTask == nil else { return }
        let available = Set(document.rows.indices).subtracting(imported)
        selected = selected == available ? [] : available
        tableView.reloadData()
        updateControls()
    }

    @objc private func cancel() {
        guard canInteract else { return }
        if saveTask != nil {
            // Shared writes cannot be rolled back by cancelling the Swift continuation.
            // Finish the current row, then stop before starting another one.
            stopRequested = true
            cancelButton.isEnabled = false
            statusLabel.text = "正在停止，等待当前规则保存完成"
        } else {
            navigationController?.dismiss(animated: true)
        }
    }

    @objc private func confirm() {
        guard canInteract, saveTask == nil, !selected.isEmpty else { return }
        let indices = selected.sorted()
        stopRequested = false
        navigationController?.isModalInPresentation = true
        saveTask = Task { [self] in
            var failure: Error?
            var count = 0
            for index in indices {
                do {
                    try Task.checkCancellation()
                    guard !stopRequested else { break }
                    try await waitUntilActive()
                    guard !stopRequested else { break }
                    try await adapter.save(document.rows[index])
                    imported.insert(index)
                    selected.remove(index)
                    count += 1
                    statusLabel.text = "已导入 \(count)/\(indices.count)"
                    tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
                } catch {
                    failure = error
                    break
                }
            }
            saveTask = nil
            navigationController?.isModalInPresentation = false
            updateControls()
            if let failure {
                statusLabel.text = "本次已导入 \(count) 条，剩余项未完成：\(failure.userFacingMessage)"
            } else if stopRequested {
                statusLabel.text = "已停止，本次已导入 \(count) 条"
            } else {
                onImported?()
                navigationController?.dismiss(animated: true)
            }
            view.setNeedsLayout()
        }
        updateControls()
    }

    private func waitUntilActive() async throws {
        while !canInteract {
            try Task.checkCancellation()
            guard !stopRequested, hasCurrentPresentation
            else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func updateControls() {
        let busy = saveTask != nil
        confirmButton.isEnabled = !busy && !selected.isEmpty
        confirmButton.title = busy ? "正在导入" : "确认导入（\(selected.count)）"
        selectionButton.isEnabled = !busy && imported.count != document.rows.count
        cancelButton.isEnabled = !stopRequested || !busy
        cancelButton.title = busy ? "停止" : L10n.Common.cancel
        tableView.allowsSelection = !busy
        if !busy { statusLabel.text = "已选 \(selected.count)/\(document.rows.count)，已导入 \(imported.count)" }
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool { saveTask == nil }
}
