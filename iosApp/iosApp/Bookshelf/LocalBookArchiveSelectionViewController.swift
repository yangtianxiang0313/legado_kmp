import shared
import UIKit

@MainActor
final class LocalBookArchiveSelectionViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    var onSelection: (([ArchiveBookEntry]?) -> Void)?
    private let entries: [ArchiveBookEntry]
    private let archiveFormatName: String
    private var selectedIndices = Set<Int>()
    private var hasCompleted = false
    private weak var presentationHost: UIViewController?

    init(fileName: String, entries: [ArchiveBookEntry]) {
        self.entries = entries
        archiveFormatName = LocalBookArchiveType(fileName: fileName)?.displayName ?? "压缩包"
        super.init(style: .insetGrouped)
        title = "选择书籍"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelSelection)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "确认", style: .done, target: self, action: #selector(confirmSelection)
        )
        navigationItem.rightBarButtonItem?.isEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let host: UIViewController = navigationController ?? self
        if host.presentingViewController != nil {
            presentationHost = host
            host.presentationController?.delegate = self
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let presentationHost,
            presentationHost.isBeingDismissed || presentationHost.presentingViewController == nil
        {
            complete(nil)
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "\(archiveFormatName) 中的书籍" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 && entries.isEmpty ? "压缩包中没有可导入的书籍" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = indexPath.section == 0 ? "archive-selection" : "archive-entry"
        let cell =
            tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = AndroidReplicaTheme.primaryText
        content.textProperties.numberOfLines = 0
        content.textProperties.lineBreakMode = .byCharWrapping
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = AndroidReplicaTheme.secondaryText
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.lineBreakMode = .byCharWrapping
        cell.accessoryType = .none
        if indexPath.section == 0 {
            let allSelected = !entries.isEmpty && selectedIndices.count == entries.count
            content.text = allSelected ? "取消选择" : "全选"
            content.secondaryText = "已选 \(selectedIndices.count) 项，共 \(entries.count) 项"
            content.image = UIImage(systemName: allSelected ? "minus.square" : "checkmark.square")
            cell.contentConfiguration = content
            cell.selectionStyle = entries.isEmpty ? .none : .default
            cell.accessibilityTraits = entries.isEmpty ? [.notEnabled] : [.button]
            return cell
        }
        let entry = entries[indexPath.row]
        let isSelected = selectedIndices.contains(indexPath.row)
        content.text = entry.path
        let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        content.secondaryText = "\(entry.format.uppercased()) / \(size)"
        content.image = UIImage(systemName: isSelected ? "checkmark.square.fill" : "square")
        cell.contentConfiguration = content
        cell.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        cell.accessibilityValue = isSelected ? "已选择" : "未选择"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !hasCompleted else { return }
        if indexPath.section == 0 {
            selectedIndices = selectedIndices.count == entries.count ? [] : Set(entries.indices)
            tableView.reloadData()
        } else {
            if selectedIndices.contains(indexPath.row) {
                selectedIndices.remove(indexPath.row)
            } else {
                selectedIndices.insert(indexPath.row)
            }
            tableView.reloadRows(at: [IndexPath(row: 0, section: 0), indexPath], with: .none)
        }
        navigationItem.rightBarButtonItem?.isEnabled = !selectedIndices.isEmpty
    }

    @objc func cancelSelection() { complete(nil) }

    @objc private func confirmSelection() {
        guard !selectedIndices.isEmpty else { return }
        let selected = entries.enumerated().compactMap { index, entry in
            selectedIndices.contains(index) ? entry : nil
        }
        complete(selected)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { complete(nil) }

    private func complete(_ entries: [ArchiveBookEntry]?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.isUserInteractionEnabled = false
        let callback = onSelection
        onSelection = nil
        callback?(entries)
    }
}
