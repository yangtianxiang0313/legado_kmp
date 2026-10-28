import UIKit
import shared

protocol SearchContentDelegate: AnyObject {
    func searchContentDidSelectResult(
        _ result: ContentSearchResult,
        at index: Int,
        allResults: [ContentSearchResult],
        options: ReaderContentSearchOptions,
        resultOptions: ReaderContentSearchOptions
    )
}

final class SearchContentViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource,
    UITableViewDelegate, UIAdaptivePresentationControllerDelegate
{
    weak var delegate: SearchContentDelegate?
    var onClose: (() -> Void)?
    var onOptionsChanged: ((ReaderContentSearchOptions) -> Void)?
    // Ownership is independent of scene activation and temporary presentation covers.
    var canOpenResult: (() -> Bool)?
    var canInteract: (() -> Bool)? {
        didSet { refreshInteractionAvailability() }
    }

    private enum Completion {
        case finished
        case stopped
        case failed(String)
    }

    private struct CellSnapshot {
        let generation: Int
        let row: Int
        let result: ContentSearchResult
    }

    private let page = ReaderContentSearchPageView()
    private var searchField: UITextField { page.toolbar.searchField }
    private var tableView: UITableView { page.tableView }
    private let screen: ReaderScreenAdapterSearchable
    private let initialQuery: String?
    private let cachedResults: [ContentSearchResult]
    private let focusedResultIndex: Int?
    private let currentChapterIndex: Int
    private var options: ReaderContentSearchOptions
    private var resultOptions: ReaderContentSearchOptions
    private var results: [ContentSearchResult] = []
    private var message: String?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var resultsGeneration = 0
    private var submittedQuery = ""
    private var submittedOptions = ReaderContentSearchOptions()
    private var isSearching = false
    private var acceptsResults = false
    private var isStopRequested = false
    private var shouldScrollToFocusedResult = false
    private var isClosing = false
    private var didNotifyClose = false
    private var overflowMenu: ReaderOverflowMenuView?
    private var pendingResults: [ContentSearchResult] = []
    private var scheduledDeliveryGeneration: Int?
    private var deliveryRetry: DispatchWorkItem?
    private var needsResultReset = false
    private var needsDelivery = false
    private var isDelivering = false
    private var needsInitialFocus = false
    private var completion: Completion?
    private var isPresentationVisible = false
    private var isSceneSuspended = false
    private var isDeparting = false
    private var isSourceInvalidated = false
    private var listInteractionEnabled = true
    private var cellSnapshots: [ObjectIdentifier: CellSnapshot] = [:]
    private var highlightedSnapshot: CellSnapshot?
    private var selectionSnapshot: CellSnapshot?

    init(
        screen: ReaderScreenAdapterSearchable,
        initialQuery: String? = nil,
        currentChapterIndex: Int,
        cachedResults: [ContentSearchResult] = [],
        focusedResultIndex: Int? = nil,
        options: ReaderContentSearchOptions = .init(),
        cachedResultOptions: ReaderContentSearchOptions
    ) {
        self.screen = screen
        self.initialQuery = initialQuery
        self.cachedResults = cachedResults
        self.focusedResultIndex = focusedResultIndex
        self.currentChapterIndex = currentChapterIndex
        self.options = options
        resultOptions = cachedResultOptions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override func loadView() { view = page }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.setNavigationBarHidden(true, animated: false)
        page.toolbar.onBack = { [weak self] in self?.exitSearch() }
        page.toolbar.onSubmit = { [weak self] in self?.submitSearch() }
        page.toolbar.onMore = { [weak self] in self?.presentMoreMenu() }
        page.summaryButton.addTarget(self, action: #selector(focusQuery), for: .touchUpInside)
        page.topButton.addTarget(self, action: #selector(scrollToTop), for: .touchUpInside)
        page.bottomButton.addTarget(self, action: #selector(scrollToBottom), for: .touchUpInside)
        page.stopButton.addTarget(self, action: #selector(stopSearch), for: .touchUpInside)
        page.onFastScrollStateChange = { [weak self] active in
            guard let self else { return }
            if !active { self.scheduleDelivery() }
            self.updateNavigationControls()
        }
        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            ReaderContentSearchResultCell.self, forCellReuseIdentifier: ReaderContentSearchResultCell.reuseIdentifier)
        tableView.panGestureRecognizer.addTarget(self, action: #selector(listPanChanged(_:)))
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didActivateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }

        let query = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cachedResults.isEmpty {
            results = cachedResults
            searchField.text = query.isEmpty ? cachedResults.first?.query : query
            shouldScrollToFocusedResult = focusedResultIndex != nil
            tableView.reloadData()
            updateSummary()
        } else if query.isEmpty {
            updateSummary()
            needsInitialFocus = true
        } else {
            searchField.text = query
            startSearch(query: query)
        }
        page.toolbar.updateQueryControls()
        refreshInteractionAvailability()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
        isPresentationVisible = true
        isDeparting = false
        isSceneSuspended = false
        refreshInteractionAvailability()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationVisible = false
        isDeparting = isLeavingPresentation
        refreshInteractionAvailability()
        overflowMenu?.dismiss()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isDeparting && !isClosing {
            isClosing = true
            cancelSearch()
            notifyClose()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshInteractionAvailability()
    }

    deinit {
        searchTask?.cancel()
        deliveryRetry?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent
        }
        return false
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isClosing = true
        cancelSearch()
        notifyClose()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitSearch()
    }

    @discardableResult
    private func submitSearch() -> Bool {
        let query = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty, searchField.markedTextRange == nil, canUseControls,
            !page.isFastScrolling, canOpenResult?() != false
        else { return false }
        view.endEditing(true)
        startSearch(query: query)
        return true
    }

    private func startSearch(query: String) {
        guard !isClosing, !isLeavingPresentation, !isSourceInvalidated, canOpenResult?() != false else { return }
        cancelSearch()
        let generation = searchGeneration
        let submittedOptions = options
        self.submittedOptions = submittedOptions
        submittedQuery = query
        needsResultReset = true
        needsDelivery = true
        shouldScrollToFocusedResult = false
        acceptsResults = true
        isSearching = true
        flushPendingResults()
        updateNavigationControls()

        searchTask = Task { @MainActor [weak self, screen] in
            do {
                try Task.checkCancellation()
                try await screen.searchInBook(keyword: query, options: submittedOptions) { [weak self] result in
                    DispatchQueue.main.async { [weak self] in self?.append(result, generation: generation) }
                }
                // Results and completion share this FIFO, including synchronous cache-only searches.
                DispatchQueue.main.async { [weak self] in self?.finish(generation: generation) }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.finish(generation: generation, error: error) }
            }
        }
    }

    private func presentMoreMenu() {
        if let overflowMenu {
            overflowMenu.dismiss()
            return
        }
        guard canUseControls, !page.isFastScrolling, !isSourceInvalidated, canOpenResult?() != false else { return }
        let generation = searchGeneration
        let menuOptions = options
        let menu = ReaderOverflowMenuView(
            items: [
                .init(
                    identifier: "reader_search_replace_enabled", title: "替换",
                    isChecked: options.replaceEnabled
                ) { [weak self] in
                    guard let self, self.canUseControls, !self.isSourceInvalidated,
                        self.searchGeneration == generation, self.options == menuOptions,
                        self.canOpenResult?() != false
                    else { return }
                    self.options.replaceEnabled.toggle()
                    self.onOptionsChanged?(self.options)
                }
            ],
            anchorView: page.toolbar.moreButton,
            interfaceStyle: traitCollection.userInterfaceStyle,
            placement: .belowAnchor
        )
        menu.canActivateItem = { [weak self] in
            guard let self else { return false }
            return self.canUseSearchSurface && !self.isSourceInvalidated && !self.page.isFastScrolling
                && self.searchGeneration == generation && self.options == menuOptions
                && self.canOpenResult?() != false
        }
        menu.onDismiss = { [weak self, weak menu] in
            guard let self, self.overflowMenu === menu else { return }
            self.overflowMenu = nil
            self.refreshInteractionAvailability()
        }
        overflowMenu = menu
        refreshInteractionAvailability()
        menu.present(in: view)
        if menu.superview == nil, overflowMenu === menu {
            overflowMenu = nil
            refreshInteractionAvailability()
        }
    }

    private func accepts(_ generation: Int) -> Bool {
        searchGeneration == generation && acceptsResults && !isClosing && !isSourceInvalidated
    }

    private func append(_ result: ContentSearchResult, generation: Int) {
        guard accepts(generation), result.query == submittedQuery else { return }
        guard canOpenResult?() != false else {
            invalidateSource()
            return
        }
        pendingResults.append(result)
        needsDelivery = true
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard needsDelivery, scheduledDeliveryGeneration != searchGeneration else { return }
        deliveryRetry?.cancel()
        deliveryRetry = nil
        let generation = searchGeneration
        scheduledDeliveryGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.searchGeneration == generation,
                self.scheduledDeliveryGeneration == generation
            else { return }
            self.scheduledDeliveryGeneration = nil
            self.flushPendingResults()
        }
    }

    private func flushPendingResults() {
        guard needsDelivery, !isDelivering else { return }
        guard canUseControls, !isListBusy else {
            scheduleDeferredDeliveryRetry()
            return
        }
        guard isSourceInvalidated || canOpenResult?() != false else {
            invalidateSource()
            return
        }
        isDelivering = true
        defer { isDelivering = false }

        // Self-sizing rows can revise earlier height estimates when a tail batch is inserted.
        tableView.layoutIfNeeded()
        let anchor = needsResultReset ? nil : tableView.indexPathsForVisibleRows?.min()
        let anchorOffset = anchor.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        let resetting = needsResultReset
        let oldMessage = message
        if resetting {
            results.removeAll(keepingCapacity: true)
            resultsGeneration = searchGeneration
            resultOptions = submittedOptions
            cellSnapshots.removeAll(keepingCapacity: true)
            needsResultReset = false
        }
        let first = results.count
        results.append(contentsOf: pendingResults)
        pendingResults.removeAll(keepingCapacity: true)
        message = nil
        if results.isEmpty, let completion {
            switch completion {
            case .finished: message = "搜索内容为空，请检查净化或简繁设置"
            case .stopped: break
            case .failed(let error): message = error
            }
        }
        needsDelivery = false
        UIView.performWithoutAnimation {
            if resetting || (results.isEmpty && oldMessage != message) {
                tableView.reloadData()
            } else if first < results.count {
                tableView.insertRows(at: (first..<results.count).map { IndexPath(row: $0, section: 0) }, with: .none)
            }
            tableView.layoutIfNeeded()
            if resetting {
                tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
            } else if let anchor, let anchorOffset, results.indices.contains(anchor.row) {
                let minimum = -tableView.adjustedContentInset.top
                let maximum = max(
                    minimum,
                    tableView.contentSize.height - tableView.bounds.height
                        + tableView.adjustedContentInset.bottom)
                let y = min(maximum, max(minimum, tableView.rectForRow(at: anchor).minY - anchorOffset))
                tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: y), animated: false)
            }
        }
        page.setSearching(isSearching)
        updateSummary()
        updateNavigationControls()
    }

    private func finish(generation: Int, error: Error? = nil) {
        guard accepts(generation) else { return }
        guard canOpenResult?() != false else {
            invalidateSource()
            return
        }
        acceptsResults = false
        isSearching = false
        searchTask = nil
        if isStopRequested || error is CancellationError {
            completion = .stopped
        } else if let error {
            completion = .failed(L10n.Reader.searchFailed(error.userFacingMessage))
        } else {
            completion = .finished
        }
        needsDelivery = true
        scheduleDelivery()
        updateNavigationControls()
    }

    private func cancelSearch() {
        searchGeneration &+= 1
        acceptsResults = false
        pendingResults.removeAll(keepingCapacity: true)
        scheduledDeliveryGeneration = nil
        deliveryRetry?.cancel()
        deliveryRetry = nil
        needsDelivery = false
        needsResultReset = false
        completion = nil
        isStopRequested = false
        selectionSnapshot = nil
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    @objc private func stopSearch() {
        guard isSearching else { return }
        guard canUseControls, !isSourceInvalidated, canOpenResult?() != false else { return }
        isStopRequested = true
        isSearching = false
        searchTask?.cancel()
        searchTask = nil
        // Drain result callbacks already queued before the terminal marker, without changing datasets.
        let generation = searchGeneration
        DispatchQueue.main.async { [weak self] in
            self?.finish(generation: generation)
        }
        updateNavigationControls()
    }

    private func updateSummary() {
        let count = "搜索结果: \(results.count)"
        switch completion {
        case .failed(let error): page.setSummary("\(count)，\(error)", isError: true)
        default: page.setSummary(count)
        }
    }

    private func invalidateSource() {
        guard !isSourceInvalidated else { return }
        cancelSearch()
        isSourceInvalidated = true
        needsResultReset = true
        needsDelivery = true
        completion = .failed("书籍已变化，请重新打开正文搜索")
        refreshInteractionAvailability()
    }

    private func updateNavigationControls() {
        let canAct = canUseControls && !isSourceInvalidated && canOpenResult?() != false
        let currentResults = resultsGeneration == searchGeneration && !needsResultReset
        let enabled = canAct && currentResults && !results.isEmpty && !page.isFastScrolling
        page.topButton.isEnabled = enabled
        page.bottomButton.isEnabled = enabled
        page.summaryButton.isEnabled = canAct && !page.isFastScrolling
        page.stopButton.isEnabled = canAct && isSearching
        tableView.allowsSelection = canAct && currentResults && !page.isFastScrolling
    }

    private var canUseControls: Bool {
        overflowMenu == nil && canUseSearchSurface
    }

    private var canUseSearchSurface: Bool {
        guard isPresentationVisible, !isSceneSuspended, !isClosing, !isLeavingPresentation,
            let view = viewIfLoaded, !view.isHidden, view.alpha > 0.01,
            let window = view.window, !window.isHidden,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            canInteract?() != false
        else { return false }
        if let navigationController, navigationController.topViewController !== self { return false }
        var controller: UIViewController? = self
        while let current = controller {
            if current.presentedViewController != nil { return false }
            controller = current.parent
        }
        return true
    }

    private var isListBusy: Bool {
        let pan = tableView.panGestureRecognizer.state
        let hasHighlightedCell =
            highlightedSnapshot.map {
                tableView.cellForRow(at: IndexPath(row: $0.row, section: 0))?.isHighlighted == true
            } ?? false
        return page.isFastScrolling || tableView.isTracking || tableView.isDragging || tableView.isDecelerating
            || pan == .began || pan == .changed || hasHighlightedCell || selectionSnapshot != nil
    }

    func refreshInteractionAvailability() {
        guard isViewLoaded else { return }
        let surfaceEnabled = canUseSearchSurface && !isSourceInvalidated && canOpenResult?() != false
        let enabled = surfaceEnabled && overflowMenu == nil
        if !enabled {
            selectionSnapshot = nil
            highlightedSnapshot = nil
            page.cancelFastScrolling()
        }
        if enabled != listInteractionEnabled {
            listInteractionEnabled = enabled
            page.setListActionsEnabled(enabled)
        }
        // Popup ownership requires a live, enabled anchor; its overlay blocks toolbar touches.
        if searchField.isEnabled != surfaceEnabled {
            page.toolbar.setInteractionEnabled(surfaceEnabled)
        }
        updateNavigationControls()
        scheduleDelivery()
        guard enabled, !isListBusy, !needsResultReset else { return }
        if needsInitialFocus {
            needsInitialFocus = false
            searchField.becomeFirstResponder()
        }
        if shouldScrollToFocusedResult, let focusedResultIndex, results.indices.contains(focusedResultIndex) {
            shouldScrollToFocusedResult = false
            tableView.scrollToRow(at: IndexPath(row: focusedResultIndex, section: 0), at: .top, animated: false)
        }
    }

    private func scheduleDeferredDeliveryRetry() {
        // Covers and tracking-only touches do not always produce appearance/scroll-end callbacks.
        guard deliveryRetry == nil, needsDelivery, isPresentationVisible, !isClosing, !isSceneSuspended,
            UIApplication.shared.applicationState == .active,
            viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return }
        let generation = searchGeneration
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.deliveryRetry = nil
            self.refreshInteractionAvailability()
        }
        deliveryRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: retry)
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        isSceneSuspended =
            notification.name != UIApplication.didBecomeActiveNotification
            && notification.name != UIScene.didActivateNotification
        refreshInteractionAvailability()
    }

    @objc private func listPanChanged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            scheduleDelivery()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        selectionSnapshot = nil
        highlightedSnapshot = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleDelivery() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scheduleDelivery() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scheduleDelivery() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { scheduleDelivery() }

    @objc private func focusQuery() {
        guard canUseControls, !isSourceInvalidated, canOpenResult?() != false, !page.isFastScrolling else { return }
        searchField.becomeFirstResponder()
    }

    @objc private func scrollToTop() { scrollToEdge(last: false) }
    @objc private func scrollToBottom() { scrollToEdge(last: true) }

    private func scrollToEdge(last: Bool) {
        guard canUseControls, !isSourceInvalidated, canOpenResult?() != false,
            resultsGeneration == searchGeneration, !needsResultReset, !results.isEmpty, !page.isFastScrolling
        else { return }
        view.endEditing(true)
        tableView.scrollToRow(at: IndexPath(row: last ? results.count - 1 : 0, section: 0), at: .top, animated: false)
        scheduleDelivery()
    }

    private func exitSearch() {
        guard canUseControls else { return }
        isClosing = true
        refreshInteractionAvailability()
        overflowMenu?.dismiss()
        cancelSearch()
        view.endEditing(true)
        didNotifyClose = true
        let onClose = onClose
        dismiss(animated: true) { onClose?() }
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose?()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count + (results.isEmpty && message != nil ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: ReaderContentSearchResultCell.reuseIdentifier, for: indexPath)
            as! ReaderContentSearchResultCell
        if let result = results[safe: indexPath.row] {
            cell.configure(with: result, isCurrentChapter: Int(result.chapterIndex) == currentChapterIndex)
            cellSnapshots[ObjectIdentifier(cell)] = CellSnapshot(
                generation: resultsGeneration, row: indexPath.row, result: result)
        } else {
            cell.configureEmpty(message: message ?? "")
            cellSnapshots.removeValue(forKey: ObjectIdentifier(cell))
        }
        return cell
    }

    private func selectableSnapshot(at indexPath: IndexPath) -> CellSnapshot? {
        guard canUseControls, !isSourceInvalidated, !page.isFastScrolling,
            !tableView.isDragging, !tableView.isDecelerating, canOpenResult?() != false,
            !needsResultReset, resultsGeneration == searchGeneration,
            let cell = tableView.cellForRow(at: indexPath),
            let snapshot = cellSnapshots[ObjectIdentifier(cell)], snapshot.generation == searchGeneration,
            snapshot.row == indexPath.row, let result = results[safe: indexPath.row], snapshot.result === result,
            !result.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return snapshot
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        selectableSnapshot(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        highlightedSnapshot = selectableSnapshot(at: indexPath)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        if highlightedSnapshot?.row == indexPath.row { highlightedSnapshot = nil }
        scheduleDelivery()
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        selectionSnapshot = nil
        if let highlightedSnapshot, highlightedSnapshot.generation != searchGeneration { return nil }
        guard let snapshot = selectableSnapshot(at: indexPath) else { return nil }
        selectionSnapshot = snapshot
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selection = selectionSnapshot
        selectionSnapshot = nil
        tableView.deselectRow(at: indexPath, animated: false)
        guard let selection, let selected = selectableSnapshot(at: indexPath),
            selection.generation == selected.generation, selection.row == selected.row,
            selection.result === selected.result
        else { return }
        isClosing = true
        didNotifyClose = true
        refreshInteractionAvailability()
        let snapshot = results
        let options = options
        let resultOptions = resultOptions
        let delegate = delegate
        let canOpenResult = canOpenResult
        let scene = view.window?.windowScene
        cancelSearch()
        let dismissalGeneration = searchGeneration
        view.endEditing(true)
        dismiss(animated: true) { [self, weak scene] in
            guard searchGeneration == dismissalGeneration, canOpenResult?() != false,
                UIApplication.shared.applicationState == .active, scene?.activationState == .foregroundActive
            else { return }
            delegate?.searchContentDidSelectResult(
                selection.result, at: selection.row, allResults: snapshot, options: options, resultOptions: resultOptions)
        }
    }
}

/// The adapter owns cached-content search; the page owns only presentation and operation lifetime.
protocol ReaderScreenAdapterSearchable {
    func searchInBook(keyword: String, onResult: @escaping (ContentSearchResult) -> Void) async throws
    func searchInBook(
        keyword: String,
        options: ReaderContentSearchOptions,
        onResult: @escaping (ContentSearchResult) -> Void
    ) async throws
}
