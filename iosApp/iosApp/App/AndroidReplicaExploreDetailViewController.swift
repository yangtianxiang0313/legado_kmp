import UIKit
import shared

final class AndroidReplicaExploreDetailViewController: UIViewController, UITableViewDelegate {
    private enum RetryAction { case bootstrap, kinds, firstPage, more }

    private let source: BookSourcePart
    private let adapter = AndroidReplicaExploreDetailAdapter()
    private let toolbar = ExploreResultsToolbarView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var selectedKind: ExploreKind?
    private var books: [SearchBook] = []
    private var bookshelfKeys: Set<String> = []
    private var footerState: ExploreResultsFooterCell.State = .loading
    private var retryAction: RetryAction?
    private var currentPage: Int32 = 0
    private var hasMore = false
    private var isLoading = false
    private var isRuntimeReady = false
    private var hasLeftPage = false
    private var hasAppeared = false
    private var paginationCheckScheduled = false
    private var automaticallyRequestedPage: Int32?
    private var automaticContentHeight: CGFloat = 0
    private let listGeneration = UUID()
    private lazy var resultList: ExploreResultsListCoordinator = {
        let list = ExploreResultsListCoordinator(tableView: tableView)
        list.canActivate = { [weak self] in self?.canInteract == true }
        list.onBookSelected = { [weak self] in self?.openBook($0) }
        list.onFooterActivated = { [weak self] in self?.activateFooter(expected: $0) }
        list.onContentSettled = { [weak self] in self?.schedulePaginationCheck() }
        return list
    }()
    private var requestGeneration = UUID()
    private var footerPresentationID = UUID()
    private var requestTask: Task<Void, Never>?
    private weak var pageNavigationController: UINavigationController?

    init(source: BookSourcePart, initialKind: ExploreKind? = nil) {
        self.source = source
        selectedKind = initialKind.flatMap { kind in
            !kind.title.hasPrefix("ERROR:") && kind.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? kind : nil
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        requestTask?.cancel()
        adapter.unbind()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneStateChanged(_:)), name: name, object: nil)
        }
        bootstrap()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        pageNavigationController = navigationController
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        updatePresentation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hasAppeared = false
        footerPresentationID = UUID()
        resultList.setPresentationActive(false)
        toolbar.setInteractionEnabled(false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        toolbar.updateLayout(availableSize: view.bounds.size)
        schedulePaginationCheck()
    }

    private var canInteract: Bool {
        hasAppeared && !hasLeftPage && navigationController?.topViewController === self
            && presentedViewController == nil && !isBeingDismissed
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func updatePresentation() {
        resultList.setPresentationActive(canInteract)
        toolbar.setInteractionEnabled(canInteract)
        schedulePaginationCheck()
    }

    @objc private func sceneStateChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        let active = notification.name == UIScene.didActivateNotification && canInteract
        if notification.name != UIScene.didActivateNotification { footerPresentationID = UUID() }
        resultList.setPresentationActive(active)
        toolbar.setInteractionEnabled(active)
        if active { schedulePaginationCheck() }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if let navigationController {
            pageNavigationController = navigationController
        } else if parent == nil, pageNavigationController != nil {
            leavePage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if controller.isMovingFromParent || controller.isBeingDismissed {
                leavePage()
                return
            }
            ancestor = controller.parent
        }
        if pageNavigationController?.viewControllers.contains(where: { $0 === self }) == false { leavePage() }
    }

    private func leavePage() {
        guard !hasLeftPage else { return }
        hasLeftPage = true
        requestGeneration = UUID()
        requestTask?.cancel()
        requestTask = nil
        adapter.unbind()
        isLoading = false
        isRuntimeReady = false
        resultList.suspend()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbar.setTitle(selectedKind?.title ?? L10n.Tabs.discovery)
        toolbar.onBack = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.accessibilityIdentifier = UIIdentifiers.Discovery.exploreTable
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = .zero
        tableView.separatorColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 54 / 255, alpha: 1) : UIColor(white: 224 / 255, alpha: 143 / 255)
        }
        tableView.showsVerticalScrollIndicator = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 128
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.delegate = self
        _ = resultList
        for item in [toolbar, tableView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func bootstrap() {
        guard !hasLeftPage else { return }
        adapter.onBookshelfKeysChange = { [weak self] keys in
            guard let self, !self.hasLeftPage, self.bookshelfKeys != keys else { return }
            self.bookshelfKeys = keys
            self.resultList.setBookshelfKeys(keys)
        }
        switch adapter.bootstrap() {
        case .success:
            isRuntimeReady = true
            if selectedKind == nil { loadKinds() } else { requestBooks(page: 1) }
        case .failure(let error): setFailure(error.message, retry: .bootstrap)
        }
    }

    private func loadKinds() {
        guard !hasLeftPage, !isLoading else { return }
        beginRequest()
        let generation = requestGeneration
        let sourceURL = source.bookSourceUrl
        requestTask = Task { @MainActor [weak self, adapter] in
            do {
                let kinds = try await adapter.loadExploreKinds(sourceURL: sourceURL, forceRefresh: true)
                guard let self, self.isCurrent(generation), !Task.isCancelled else { return }
                self.requestTask = nil
                self.isLoading = false
                self.selectedKind = kinds.first { !$0.title.hasPrefix("ERROR:") && $0.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                self.toolbar.setTitle(self.selectedKind?.title ?? L10n.Tabs.discovery)
                if self.selectedKind != nil {
                    self.requestBooks(page: 1)
                } else if let error = kinds.first(where: { $0.title.hasPrefix("ERROR:") }) {
                    self.setFailure(error.url ?? error.title, retry: .kinds)
                } else {
                    self.footerState = .empty
                    self.renderBooks()
                }
            } catch {
                guard let self, self.isCurrent(generation), !Task.isCancelled else { return }
                self.requestTask = nil
                self.isLoading = false
                self.setFailure(error.userFacingMessage, retry: .kinds)
            }
        }
    }

    private func beginRequest() {
        requestGeneration = UUID()
        requestTask?.cancel()
        requestTask = nil
        isLoading = true
        retryAction = nil
        footerState = .loading
        renderBooks()
    }

    private func isCurrent(_ generation: UUID) -> Bool { !hasLeftPage && requestGeneration == generation }

    private func requestBooks(page: Int32) {
        guard !hasLeftPage, !isLoading, let url = selectedKind?.url else { return }
        beginRequest()
        let generation = requestGeneration
        let sourceURL = source.bookSourceUrl
        requestTask = Task { @MainActor [weak self, adapter] in
            do {
                let loaded = try await adapter.loadExploreBooks(sourceURL: sourceURL, exploreURL: url, page: page)
                guard let self, self.isCurrent(generation), !Task.isCancelled else { return }
                self.requestTask = nil
                var seen = page == 1 ? Set<String>() : Set(self.books.map(\.bookUrl))
                let fresh = loaded.filter { seen.insert($0.bookUrl).inserted }
                if page == 1 { self.books = fresh } else { self.books.append(contentsOf: fresh) }
                self.currentPage = page
                self.hasMore = !fresh.isEmpty && page < Int32.max
                self.isLoading = false
                self.footerState = self.books.isEmpty ? .empty : (self.hasMore ? .ready : .end)
                self.renderBooks()
            } catch {
                guard let self, self.isCurrent(generation), !Task.isCancelled else { return }
                self.requestTask = nil
                self.isLoading = false
                self.setFailure(error.userFacingMessage, retry: page == 1 ? .firstPage : .more)
            }
        }
    }

    private func setFailure(_ message: String, retry: RetryAction) {
        retryAction = retry
        footerState = .error(message)
        renderBooks()
    }

    private func retry() {
        guard !hasLeftPage, !isLoading else { return }
        switch retryAction {
        case .bootstrap: bootstrap()
        case .kinds: loadKinds()
        case .firstPage: requestBooks(page: 1)
        case .more: loadMore(force: true)
        case nil: break
        }
    }

    private func renderBooks() {
        tableView.accessibilityValue = String(books.count)
        resultList.render(books: books, footer: footerState, generation: listGeneration)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        resultList.select(at: indexPath)
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        resultList.noteUserInteraction()
        automaticContentHeight = 0
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resultList.finishScrolling() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { resultList.finishScrolling() }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) { resultList.finishScrolling() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        schedulePaginationCheck()
    }

    private func schedulePaginationCheck() {
        guard canInteract, !paginationCheckScheduled else { return }
        paginationCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.paginationCheckScheduled = false }
            self.checkForMoreBooks()
        }
    }

    private func checkForMoreBooks() {
        guard canInteract, !isLoading, retryAction == nil, hasMore, footerState == .ready,
            currentPage > 0, currentPage < Int32.max, resultList.isContentSettled,
            tableView.bounds.height > tableView.adjustedContentInset.top + tableView.adjustedContentInset.bottom
        else { return }
        tableView.layoutIfNeeded()
        guard resultList.isContentSettled else { return }
        let height = tableView.contentSize.height
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        let pixel = 1 / max(1, tableView.traitCollection.displayScale)
        let nextPage = currentPage + 1
        // Recheck only delivered geometry; a new page must grow the list before another automatic request.
        guard height > automaticContentHeight, visibleBottom >= height - pixel,
            automaticallyRequestedPage != nextPage
        else { return }
        automaticContentHeight = height
        automaticallyRequestedPage = nextPage
        loadMore()
    }

    private func loadMore(force: Bool = false) {
        guard !hasLeftPage, hasMore || force, currentPage > 0, currentPage < Int32.max, !isLoading else { return }
        requestBooks(page: currentPage + 1)
    }

    private func activateFooter(expected: ExploreResultsFooterCell.State) {
        guard canInteract, !isLoading, footerState == expected else { return }
        if case .error(let message) = footerState {
            // LoadMoreView skips its detail dialog when the diagnostic is blank.
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                retry()
                return
            }
            guard let window = viewIfLoaded?.window, let scene = window.windowScene,
                let navigation = navigationController
            else { return }
            let generation = requestGeneration
            let presentationID = UUID()
            footerPresentationID = presentationID
            let isCurrentFailure = { [weak self, weak window, weak scene, weak navigation] in
                guard let self, let window, let scene, let navigation,
                    self.footerPresentationID == presentationID, self.isCurrent(generation),
                    self.footerState == expected, !self.isLoading,
                    self.navigationController === navigation, navigation.topViewController === self,
                    self.viewIfLoaded?.window === window, window.isKeyWindow, !window.isHidden,
                    window.alpha > 0.01, window.windowScene === scene, scene.activationState == .foregroundActive,
                    UIApplication.shared.applicationState == .active
                else { return false }
                var owner: UIViewController? = self
                while let controller = owner {
                    guard !controller.isBeingPresented, !controller.isBeingDismissed,
                        !controller.isMovingFromParent, !controller.isMovingToParent
                    else { return false }
                    owner = controller.parent
                }
                return true
            }
            var shouldRetry = false
            let dialog = ReaderRestoreProgressDialogViewController(
                title: "错误", message: message, accessibilityIdentifierPrefix: "discovery.explore.error",
                actionLayout: .retry
            ) { shouldRetry = $0 }
            dialog.canConfirm = { [weak self, weak dialog] in
                guard let self, let dialog, isCurrentFailure() else { return false }
                if dialog.presentingViewController == nil {
                    return self.canInteract
                }
                return self.presentedViewController === dialog
                    && dialog.presentingViewController?.presentedViewController === dialog
                    && dialog.viewIfLoaded?.window === self.viewIfLoaded?.window
            }
            dialog.onClose = { [weak self] in
                guard let self else { return }
                self.updatePresentation()
                guard shouldRetry, self.canInteract, isCurrentFailure() else { return }
                self.retry()
            }
            resultList.setPresentationActive(false)
            toolbar.setInteractionEnabled(false)
            present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
        } else if currentPage == 0 {
            if !isRuntimeReady { bootstrap() } else if selectedKind == nil { loadKinds() } else { requestBooks(page: 1) }
        } else {
            loadMore(force: true)
        }
    }

    private func openBook(_ book: SearchBook) {
        guard canInteract, books.contains(where: { $0.bookUrl == book.bookUrl && $0.origin == book.origin }) else { return }
        resultList.setPresentationActive(false)
        navigationController?.pushViewController(AndroidReplicaBookDetailViewController(searchBook: book), animated: true)
    }
}
