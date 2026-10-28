import shared
import SnapKit
import Then
import UIKit

final class SearchViewController: UIViewController, UISearchBarDelegate {
    let screen = SearchScreenAdapter()
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let inputHelpView = UIView()
    private let historyHeaderView = UIView()
    private let historyTitleLabel = UILabel()
    private let clearHistoryButton = UIButton(type: .system)
    let historyTableView = UITableView(frame: .zero, style: .plain)
    private let historyEmptyLabel = UILabel()
    private let debugLabel = UILabel()
    private let scopeSummaryLabel = UILabel()
    private let bookshelfBannerView = UIView()
    private let bookshelfBannerLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    let tableView = UITableView(frame: .zero, style: .plain)
    private let stopButton = UIButton(type: .system)
    private let scopeButton = UIButton(type: .system)
    let moreButton = UIButton(type: .system)
    private let initialKeyword: String?
    private let preferredSourceURL: String?
    let searchBar = UISearchBar(frame: .zero).then {
        $0.placeholder = L10n.Search.searchPlaceholder
        $0.autocapitalizationType = .none
        $0.returnKeyType = .search
        $0.searchBarStyle = .minimal
    }

    var sources: [BookSource] = []
    var groups: [String] = []
    var selectedScope = SearchScopeSelection.allEnabled
    var results: [SearchBook] = []
    var historyItems: [SearchKeyword] = []
    var currentSession: SearchSessionState?
    private var lastResultsSignature: String?
    private var isNavigatingToDetail = false
    private var pendingInitialSearch = false
    var isLoadingNextPage = false
    var bookshelfKeys: Set<String> = []

    init(initialKeyword: String? = nil, preferredSourceURL: String? = nil) {
        self.initialKeyword = initialKeyword?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.preferredSourceURL = preferredSourceURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        pendingInitialSearch = self.initialKeyword != nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = L10n.Search.title
        configureScaffold()
        configureTableView()
        configureSearchField()
        configureScopeSummary()
        configureStopButton()
        configureInputHelp()
        configureDebugMarkerIfNeeded()
        stateView.setTestingIdentifier(UIIdentifiers.Search.state)
        updateDebugMarker("viewDidLoad")
        bootstrapDependencies()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if navigationController?.topViewController === self {
            isNavigatingToDetail = false
            tableView.isUserInteractionEnabled = true
            updateDebugMarker("visible")
            attemptInitialSearchIfNeeded()
        }
    }

    deinit {
        screen.cancelSearch()
        screen.unbind()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        setInputHelpVisible(false)
        performSearch()
    }

    func searchBarTextDidBeginEditing(_: UISearchBar) {
        refreshInputHelp()
        setInputHelpVisible(true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange _: String) {
        refreshInputHelp()
        setInputHelpVisible(searchBar.isFirstResponder)
    }

    private func configureScaffold() {
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        scaffoldView.titleBarView.setTitle(L10n.Search.title)
        let backButton = makeLegacyBarButton(
            imageSystemName: "chevron.left",
            target: self,
            action: #selector(handleBackTapped)
        )
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        var scopeConfiguration = UIButton.Configuration.plain()
        scopeConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        scopeConfiguration.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        scopeButton.configuration = scopeConfiguration
        scopeButton.showsMenuAsPrimaryAction = false
        scopeButton.accessibilityIdentifier = UIIdentifiers.Search.sourceMenu
        scopeButton.addTarget(self, action: #selector(handleScopeButtonTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleScopeLongPress(_:)))
        scopeButton.addGestureRecognizer(longPress)
        var moreConfiguration = UIButton.Configuration.plain()
        moreConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        moreConfiguration.image = UIImage(systemName: "ellipsis.circle")
        moreButton.configuration = moreConfiguration
        moreButton.showsMenuAsPrimaryAction = false
        moreButton.accessibilityIdentifier = UIIdentifiers.Search.moreMenu
        moreButton.addTarget(self, action: #selector(handleMoreButtonTapped), for: .touchUpInside)
        scaffoldView.titleBarView.setLeftViews([backButton])
        scaffoldView.titleBarView.setRightViews([scopeButton, moreButton])
        scaffoldView.titleBarView.setCenterView(searchBar)

        scaffoldView.contentView.addSubview(progressView)
        scaffoldView.contentView.addSubview(tableView)
        scaffoldView.contentView.addSubview(inputHelpView)
        scaffoldView.contentView.addSubview(stateView)
        scaffoldView.contentView.addSubview(stopButton)

        progressView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(2)
        }

        tableView.snp.makeConstraints { make in
            make.top.equalTo(progressView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        inputHelpView.snp.makeConstraints { make in
            make.top.equalTo(progressView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        stopButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(AppUI.Spacing.large)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(AppUI.Spacing.large)
            make.width.height.equalTo(44)
        }
    }

    private func configureTableView() {
        tableView.register(BookCoverTableViewCell.self, forCellReuseIdentifier: BookCoverTableViewCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppUI.Layout.searchRowHeight
        tableView.setPlaceholder(nil)
        tableView.accessibilityIdentifier = UIIdentifiers.Search.table
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func configureInputHelp() {
        inputHelpView.backgroundColor = .systemBackground
        inputHelpView.accessibilityIdentifier = UIIdentifiers.Search.inputHelp
        inputHelpView.isHidden = true

        historyTitleLabel.font = .preferredFont(forTextStyle: .headline)
        historyTitleLabel.text = L10n.Search.historyTitle
        clearHistoryButton.setTitle(L10n.Search.clearHistory, for: .normal)
        clearHistoryButton.accessibilityIdentifier = UIIdentifiers.Search.clearHistoryButton
        clearHistoryButton.addTarget(self, action: #selector(handleClearHistoryTapped), for: .touchUpInside)

        historyTableView.register(UITableViewCell.self, forCellReuseIdentifier: "search-history")
        historyTableView.dataSource = self
        historyTableView.delegate = self
        historyTableView.rowHeight = 44
        historyTableView.tableFooterView = UIView()
        historyTableView.accessibilityIdentifier = UIIdentifiers.Search.historyTable

        historyEmptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        historyEmptyLabel.textColor = .secondaryLabel
        historyEmptyLabel.textAlignment = .center
        historyEmptyLabel.numberOfLines = 0
        historyEmptyLabel.text = L10n.Search.historyEmpty
        historyEmptyLabel.accessibilityIdentifier = UIIdentifiers.Search.historyEmptyLabel

        inputHelpView.addSubview(historyHeaderView)
        inputHelpView.addSubview(historyTableView)
        inputHelpView.addSubview(historyEmptyLabel)
        historyHeaderView.addSubview(historyTitleLabel)
        historyHeaderView.addSubview(clearHistoryButton)

        historyHeaderView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(44)
        }
        historyTitleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(AppUI.Spacing.medium)
            make.centerY.equalToSuperview()
        }
        clearHistoryButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(AppUI.Spacing.medium)
            make.centerY.equalToSuperview()
        }
        historyTableView.snp.makeConstraints { make in
            make.top.equalTo(historyHeaderView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        historyEmptyLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(AppUI.Spacing.xLarge)
        }
        updateHistoryVisibility()
    }

    private func configureSearchField() {
        searchBar.delegate = self
        searchBar.accessibilityIdentifier = UIIdentifiers.Search.searchField
        searchBar.searchTextField.accessibilityIdentifier = UIIdentifiers.Search.searchField
        searchBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let initialKeyword {
            searchBar.text = initialKeyword
        }
    }

    private func configureStopButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "stop.fill")
        configuration.cornerStyle = .capsule
        stopButton.configuration = configuration
        stopButton.accessibilityIdentifier = UIIdentifiers.Search.stopButton
        stopButton.isHidden = true
        stopButton.addTarget(self, action: #selector(handleStopTapped), for: .touchUpInside)
        updateMoreMenu()
    }

    private func bootstrapDependencies() {
        screen.unbind()
        stateView.showLoading(message: L10n.Search.loadingBootstrap)
        screen.onSourcesChange = { [weak self] sources in
            guard let self else { return }
            self.sources = sources
            self.reconcileScopeSelection()
            self.updateSourceMenu()
            self.updateScopeSummary(session: nil)
            self.renderSearchState()
            self.attemptInitialSearchIfNeeded()
        }
        screen.onGroupsChange = { [weak self] groups in
            guard let self else { return }
            self.groups = groups
            self.reconcileScopeSelection()
            self.updateSourceMenu()
            self.updateScopeSummary(session: nil)
        }
        screen.onSearchSessionChange = { [weak self] session in
            self?.applySearchSession(session)
        }
        screen.onPrecisionSearchChange = { [weak self] _ in
            self?.updateMoreMenu()
        }
        screen.onBookshelfKeysChange = { [weak self] keys in
            self?.bookshelfKeys = keys
            self?.tableView.reloadData()
        }

        switch screen.bootstrap() {
        case .success:
            break
        case let .failure(error):
            stateView.showMessage(
                title: L10n.Search.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    private func reconcileScopeSelection() {
        if let preferredSourceURL,
           sources.contains(where: { $0.bookSourceUrl == preferredSourceURL })
        {
            selectedScope = .source(
                url: preferredSourceURL,
                name: sources.first(where: { $0.bookSourceUrl == preferredSourceURL })?.bookSourceName ?? preferredSourceURL
            )
            return
        }
        if case let .source(url, _) = selectedScope,
           sources.contains(where: { $0.bookSourceUrl == url }) == false
        {
            selectedScope = .allEnabled
        }
        if case let .group(group) = selectedScope,
           groups.contains(group) == false
        {
            selectedScope = .allEnabled
        }
        if case let .groups(selectedGroupList) = selectedScope {
            let validGroups = selectedGroupList.filter { groups.contains($0) }
            if validGroups.isEmpty {
                selectedScope = .allEnabled
            } else if validGroups.count == 1, let single = validGroups.first {
                selectedScope = .group(single)
            } else if validGroups.count != selectedGroupList.count {
                selectedScope = .groups(validGroups)
            }
        }
        if sources.isEmpty {
            selectedScope = .allEnabled
        }
    }

    func updateSourceMenu() {
        let allEnabledAction = UIAction(
            title: L10n.Search.scopeAllEnabled,
            state: selectedScope == .allEnabled ? .on : .off
        ) { [weak self] _ in
            self?.applyNewScope(.allEnabled)
        }
        let groupMenu = UIMenu(
            title: L10n.Search.scopeGroupPrefix,
            options: .displayInline,
            children: groups.map { group in
                let isSelected: Bool = {
                    switch selectedScope {
                    case let .group(g): return g == group
                    case let .groups(gs): return gs.contains(group)
                    default: return false
                    }
                }()
                return UIAction(
                    title: group,
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.applyNewScope(.group(group))
                }
            }
        )
        let sourceMenu = UIMenu(
            title: L10n.Search.sourceFallback,
            options: .displayInline,
            children: sources.map { source in
                let selection = SearchScopeSelection.source(url: source.bookSourceUrl, name: source.bookSourceName)
                return UIAction(
                    title: source.bookSourceName,
                    subtitle: source.bookSourceGroup,
                    state: selectedScope == selection ? .on : .off
                ) { [weak self] _ in
                    self?.applyNewScope(selection)
                }
            }
        )
        let children: [UIMenuElement] = [allEnabledAction] +
            (groupMenu.children.isEmpty ? [] : [groupMenu]) +
            (sourceMenu.children.isEmpty ? [] : [sourceMenu])
        scopeButton.menu = UIMenu(children: children)
        updateScopeSummary(session: nil)
    }

    func performSearch() {
        guard let keyword = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), keyword.isEmpty == false else {
            if sources.isEmpty {
                stateView.showMessage(
                    title: L10n.Search.noSourcesTitle,
                    message: L10n.Search.noSourcesMessage,
                    actionTitle: L10n.Search.goImport
                ) { [weak self] in
                    self?.openSourceManagement()
                }
            } else {
                stateView.hide()
                tableView.setPlaceholder(L10n.Search.emptySelection)
            }
            return
        }

        setInputHelpVisible(false)
        updateBookshelfBanner(keyword: keyword)
        updateDebugMarker("searching:\(keyword):\(selectedScope.displayName)")
        stateView.showLoading(message: L10n.Search.loadingSearch)
        tableView.setPlaceholder(nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await screen.startSearch(scope: selectedScope, keyword: keyword)
            } catch {
                await MainActor.run {
                    self.stateView.showMessage(
                        title: L10n.Search.failed,
                        message: error.userFacingMessage,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.performSearch()
                    }
                }
            }
        }
    }

    private func attemptInitialSearchIfNeeded() {
        guard pendingInitialSearch,
              navigationController?.topViewController === self,
              searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return
        }
        pendingInitialSearch = false
        performSearch()
    }

    private func applySearchSession(_ session: SearchSessionState) {
        currentSession = session
        isLoadingNextPage = false
        updateMoreMenu()
        if isNavigatingToDetail {
            return
        }
        results = session.results
        if session.isRunning {
            setInputHelpVisible(false)
        }
        updateScopeSummary(session: session)
        updateDebugMarker(searchDebugState(for: session))
        progressView.isHidden = session.isRunning == false
        stopButton.isHidden = session.isRunning == false
        if session.sourceTotalCount > 0 {
            progressView.progress = min(
                max(Float(session.completedSourceCount) / Float(session.sourceTotalCount), 0),
                1
            )
        } else {
            progressView.progress = 0
        }
        if sources.isEmpty {
            stateView.showMessage(
                title: L10n.Search.noSourcesTitle,
                message: L10n.Search.noSourcesMessage,
                actionTitle: L10n.Search.goImport
            ) { [weak self] in
                self?.openSourceManagement()
            }
            tableView.setPlaceholder(L10n.Search.noSourcesPlaceholder)
            reloadResultsIfNeeded(force: true)
            return
        }

        if session.isRunning {
            stateView.showLoading(message: searchProgressMessage(for: session))
        } else if let error = session.error, session.results.isEmpty {
            stateView.showMessage(
                title: L10n.Search.failed,
                message: error,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.performSearch()
            }
        } else if session.results.isEmpty, session.keyword.isEmpty == false {
            stateView.showMessage(
                title: L10n.Search.failed,
                message: L10n.Search.noResults,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.performSearch()
            }
            showEmptyResultSuggestion()
        } else {
            stateView.hide()
        }

        if session.results.isEmpty {
            let hasKeyword = session.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            tableView.setPlaceholder(hasKeyword ? L10n.Search.noResults : L10n.Search.waiting)
        } else {
            tableView.setPlaceholder(nil)
        }
        reloadResultsIfNeeded()
    }

    private func renderSearchState() {
        progressView.isHidden = true
        stopButton.isHidden = true
        progressView.progress = 0
        if sources.isEmpty {
            stateView.showMessage(
                title: L10n.Search.noSourcesTitle,
                message: L10n.Search.noSourcesMessage,
                actionTitle: L10n.Search.goImport
            ) { [weak self] in
                self?.openSourceManagement()
            }
            tableView.setPlaceholder(L10n.Search.noSourcesPlaceholder)
        } else if results.isEmpty {
            stateView.hide()
            tableView.setPlaceholder(L10n.Search.waiting)
        } else {
            stateView.hide()
            tableView.setPlaceholder(nil)
        }
        updateScopeSummary(session: nil)
    }

    func refreshInputHelp() {
        let keyword = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { [weak self] in
            guard let self else { return }
            let history = (try? await screen.loadSearchHistory(keyword: keyword)) ?? []
            await MainActor.run {
                self.historyItems = history
                self.historyTableView.reloadData()
                self.updateHistoryVisibility()
            }
        }
    }

    private func updateHistoryVisibility() {
        let hasHistory = historyItems.isEmpty == false
        historyTableView.isHidden = !hasHistory
        historyEmptyLabel.isHidden = hasHistory
        clearHistoryButton.isHidden = !hasHistory
    }

    func setInputHelpVisible(_ visible: Bool) {
        inputHelpView.isHidden = !visible
        tableView.isHidden = visible
    }

    private func reloadResultsIfNeeded(force: Bool = false) {
        if isNavigatingToDetail {
            return
        }
        let signature = results.map {
            "\($0.bookUrl)#\($0.name)#\($0.author)#\($0.latestChapterTitle ?? "")"
        }.joined(separator: "|")
        if force || signature != lastResultsSignature {
            let wasNearTop = tableView.contentOffset.y < 50
            lastResultsSignature = signature
            tableView.accessibilityValue = "\(results.count)"
            tableView.reloadData()
            if wasNearTop, !results.isEmpty {
                tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
            }
        }
    }

    var shouldShowLoadMoreCell: Bool {
        currentSession?.hasMore == true && results.isEmpty == false && currentSession?.isRunning == false
    }

    func loadNextPage() {
        guard isLoadingNextPage == false, currentSession?.hasMore == true else { return }
        isLoadingNextPage = true
        tableView.reloadData()
        Task { [weak self] in
            do {
                try await self?.screen.loadNextPage()
            } catch {
                await MainActor.run {
                    self?.isLoadingNextPage = false
                    self?.tableView.reloadData()
                    self?.presentError(error)
                }
            }
        }
    }

    func applyNewScope(_ newScope: SearchScopeSelection) {
        let changed = selectedScope != newScope
        selectedScope = newScope
        updateSourceMenu()
        updateScopeSummary(session: nil)
        if changed, inputHelpView.isHidden,
           let keyword = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keyword.isEmpty
        {
            performSearch()
        }
    }

    func toggleSearchPauseState() {
        Task { [weak self] in
            do {
                if self?.currentSession?.isPaused == true {
                    try await self?.screen.resumeSearch()
                } else {
                    try await self?.screen.pauseSearch()
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    func togglePrecisionSearch() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await screen.togglePrecisionSearch()
                await MainActor.run {
                    self.updateMoreMenu()
                    if let keyword = self.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !keyword.isEmpty, self.currentSession != nil
                    {
                        self.performSearch()
                    }
                }
            } catch {
                await MainActor.run { self.presentError(error) }
            }
        }
    }

    func openSourceManagement() {
        let controller = AndroidReplicaSourceManagementViewController().configuredForDrillDownPresentation()
        navigationController?.pushViewController(controller, animated: true)
    }

    func openDetail(for book: SearchBook) {
        guard isNavigatingToDetail == false else {
            return
        }
        isNavigatingToDetail = true
        tableView.isUserInteractionEnabled = false
        searchBar.resignFirstResponder()
        updateDebugMarker("pushing:\(book.bookUrl)")
        let controller = AndroidReplicaBookDetailViewController(searchBook: book)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func configureScopeSummary() {
        scopeSummaryLabel.font = .preferredFont(forTextStyle: .footnote)
        scopeSummaryLabel.textColor = .secondaryLabel
        scopeSummaryLabel.numberOfLines = 2
        scopeSummaryLabel.accessibilityIdentifier = UIIdentifiers.Search.scopeSummary
        scopeSummaryLabel.textAlignment = .left

        bookshelfBannerView.backgroundColor = .systemYellow.withAlphaComponent(0.15)
        bookshelfBannerView.isHidden = true
        bookshelfBannerView.accessibilityIdentifier = UIIdentifiers.Search.bookshelfBanner
        bookshelfBannerLabel.font = .preferredFont(forTextStyle: .footnote)
        bookshelfBannerLabel.textColor = .label
        bookshelfBannerLabel.textAlignment = .center
        bookshelfBannerLabel.text = L10n.Search.bookshelfMatchBanner
        bookshelfBannerView.addSubview(bookshelfBannerLabel)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 46))
        scopeSummaryLabel.frame = CGRect(
            x: AppUI.Spacing.medium,
            y: AppUI.Spacing.small,
            width: max(view.bounds.width - (AppUI.Spacing.medium * 2), 1),
            height: 34
        )
        bookshelfBannerView.frame = CGRect(x: 0, y: 46, width: view.bounds.width, height: 30)
        bookshelfBannerLabel.frame = bookshelfBannerView.bounds
        container.addSubview(scopeSummaryLabel)
        container.addSubview(bookshelfBannerView)
        tableView.tableHeaderView = container
        updateScopeSummary(session: nil)
    }

    private func updateBookshelfBanner(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setBookshelfBannerVisible(false)
            return
        }
        let matched = bookshelfKeys.contains(where: { key in
            key.localizedCaseInsensitiveContains(trimmed)
        })
        setBookshelfBannerVisible(matched)
    }

    private func setBookshelfBannerVisible(_ visible: Bool) {
        bookshelfBannerView.isHidden = !visible
        guard let header = tableView.tableHeaderView else { return }
        let newHeight: CGFloat = visible ? 76 : 46
        if header.frame.height != newHeight {
            header.frame.size.height = newHeight
            tableView.tableHeaderView = header
        }
    }

    func updateScopeSummary(session: SearchSessionState?) {
        let scopeText = selectedScope.summaryText
        guard let session else {
            scopeSummaryLabel.text = scopeText
            scopeSummaryLabel.accessibilityValue = scopeText
            return
        }
        if session.sourceTotalCount > 0 {
            let progress = String(
                format: L10n.Search.progressSummary,
                Int(session.completedSourceCount),
                Int(session.sourceTotalCount),
                Int(session.failedSourceCount)
            )
            let combined = [scopeText, progress].joined(separator: "\n")
            scopeSummaryLabel.text = combined
            scopeSummaryLabel.accessibilityValue = combined
            return
        }
        scopeSummaryLabel.text = scopeText
        scopeSummaryLabel.accessibilityValue = scopeText
    }

    private func searchProgressMessage(for session: SearchSessionState) -> String {
        guard session.sourceTotalCount > 0 else {
            return L10n.Search.loadingSearch
        }
        return String(
            format: L10n.Search.progressSummary,
            Int(session.completedSourceCount),
            Int(session.sourceTotalCount),
            Int(session.failedSourceCount)
        )
    }

    private func configureDebugMarkerIfNeeded() {}

    private func updateDebugMarker(_: String) {}

    private func searchDebugState(for session: SearchSessionState) -> String {
        if session.isRunning {
            return "running:\(session.keyword):\(session.completedSourceCount)/\(session.sourceTotalCount):\(session.results.count)"
        }
        if let error = session.error, session.results.isEmpty {
            return "error:\(error)"
        }
        if session.results.isEmpty {
            return "idle:\(session.keyword)"
        }
        return "results:\(session.results.count):\(session.results.first?.bookUrl ?? "")"
    }

    @objc private func handleBackTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func handleStopTapped() {
        screen.cancelSearch()
    }
}
