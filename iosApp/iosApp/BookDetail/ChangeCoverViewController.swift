import SnapKit
import UIKit
import shared

@MainActor
protocol ChangeCoverDelegate: AnyObject {
    func changeCoverDidSelect(_ coverUrl: String)
}

final class ChangeCoverViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout
{
    weak var delegate: ChangeCoverDelegate?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private let bookURL: String
    private let bookName: String
    private let bookAuthor: String
    private let originalCoverUrl: String?

    /// Closure that creates a streaming cover search session.
    private let sessionFactory:
        (
            _ onResult: @escaping (CoverSearchResult) -> Void,
            _ onProgress: @escaping (CoverSearchProgress) -> Void,
            _ onFinished: @escaping () -> Void
        ) async throws -> CoverSearchSession

    private var coverItems: [CoverItem] = []
    private var collectionView: UICollectionView!
    private var searchSession: CoverSearchSession?
    private var creationTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var isSearching = false

    private let chromeView = ChangeCoverChromeView()
    private var statusFooterText: String?
    private var hasSearchError = false
    private var lastGridWidth: CGFloat = 0
    private var isClosing = false
    private var imageTasks: [UUID: Task<Void, Never>] = [:]
    private var defaultCoverTask: Task<Void, Never>?
    private var restoredCoverRuleTask: Task<Void, Never>?
    private var placeholder: ChangeCoverGridCell.Placeholder

    private struct CoverItem {
        let id = UUID()
        let coverUrl: String
        let sourceName: String
        let isDefault: Bool
        var image: UIImage?
        var isImageLoading = false
    }

    init(
        bookURL: String,
        bookName: String,
        bookAuthor: String,
        originalCoverUrl: String?,
        sessionFactory:
            @escaping (
                _ onResult: @escaping (CoverSearchResult) -> Void,
                _ onProgress: @escaping (CoverSearchProgress) -> Void,
                _ onFinished: @escaping () -> Void
            ) async throws -> CoverSearchSession
    ) {
        self.bookURL = bookURL
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        self.originalCoverUrl = originalCoverUrl
        self.sessionFactory = sessionFactory
        self.placeholder = ChangeCoverGridCell.Placeholder(bookName: bookName, bookAuthor: bookAuthor)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.BookDetail.changeCoverSource
        chromeView.onClose = { [weak self] in self?.dismissSelf() }
        chromeView.onSearchToggle = { [weak self] in self?.toggleSearch() }

        setupCollectionView()
        applyTheme()

        // Insert default cover item
        coverItems.insert(
            CoverItem(
                coverUrl: "use_default_cover",
                sourceName: L10n.BookDetail.defaultCover,
                isDefault: true,
                image: nil
            ), at: 0)
        collectionView.reloadData()

        loadDefaultCover()
        startSearch()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = gridWidth
        if width != lastGridWidth {
            lastGridWidth = width
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyTheme()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false {
            let visibility = AndroidDefaultBookCoverRenderer.restoredVisibility(traits: traitCollection)
            placeholder.drawBookName = visibility.name
            placeholder.drawBookAuthor = visibility.author
            for case let cell as ChangeCoverGridCell in collectionView.visibleCells {
                guard let indexPath = collectionView.indexPath(for: cell), indexPath.item < coverItems.count else {
                    continue
                }
                configure(cell, with: coverItems[indexPath.item])
            }
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismissSelf()
        return true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            stopSearch()
            cancelImageLoads()
            defaultCoverTask?.cancel()
        }
    }

    deinit {
        creationTask?.cancel()
        searchSession?.dispose()
        defaultCoverTask?.cancel()
        restoredCoverRuleTask?.cancel()
        for task in imageTasks.values { task.cancel() }
    }

    // MARK: - Collection view

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        // ChangeCoverDialog uses GridLayoutManager(3); item padding supplies all spacing.
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            ChangeCoverGridCell.self, forCellWithReuseIdentifier: ChangeCoverGridCell.reuseIdentifier)
        collectionView.register(
            ChangeCoverStatusFooterView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: ChangeCoverStatusFooterView.reuseIdentifier)
        view.addSubview(chromeView)
        chromeView.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview() }
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints {
            $0.top.equalTo(chromeView.snp.bottom)
            $0.leading.trailing.bottom.equalToSuperview()
        }
    }

    private func applyTheme() {
        view.backgroundColor = AndroidReplicaTheme.bottomBackground
        view.tintColor = AndroidReplicaTheme.accent
        collectionView?.backgroundColor = AndroidReplicaTheme.background
    }

    private var gridWidth: CGFloat {
        max(
            0,
            collectionView.bounds.width - collectionView.adjustedContentInset.left
                - collectionView.adjustedContentInset.right)
    }

    private func loadDefaultCover() {
        guard case .success(let facade) = SharedRuntime.bookImageFacade() else { return }
        let visibility = AndroidDefaultBookCoverRenderer.restoredVisibility(traits: traitCollection)
        placeholder.drawBookName = visibility.name
        placeholder.drawBookAuthor = visibility.author
        guard let path = facade.defaultCoverUrl, !path.isEmpty else { return }
        let bookURL = bookURL
        defaultCoverTask = Task { [weak self] in
            let image: UIImage?
            if let url = BookCoverImageLoader.localImageURL(path) {
                image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
            } else {
                image = await BookCoverImageLoader.loadDecodedImage(bookUrl: bookURL, imageUrl: path, isCover: true)
            }
            await MainActor.run {
                guard let self, !Task.isCancelled, !self.isClosing else { return }
                self.defaultCoverTask = nil
                self.placeholder.image = image
                self.collectionView.reloadData()
            }
        }
    }

    private func cancelImageLoads() {
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
    }

    private func setStatus(_ text: String, footer: String? = nil, isError: Bool = false) {
        chromeView.setStatus(text)
        hasSearchError = isError
        statusFooterText = footer ?? text
        collectionView.collectionViewLayout.invalidateLayout()
        for case let footerView as ChangeCoverStatusFooterView in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionFooter)
        {
            footerView.configure(text: statusFooterText, isError: isError)
        }
    }

    // MARK: - Search control

    private func startSearch() {
        stopSearch()
        cancelImageLoads()
        let generation = searchGeneration
        // Keep only default cover item
        coverItems = coverItems.filter { $0.isDefault }
        collectionView.reloadData()
        updateSearchState(searching: true)
        setStatus(L10n.Search.loadingSearch)
        searchRestoredCoverRule(generation: generation)

        let sessionFactory = sessionFactory
        creationTask = Task { [weak self] in
            do {
                let session = try await sessionFactory(
                    { [weak self] result in
                        DispatchQueue.main.async {
                            guard self?.searchGeneration == generation, self?.isSearching == true else { return }
                            self?.handleNewCover(result)
                        }
                    },
                    { [weak self] progress in
                        DispatchQueue.main.async {
                            guard self?.searchGeneration == generation, self?.isSearching == true else { return }
                            self?.handleProgress(progress)
                        }
                    },
                    { [weak self] in
                        DispatchQueue.main.async {
                            guard self?.searchGeneration == generation, self?.isSearching == true else { return }
                            self?.handleSearchFinished()
                        }
                    }
                )
                await MainActor.run {
                    guard let self, self.searchGeneration == generation, !Task.isCancelled, !self.isClosing else {
                        session.dispose()
                        return
                    }
                    self.creationTask = nil
                    self.searchSession = session
                    session.start()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.searchGeneration == generation, !Task.isCancelled else { return }
                    self.creationTask = nil
                    self.updateSearchState(searching: false)
                    self.setStatus(error.localizedDescription, footer: error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func searchRestoredCoverRule(generation: UUID) {
        guard case .success(let facade) = SharedRuntime.bookImageFacade() else { return }
        let rule = facade.getCoverRule()
        guard rule.enable, !rule.searchUrl.isEmpty, !rule.coverRule.isEmpty else { return }
        let bookURL = bookURL
        restoredCoverRuleTask = Task { [weak self] in
            do {
                let url: String? = try await SharedAsync.optionalValue { completion in
                    facade.searchCover(bookUrl: bookURL, coverRuleConfig: rule, completionHandler: completion)
                }
                await MainActor.run {
                    guard let self, let url, !Task.isCancelled, !self.isClosing,
                          self.searchGeneration == generation,
                          !self.coverItems.contains(where: { $0.coverUrl == url }) else { return }
                    self.handleNewCover(CoverSearchResult(coverUrl: url, sourceName: "封面规则", sourceUrl: rule.searchUrl))
                    if !self.isSearching { self.handleSearchFinished() }
                }
            } catch {
                if !Task.isCancelled { SharedRuntime.log("cover rule search failed: \(error.localizedDescription)") }
            }
        }
    }

    private func stopSearch() {
        restoredCoverRuleTask?.cancel()
        restoredCoverRuleTask = nil
        searchGeneration = UUID()
        creationTask?.cancel()
        creationTask = nil
        searchSession?.dispose()
        searchSession = nil
        updateSearchState(searching: false)
    }

    @objc private func toggleSearch() {
        guard !isClosing else { return }
        if isSearching {
            stopSearch()
            let count = coverItems.filter { !$0.isDefault }.count
            setStatus(count == 0 ? L10n.Reader.searchStopped : L10n.Reader.searchStoppedWithResults(count))
        } else {
            startSearch()
        }
    }

    private func updateSearchState(searching: Bool) {
        isSearching = searching
        chromeView.setSearching(searching)
    }

    // MARK: - Callbacks from search session

    private func handleNewCover(_ result: CoverSearchResult) {
        let item = CoverItem(
            coverUrl: result.coverUrl,
            sourceName: result.sourceName,
            isDefault: false,
            image: nil,
            isImageLoading: true
        )
        coverItems.append(item)
        let indexPath = IndexPath(item: coverItems.count - 1, section: 0)
        collectionView.insertItems(at: [indexPath])

        // Load cover image asynchronously
        let bookURL = bookURL
        imageTasks[item.id] = Task { [weak self] in
            let image = await BookCoverImageLoader.loadDecodedImage(
                bookUrl: bookURL,
                imageUrl: result.coverUrl,
                isCover: true
            )
            await MainActor.run {
                guard let self, !Task.isCancelled, !self.isClosing,
                    let itemIndex = self.coverItems.firstIndex(where: { $0.id == item.id })
                else { return }
                self.imageTasks[item.id] = nil
                self.coverItems[itemIndex].image = image
                self.coverItems[itemIndex].isImageLoading = false
                if let cell = self.collectionView.cellForItem(at: IndexPath(item: itemIndex, section: 0))
                    as? ChangeCoverGridCell
                {
                    self.configure(cell, with: self.coverItems[itemIndex])
                }
            }
        }
    }

    private func handleProgress(_ progress: CoverSearchProgress) {
        guard isSearching else { return }
        setStatus(
            String(
                format: L10n.BookDetail.changeCoverSearchProgress,
                progress.searched,
                progress.total,
                progress.found
            ))
    }

    private func handleSearchFinished() {
        updateSearchState(searching: false)
        searchSession?.dispose()
        searchSession = nil
        let coverCount = coverItems.filter { !$0.isDefault }.count
        if coverCount == 0 {
            setStatus(L10n.BookDetail.changeCoverEmpty, footer: L10n.BookDetail.changeCoverEmpty)
        } else {
            setStatus(
                String(
                    format: L10n.BookDetail.changeCoverSearchComplete,
                    coverCount
                ))
        }
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        coverItems.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
    {
        let cell =
            collectionView.dequeueReusableCell(withReuseIdentifier: ChangeCoverGridCell.reuseIdentifier, for: indexPath)
            as! ChangeCoverGridCell
        let item = coverItems[indexPath.item]
        configure(cell, with: item)
        return cell
    }

    private func configure(_ cell: ChangeCoverGridCell, with item: CoverItem) {
        cell.configure(
            sourceName: item.sourceName, image: item.image, isDefault: item.isDefault,
            isLoading: item.isImageLoading, placeholder: placeholder)
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let footer =
            collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: ChangeCoverStatusFooterView.reuseIdentifier, for: indexPath)
            as! ChangeCoverStatusFooterView
        footer.configure(text: statusFooterText, isError: hasSearchError)
        return footer
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let itemWidth = gridWidth / 3
        return CGSize(width: itemWidth, height: ChangeCoverGridCell.itemHeight(compatibleWith: traitCollection))
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForFooterInSection section: Int
    ) -> CGSize {
        // The original has no normal progress footer; retain iOS's existing visible failure recovery.
        guard hasSearchError, let text = statusFooterText else { return .zero }
        return CGSize(
            width: gridWidth,
            height: ChangeCoverStatusFooterView.height(for: text, width: gridWidth, traits: traitCollection))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isClosing else { return }
        isClosing = true
        collectionView.deselectItem(at: indexPath, animated: true)
        let item = coverItems[indexPath.item]
        let callback = delegate
        stopSearch()
        cancelImageLoads()
        defaultCoverTask?.cancel()
        dismiss(animated: true) {
            callback?.changeCoverDidSelect(item.isDefault ? "" : item.coverUrl)
        }
    }

    @objc private func dismissSelf() {
        guard !isClosing else { return }
        isClosing = true
        stopSearch()
        cancelImageLoads()
        defaultCoverTask?.cancel()
        dismiss(animated: true)
    }
}
