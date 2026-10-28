import shared
import SnapKit
import UIKit

final class ExploreShowViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum ReuseIdentifier {
        static let loadMore = "explore-load-more"
    }

    private let source: BookSourcePart
    private let screen = DiscoveryScreenAdapter()
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private lazy var backButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "chevron.left",
        target: self,
        action: #selector(handleBack)
    )
    private lazy var kindButton = makeLegacyBarButton(
        title: L10n.Discovery.kindFallback,
        imageSystemName: "line.3.horizontal.decrease.circle",
        target: self,
        action: #selector(handleKindButton)
    )
    private lazy var refreshButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "arrow.clockwise",
        target: self,
        action: #selector(handleRefresh)
    )

    private var kinds: [ExploreKind] = []
    private var books: [SearchBook] = []
    private var selectedKindURL: String?
    private var selectedKindTitle: String?
    private var currentPage: Int32 = 1
    private var hasMore = false
    private var isLoadingMore = false
    private var bookshelfKeys: Set<String> = []

    init(source: BookSourcePart) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureChrome()
        configureTable()
        configureStateView()
        bootstrapRuntime()
    }

    private func configureChrome() {
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        scaffoldView.titleBarView.setTitle(source.bookSourceName)
        scaffoldView.titleBarView.setLeftViews([backButton])
        scaffoldView.titleBarView.setRightViews([refreshButton, kindButton])
        kindButton.accessibilityIdentifier = UIIdentifiers.Discovery.kindButton
        refreshButton.accessibilityIdentifier = UIIdentifiers.Discovery.refreshButton
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func configureTable() {
        tableView.register(BookCoverTableViewCell.self, forCellReuseIdentifier: BookCoverTableViewCell.reuseIdentifier)
        tableView.setPlaceholder(nil)
        tableView.accessibilityIdentifier = UIIdentifiers.Discovery.exploreTable
        tableView.dataSource = self
        tableView.delegate = self

        scaffoldView.contentView.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func configureStateView() {
        scaffoldView.contentView.addSubview(stateView)
        stateView.setTestingIdentifier(UIIdentifiers.Discovery.exploreState)
        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func bootstrapRuntime() {
        screen.onBookshelfKeysChange = { [weak self] keys in
            self?.bookshelfKeys = keys
            self?.tableView.reloadData()
        }
        switch screen.bootstrap() {
        case .success:
            loadKinds(forceRefresh: false)
        case let .failure(error):
            stateView.showMessage(
                title: L10n.Discovery.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.reloadRuntimeAndKinds()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    deinit {
        screen.unbind()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        books.count + (hasMore ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if hasMore, indexPath.row == books.count {
            let cell = UITableViewCell(style: .default, reuseIdentifier: ReuseIdentifier.loadMore)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = isLoadingMore ? L10n.Discovery.loadingMoreBooks : L10n.Common.loadMore
            configuration.textProperties.alignment = .center
            cell.contentConfiguration = configuration
            cell.accessibilityIdentifier = UIIdentifiers.Discovery.loadMoreCell
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: BookCoverTableViewCell.reuseIdentifier, for: indexPath) as! BookCoverTableViewCell
        let book = books[indexPath.row]
        let tertiaryParts: [String] = [book.latestChapterTitle, book.intro].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value.replacingOccurrences(of: "\n", with: " ")
        }
        let onShelf = BookshelfFacade.companion.isInBookshelf(
            keys: bookshelfKeys,
            name: book.name,
            author: book.author ?? "",
            bookUrl: book.bookUrl
        )
        cell.configure(
            title: book.name,
            subtitle: [book.author, book.kind].compactMap { value in
                guard let value, value.isEmpty == false else { return nil }
                return value
            }.joined(separator: " · "),
            tertiary: tertiaryParts.isEmpty ? L10n.Search.latestChapterFallback : tertiaryParts.joined(separator: " | "),
            coverURL: book.coverUrl,
            isInBookshelf: onShelf
        )
        cell.accessibilityIdentifier = UIIdentifiers.Discovery.resultCell
        cell.onActivate = { [weak self] in
            self?.openDetail(for: book)
        }
        return cell
    }

    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        if hasMore, indexPath.row == books.count {
            loadMoreBooks()
            return
        }
        guard indexPath.row < books.count else { return }
        openDetail(for: books[indexPath.row])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView, hasMore, !isLoadingMore else { return }
        let threshold: CGFloat = 100
        if scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - threshold {
            loadMoreBooks()
        }
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func handleKindButton() {
        guard kindButton.menu != nil else {
            showTransientMessage(L10n.Discovery.kindUnavailable)
            return
        }
    }

    @objc private func handleRefresh() {
        loadKinds(forceRefresh: true)
    }

    private func loadKinds(forceRefresh: Bool) {
        stateView.showLoading(message: L10n.Discovery.loadingKinds)
        Task { [weak self] in
            guard let self else { return }
            do {
                let kinds = try await screen.loadExploreKinds(sourceURL: source.bookSourceUrl, forceRefresh: forceRefresh)
                await MainActor.run {
                    self.applyKinds(kinds)
                }
            } catch {
                await MainActor.run {
                    let diagnostic = self.diagnosticMessage(for: error)
                    self.stateView.showMessage(
                        title: L10n.Discovery.loadKindsFailed,
                        message: diagnostic,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.loadKinds(forceRefresh: forceRefresh)
                    }
                }
            }
        }
    }

    private func applyKinds(_ kinds: [ExploreKind]) {
        let errorKinds = kinds.filter { $0.title.hasPrefix("ERROR:") }
        let validKinds = kinds.filter { !$0.title.hasPrefix("ERROR:") }
        self.kinds = validKinds
        if let errorKind = errorKinds.first {
            showErrorKindAlert(errorKind)
        }
        let resolvedKind = validKinds.first { $0.url == selectedKindURL } ?? validKinds.first
        selectedKindURL = resolvedKind?.url
        selectedKindTitle = resolvedKind?.title
        if let kindTitle = selectedKindTitle {
            scaffoldView.titleBarView.setTitle("\(source.bookSourceName) — \(kindTitle)")
        }
        currentPage = 1
        hasMore = false
        isLoadingMore = false
        updateKindMenu()

        guard let kindURL = selectedKindURL, kindURL.isEmpty == false else {
            books = []
            tableView.reloadData()
            tableView.setPlaceholder(L10n.Discovery.emptyKinds)
            stateView.hide()
            return
        }

        loadBooks(exploreURL: kindURL, page: 1, resetResults: true)
    }

    private func loadBooks(exploreURL: String, page: Int32 = 1, resetResults: Bool = false) {
        stateView.showLoading(message: L10n.Discovery.loadingBooks)
        Task { [weak self] in
            guard let self else { return }
            do {
                let books = try await self.screen.loadExploreBooks(sourceURL: self.source.bookSourceUrl, exploreURL: exploreURL, page: page)
                await MainActor.run {
                    self.currentPage = page
                    if resetResults || page == 1 {
                        self.books = books
                    } else {
                        let existingUrls = Set(self.books.map { $0.bookUrl })
                        let newBooks = books.filter { !existingUrls.contains($0.bookUrl) }
                        self.books.append(contentsOf: newBooks)
                    }
                    self.hasMore = books.isEmpty == false
                    self.isLoadingMore = false
                    self.renderBooks()
                }
            } catch {
                await MainActor.run {
                    let diagnostic = self.diagnosticMessage(for: error)
                    self.isLoadingMore = false
                    self.stateView.showMessage(
                        title: L10n.Discovery.loadBooksFailed,
                        message: diagnostic,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.loadBooks(exploreURL: exploreURL, page: page, resetResults: resetResults)
                    }
                }
            }
        }
    }

    private func updateKindMenu() {
        let selectedTitle = selectedKindTitle ?? L10n.Discovery.kindFallback
        var configuration = kindButton.configuration ?? .plain()
        configuration.title = selectedTitle
        kindButton.configuration = configuration

        let actions = kinds.map { kind in
            UIAction(
                title: kind.title,
                state: kind.url == selectedKindURL ? .on : .off
            ) { [weak self] _ in
                self?.selectKind(kind)
            }
        }
        kindButton.menu = actions.isEmpty ? nil : UIMenu(children: actions)
        kindButton.showsMenuAsPrimaryAction = actions.isEmpty == false
    }

    private func selectKind(_ kind: ExploreKind) {
        guard selectedKindURL != kind.url else { return }
        selectedKindURL = kind.url
        selectedKindTitle = kind.title
        scaffoldView.titleBarView.setTitle("\(source.bookSourceName) — \(kind.title)")
        updateKindMenu()
        books = []
        currentPage = 1
        hasMore = false
        isLoadingMore = false
        tableView.reloadData()
        guard let exploreURL = kind.url, exploreURL.isEmpty == false else {
            tableView.setPlaceholder(L10n.Discovery.emptyKinds)
            return
        }
        loadBooks(exploreURL: exploreURL, page: 1, resetResults: true)
    }

    private func renderBooks() {
        tableView.accessibilityValue = "\(books.count)"
        tableView.reloadData()
        if books.isEmpty, !hasMore {
            tableView.setPlaceholder(kinds.isEmpty ? L10n.Discovery.emptyKinds : L10n.Discovery.emptyBooks)
        } else {
            tableView.setPlaceholder(nil)
        }
        stateView.hide()
    }

    private func loadMoreBooks() {
        guard hasMore, isLoadingMore == false, let exploreURL = selectedKindURL, exploreURL.isEmpty == false else { return }
        isLoadingMore = true
        tableView.reloadData()
        loadBooks(exploreURL: exploreURL, page: currentPage + 1)
    }

    private func openDetail(for book: SearchBook) {
        let controller = AndroidReplicaBookDetailViewController(searchBook: book)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func showErrorKindAlert(_ kind: ExploreKind) {
        let message = String(kind.title.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = kind.url ?? ""
        let alert = UIAlertController(
            title: L10n.Discovery.kindErrorTitle,
            message: detail.isEmpty ? message : "\(message)\n\n\(detail)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
        present(alert, animated: true)
    }

    private func reloadRuntimeAndKinds() {
        switch screen.bootstrap() {
        case .success:
            loadKinds(forceRefresh: true)
        case let .failure(error):
            stateView.showMessage(
                title: L10n.Discovery.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.reloadRuntimeAndKinds()
            }
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        error.userFacingMessage
    }
}
