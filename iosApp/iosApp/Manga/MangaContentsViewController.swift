import UIKit
import shared

@MainActor
final class MangaContentsViewController: UITableViewController, UISearchResultsUpdating {
    private let chapters: [BookChapter]
    private let currentIndex: Int
    private let onSelect: (Int) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private var titles: [Int: String] = [:]
    private var filtered: [BookChapter]
    var loadTask: Task<Void, Never>?

    init(chapters: [BookChapter], currentIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.chapters = chapters
        self.currentIndex = currentIndex
        self.onSelect = onSelect
        filtered = chapters
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "目录"
        overrideUserInterfaceStyle = .dark
        tableView.backgroundColor = .black
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "chapter")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "搜索章节"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !search.isActive, let row = filtered.firstIndex(where: { Int($0.index) == currentIndex }) {
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
        }
    }

    func updateTitles(_ items: [ReaderChapterListItem]) {
        titles = Dictionary(items.map { (Int($0.chapter.index), $0.displayTitle) }, uniquingKeysWith: { _, latest in latest })
        if isViewLoaded { updateSearchResults(for: search) }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        filtered =
            query.isEmpty
            ? chapters
            : chapters.filter {
                (titles[Int($0.index)] ?? $0.title).localizedCaseInsensitiveContains(query)
            }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter", for: indexPath)
        let chapter = filtered[indexPath.row]
        let current = Int(chapter.index) == currentIndex
        var content = cell.defaultContentConfiguration()
        content.text = titles[Int(chapter.index)] ?? chapter.title
        content.textProperties.numberOfLines = 0
        content.textProperties.color = current ? .systemGreen : .white
        content.textProperties.font = .systemFont(ofSize: 15, weight: chapter.isVolume ? .semibold : .regular)
        cell.contentConfiguration = content
        cell.backgroundColor = .black
        cell.accessoryType = current ? .checkmark : .none
        cell.tintColor = .systemGreen
        cell.accessibilityTraits = current ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let index = Int(filtered[indexPath.row].index)
        search.isActive = false
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [onSelect] in onSelect(index) }
    }

    @objc private func close() { dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }
}
