import shared
import UIKit

final class AndroidReplicaRssFavoritesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let screen = RssScreenAdapter()
    private lazy var topBar = AndroidReplicaDetailBar(title: L10n.RSS.favoritesTitle, target: self, backAction: #selector(handleBack))
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let stateView = ContentStateView()
    private var favorites: [RssStar] = []
    private var openTask: Task<Void, Never>?

    deinit {
        openTask?.cancel()
        screen.unbind()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.separatorStyle = .none
        tableView.register(AndroidReplicaRssArticleCell.self, forCellReuseIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "rss.favorites.table"
        stateView.setTestingIdentifier("rss.favorites.state")
        stateView.backgroundColor = AndroidReplicaTheme.background
        for item in [topBar, tableView, stateView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.topAnchor.constraint(equalTo: tableView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
        ])
        bindScreen()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        openTask?.cancel()
        openTask = nil
        tableView.isUserInteractionEnabled = true
    }

    private func bindScreen() {
        stateView.showLoading(message: L10n.RSS.favoritesTitle)
        screen.onFavoritesChange = { [weak self] favorites in
            guard let self else { return }
            self.favorites = favorites
            self.tableView.reloadData()
            if favorites.isEmpty {
                self.stateView.showMessage(title: L10n.RSS.favoritesEmpty)
            } else {
                self.stateView.hide()
            }
        }
        if case let .failure(error) = screen.bootstrap() {
            stateView.showMessage(title: L10n.RSS.unavailable, message: error.message, actionTitle: L10n.Common.retry) { [weak self] in
                self?.bindScreen()
            }
        }
    }

    @objc private func handleBack() { navigationController?.popViewController(animated: true) }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { favorites.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier, for: indexPath) as! AndroidReplicaRssArticleCell
        let star = favorites[indexPath.row]
        cell.configure(title: star.title, detail: [star.sort, star.pubDate].compactMap { $0?.nilIfEmpty }.joined(separator: " · "))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard openTask == nil else { return }
        let article = favorites[indexPath.row].toRssArticle(read: false)
        tableView.isUserInteractionEnabled = false
        openTask = Task { [weak self] in
            guard let self else { return }
            defer {
                openTask = nil
                tableView.isUserInteractionEnabled = true
            }
            do {
                let sources = try await screen.loadAllSources()
                guard !Task.isCancelled, navigationController?.topViewController === self else { return }
                let source = sources.first { $0.sourceUrl == article.origin }
                navigationController?.pushViewController(AndroidReplicaRssArticleViewController(article: article, source: source, screen: screen, favorites: screen.currentFavorites), animated: true)
            } catch {
                guard !Task.isCancelled else { return }
                showTransientMessage(error.userFacingMessage)
            }
        }
    }
}
