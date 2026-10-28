import PDFKit
import UIKit

@MainActor
final class PdfPageListViewController: UITableViewController {
    private struct Entry {
        let title: String
        let page: Int
        let depth: Int
    }

    private let document: PDFDocument
    private let selectedPage: Int
    private var entries: [Entry] = []
    var onSelection: ((Int) -> Void)?

    init(document: PDFDocument, selectedPage: Int) {
        self.document = document
        self.selectedPage = selectedPage
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "目录"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "page")
        tableView.accessibilityIdentifier = "pdf.pageList"
        if let root = document.outlineRoot { append(root, depth: -1) }
        if entries.isEmpty {
            entries = (0..<document.pageCount).map { Entry(title: "第 \($0 + 1) 页", page: $0, depth: 0) }
        }
        if let row = entries.lastIndex(where: { $0.page <= selectedPage }) {
            tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .middle)
        }
    }

    private func append(_ outline: PDFOutline, depth: Int) {
        guard depth < 32, entries.count < 10_000 else { return }
        if depth >= 0, let page = outline.destination?.page {
            let index = document.index(for: page)
            if index != NSNotFound {
                entries.append(Entry(title: outline.label ?? "第 \(index + 1) 页", page: index, depth: depth))
            }
        }
        for index in 0..<min(outline.numberOfChildren, 10_000 - entries.count) {
            if let child = outline.child(at: index) { append(child, depth: depth + 1) }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "page", for: indexPath)
        let entry = entries[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.title
        content.secondaryText = "\(entry.page + 1)"
        content.textProperties.color = AndroidReplicaTheme.primaryText
        cell.contentConfiguration = content
        cell.indentationLevel = min(entry.depth, 5)
        cell.backgroundColor = AndroidReplicaTheme.background
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let page = entries[indexPath.row].page
        let selection = onSelection
        dismiss(animated: true) { selection?(page) }
    }

    @objc private func close() { dismiss(animated: true) }
}
