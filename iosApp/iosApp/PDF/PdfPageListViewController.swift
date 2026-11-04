import PDFKit
import UIKit

@MainActor
final class PdfPageListViewController: UITableViewController {
    private struct Entry {
        let title: String
        let page: Int
        let depth: Int
    }

    private enum Mode: Int { case outline, pages }
    private let document: PDFDocument
    private let selectedPage: Int
    private var entries: [Entry] = []
    private var mode = Mode.pages
    private var isPresentationActive = false
    private var isClosing = false
    private var selectionRevision = UUID()
    private let modeControl = UISegmentedControl()
    var canSubmit: (() -> Bool)?
    var onSelection: ((Int) -> Void)?

    init(document: PDFDocument, selectedPage: Int) {
        self.document = document
        self.selectedPage = selectedPage
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.PDFNavigation.contents
        view.accessibilityViewIsModal = true
        let close = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        close.accessibilityIdentifier = "pdf.pageList.close"
        let current = UIBarButtonItem(
            image: UIImage(systemName: "location"), style: .plain, target: self, action: #selector(showCurrent))
        current.accessibilityLabel = L10n.PDFNavigation.currentPage
        current.accessibilityIdentifier = "pdf.pageList.current"
        current.isEnabled = (0..<document.pageCount).contains(selectedPage)
        navigationItem.rightBarButtonItems = [close, current]
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(PdfPageListCell.self, forCellReuseIdentifier: "page")
        tableView.accessibilityIdentifier = "pdf.pageList"
        if let root = document.outlineRoot { append(root, depth: -1) }
        if !entries.isEmpty {
            mode = .outline
            modeControl.insertSegment(withTitle: L10n.PDFNavigation.outline, at: 0, animated: false)
            modeControl.insertSegment(withTitle: L10n.PDFNavigation.pages, at: 1, animated: false)
            modeControl.selectedSegmentIndex = mode.rawValue
            modeControl.accessibilityIdentifier = "pdf.pageList.mode"
            modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
            navigationItem.titleView = modeControl
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(invalidatePendingSelection), name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDeactivated), name: UIScene.willDeactivateNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationActive = true
        selectCurrent(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationActive = false
    }

    private var canInteract: Bool {
        isPresentationActive && !isClosing && canPerformNavigationAction && (canSubmit?() ?? true)
            && view.window.map { AppLockManager.shared.isUnlocked(in: $0) } == true
    }

    private var currentRow: Int? {
        if mode == .outline { return entries.lastIndex { $0.page <= selectedPage } }
        return (0..<document.pageCount).contains(selectedPage) ? selectedPage : nil
    }

    private func entry(at row: Int) -> Entry? {
        if mode == .outline { return entries.indices.contains(row) ? entries[row] : nil }
        guard (0..<document.pageCount).contains(row) else { return nil }
        return Entry(title: L10n.PDFNavigation.page(row + 1), page: row, depth: 0)
    }

    private func selectCurrent(animated: Bool) {
        guard let row = currentRow, row < tableView.numberOfRows(inSection: 0) else { return }
        tableView.selectRow(at: IndexPath(row: row, section: 0), animated: animated, scrollPosition: .middle)
    }

    @objc private func modeChanged() {
        guard canInteract, let mode = Mode(rawValue: modeControl.selectedSegmentIndex),
            mode == .pages || !entries.isEmpty
        else { return }
        self.mode = mode
        tableView.reloadData()
        tableView.layoutIfNeeded()
        selectCurrent(animated: false)
    }

    @objc private func showCurrent() {
        guard canInteract else { return }
        if mode == .outline && !entries.contains(where: { $0.page == selectedPage }) {
            modeControl.selectedSegmentIndex = Mode.pages.rawValue
            modeChanged()
            return
        }
        selectCurrent(animated: true)
    }

    private func append(_ outline: PDFOutline, depth: Int) {
        guard depth < 32, entries.count < 10_000 else { return }
        if depth >= 0, let page = outline.destination?.page {
            let index = document.index(for: page)
            if index != NSNotFound && (0..<document.pageCount).contains(index) {
                entries.append(
                    Entry(title: outline.label ?? L10n.PDFNavigation.page(index + 1), page: index, depth: depth))
            }
        }
        for index in 0..<min(outline.numberOfChildren, 10_000 - entries.count) {
            if let child = outline.child(at: index) { append(child, depth: depth + 1) }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        mode == .outline ? entries.count : document.pageCount
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "page", for: indexPath)
        guard let entry = entry(at: indexPath.row) else { return cell }
        let isCurrent = indexPath.row == currentRow
        var content = cell.defaultContentConfiguration()
        content.text = entry.title
        content.secondaryText = mode == .outline ? L10n.PDFNavigation.page(entry.page + 1) : nil
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 2
        content.textProperties.color = isCurrent ? AndroidReplicaTheme.accent : AndroidReplicaTheme.primaryText
        content.secondaryTextProperties.color = AndroidReplicaTheme.secondaryText
        cell.contentConfiguration = content
        cell.indentationLevel = min(entry.depth, 5)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.accessoryType = isCurrent ? .checkmark : .none
        cell.tintColor = AndroidReplicaTheme.accent
        cell.accessibilityIdentifier = "pdf.pageList.\(mode == .outline ? "outline" : "page").\(indexPath.row)"
        cell.accessibilityValue = isCurrent ? L10n.PDFNavigation.currentPage : nil
        cell.accessibilityTraits = isCurrent ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        canInteract && entry(at: indexPath.row) != nil ? indexPath : nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard canInteract, let entry = entry(at: indexPath.row), let window = view.window else { return }
        let owner = navigationController ?? self
        guard let presenter = owner.presentingViewController, owner.transitionCoordinator == nil else { return }
        let revision = selectionRevision, callback = onSelection, submit = canSubmit
        weak var root = window.rootViewController
        isClosing = true
        owner.dismiss(animated: true) { [self, weak owner, weak presenter, weak window] in
            guard let window, self.selectionRevision == revision,
                owner?.presentingViewController == nil, presenter?.presentedViewController == nil,
                presenter?.viewIfLoaded?.window === window, window.rootViewController === root,
                window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active, AppLockManager.shared.isUnlocked(in: window),
                submit?() ?? true
            else { return }
            callback?(entry.page)
        }
    }

    @objc private func invalidatePendingSelection() { selectionRevision = UUID() }
    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === view.window?.windowScene else { return }
        invalidatePendingSelection()
    }
    @objc private func close() {
        guard canInteract else { return }
        isClosing = true
        invalidatePendingSelection()
        (navigationController ?? self).dismiss(animated: true)
    }
}

private final class PdfPageListCell: UITableViewCell {
    override func accessibilityActivate() -> Bool { ReaderTableAccessibility.activate(self) }
}
