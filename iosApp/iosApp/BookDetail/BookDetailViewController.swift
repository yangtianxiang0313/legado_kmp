import UIKit
import SnapKit
import shared

final class BookDetailViewController: UIViewController, ChangeSourceDelegate, ChangeCoverDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let screen: BookDetailScreenAdapter
    private let bookURL: String
    private var book: Book?
    private var chapters: [BookChapter] = []
    private var isInBookshelf = false
    private var loadingTask: Task<Void, Never>?
    private var defaultChapterPreloadTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var hasAttemptedDefaultChapterPreload = false
    private var isDefaultChapterPreloadRunning = false
    private var isUpdatingHeaderLayout = false
    private var isShelfMutationInFlight = false
    private var expectedShelfStateAfterMutation: Bool?
    private var bookInfoDeleteAlertEnabled = true
    private var lastHeaderLayoutSize: CGSize = .zero
    private var didNavigateToReader = false

    private let scaffoldView = LegacyRootScaffoldView()
    private let scrollView = UIScrollView()
    private let refreshControl = UIRefreshControl()
    private let contentView = UIView()
    private let headerView = BookDetailHeaderView()
    private var headerHeightConstraint: NSLayoutConstraint?
    private lazy var backButton = makeLegacyBarButton(
        imageSystemName: "chevron.left",
        target: self,
        action: #selector(handleBackTapped)
    )
    private lazy var moreButton = makeLegacyBarButton(
        imageSystemName: "ellipsis.circle",
        target: self,
        action: #selector(handleMoreTapped)
    )

    private let stateView = ContentStateView()
    private let debugLabel = UILabel()

    private let bottomActionBar = UIView()
    private let bottomDividerView = UIView()
    private let bottomActionStackView = UIStackView()
    private let bottomShelfButton = UIButton(type: .system)
    private let bottomReadButton = UIButton(type: .system)

    init(bookURL: String) {
        self.bookURL = bookURL
        self.screen = BookDetailScreenAdapter(bookURL: bookURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.BookDetail.title
        view.backgroundColor = .systemBackground
        navigationItem.hidesBackButton = true

        headerView.onTitleTap = { [weak self] in
            self?.openRelatedSearch(keyword: self?.book?.name)
        }
        headerView.onAuthorTap = { [weak self] in
            self?.openRelatedSearch(keyword: self?.book?.author)
        }
        headerView.onChapterListTap = { [weak self] in
            self?.openChapterList()
        }
        headerView.onChangeSourceTap = { [weak self] in
            self?.presentSourceChangePicker()
        }
        headerView.onChangeGroupTap = { [weak self] in
            self?.presentGroupPicker()
        }
        headerView.onCoverTap = { [weak self] in
            self?.presentChangeCoverOptions()
        }
        headerView.onCoverLongPress = { [weak self] image in
            self?.presentCoverFullscreen(image: image)
        }

        scaffoldView.titleBarView.setTitle(L10n.BookDetail.title)
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        scaffoldView.titleBarView.setLeftViews([backButton])
        scaffoldView.titleBarView.setRightViews([moreButton])

        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        configureScrollContent()
        configureRefreshControl()
        configureBottomActionBar()
        configureDebugMarkerIfNeeded()
        view.bringSubviewToFront(bottomActionBar)

        scaffoldView.contentView.addSubview(stateView)
        stateView.setTestingIdentifier(UIIdentifiers.BookDetail.state)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: scaffoldView.contentView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: scaffoldView.contentView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: scaffoldView.contentView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: scaffoldView.contentView.bottomAnchor),
        ])

        updateDebugMarker("viewDidLoad:\(bookURL)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if navigationController?.topViewController === self {
            updateDebugMarker("visible:\(bookURL)")
            if hasBootstrapped == false {
                hasBootstrapped = true
                bootstrapDependencies()
            } else if didNavigateToReader {
                didNavigateToReader = false
                updateHeader()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    deinit {
        defaultChapterPreloadTask?.cancel()
        screen.unbind()
    }

    private func configureScrollContent() {
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        scrollView.accessibilityIdentifier = UIIdentifiers.BookDetail.table

        scaffoldView.contentView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(headerView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        headerView.translatesAutoresizingMaskIntoConstraints = false

        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: 320)
        headerHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: scaffoldView.contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: scaffoldView.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: scaffoldView.contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scaffoldView.contentView.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func configureRefreshControl() {
        refreshControl.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
        scrollView.refreshControl = refreshControl
    }

    private func configureBottomActionBar() {
        bottomActionBar.accessibilityIdentifier = UIIdentifiers.BookDetail.bottomActionBar
        bottomActionBar.backgroundColor = .systemBackground
        bottomDividerView.backgroundColor = .separator.withAlphaComponent(0.3)

        bottomActionStackView.axis = .horizontal
        bottomActionStackView.spacing = AppUI.Spacing.small
        bottomActionStackView.distribution = .fillEqually
        bottomActionStackView.translatesAutoresizingMaskIntoConstraints = false

        var shelfConfiguration = UIButton.Configuration.plain()
        shelfConfiguration.cornerStyle = .large
        shelfConfiguration.imagePadding = 8
        shelfConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        bottomShelfButton.configuration = shelfConfiguration
        bottomShelfButton.accessibilityIdentifier = UIIdentifiers.BookDetail.bottomShelfAction
        bottomShelfButton.addTarget(self, action: #selector(handleBottomShelfTap), for: .touchUpInside)

        var readConfiguration = UIButton.Configuration.filled()
        readConfiguration.cornerStyle = .large
        readConfiguration.imagePadding = 8
        readConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        bottomReadButton.configuration = readConfiguration
        bottomReadButton.accessibilityIdentifier = UIIdentifiers.BookDetail.bottomReadAction
        bottomReadButton.addTarget(self, action: #selector(handleBottomReadTap), for: .touchUpInside)

        view.addSubview(bottomActionBar)
        bottomActionBar.addSubview(bottomDividerView)
        bottomActionBar.addSubview(bottomActionStackView)
        bottomActionStackView.addArrangedSubview(bottomShelfButton)
        bottomActionStackView.addArrangedSubview(bottomReadButton)

        bottomActionBar.translatesAutoresizingMaskIntoConstraints = false
        bottomDividerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            bottomActionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomActionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomActionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            bottomDividerView.topAnchor.constraint(equalTo: bottomActionBar.topAnchor),
            bottomDividerView.leadingAnchor.constraint(equalTo: bottomActionBar.leadingAnchor),
            bottomDividerView.trailingAnchor.constraint(equalTo: bottomActionBar.trailingAnchor),
            bottomDividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            bottomActionStackView.topAnchor.constraint(equalTo: bottomActionBar.safeAreaLayoutGuide.topAnchor, constant: AppUI.Spacing.small),
            bottomActionStackView.leadingAnchor.constraint(equalTo: bottomActionBar.safeAreaLayoutGuide.leadingAnchor, constant: AppUI.Spacing.medium),
            bottomActionStackView.trailingAnchor.constraint(equalTo: bottomActionBar.safeAreaLayoutGuide.trailingAnchor, constant: -AppUI.Spacing.medium),
            bottomActionStackView.bottomAnchor.constraint(equalTo: bottomActionBar.safeAreaLayoutGuide.bottomAnchor, constant: -AppUI.Spacing.small),
            bottomActionStackView.heightAnchor.constraint(equalToConstant: 50),
        ])

        scrollView.contentInset.bottom = 104
        scrollView.verticalScrollIndicatorInsets.bottom = 104
        updateBottomActions()
    }

    @objc
    private func handleBackTapped() {
        navigationController?.popViewController(animated: true)
    }

    private func bootstrapDependencies() {
        loadingTask?.cancel()
        defaultChapterPreloadTask?.cancel()
        hasAttemptedDefaultChapterPreload = false
        isDefaultChapterPreloadRunning = false
        updateDebugMarker("bootstrap:\(bookURL)")
        stateView.showLoading(message: L10n.BookDetail.loading)

        screen.onBookChange = { [weak self] book in
            guard let self else { return }
            let nextIsInBookshelf = book != nil
            if self.shouldIgnoreBookWatchUpdate(nextIsInBookshelf: nextIsInBookshelf) {
                return
            }
            self.isInBookshelf = nextIsInBookshelf
            if let book {
                self.book = book
                self.title = book.name
                self.scaffoldView.titleBarView.setTitle(book.name)
                self.updateDebugMarker("watchBook:\(book.bookUrl)")
            } else {
                self.title = L10n.BookDetail.title
                self.scaffoldView.titleBarView.setTitle(L10n.BookDetail.title)
                self.updateDebugMarker("watchBook:nil")
            }
            self.stateView.hide()
            self.updateHeader()
            self.ensureDefaultChapterPreloadIfNeeded()
        }

        screen.onChaptersChange = { [weak self] chapters in
            guard let self else { return }
            self.chapters = chapters
            self.updateDebugMarker("chapters:\(chapters.count)")
            self.updateHeader()
            self.ensureDefaultChapterPreloadIfNeeded()
        }
        screen.onBookInfoDeleteAlertChange = { [weak self] enabled in
            self?.bookInfoDeleteAlertEnabled = enabled
        }

        switch screen.bootstrap() {
        case .success:
            loadInitialState()
        case .failure(let error):
            stateView.showMessage(
                title: L10n.BookDetail.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    private func loadInitialState() {
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.screen.resolveInitialBook()
                await MainActor.run {
                    self.book = resolved
                    self.title = resolved?.name ?? L10n.BookDetail.title
                    self.scaffoldView.titleBarView.setTitle(resolved?.name ?? L10n.BookDetail.title)
                    self.updateDebugMarker("resolved:\(resolved?.bookUrl ?? "nil")")
                    self.stateView.hide()
                    self.updateHeader()
                    self.ensureDefaultChapterPreloadIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.updateDebugMarker("error:\(error.userFacingMessage)")
                    self.stateView.showMessage(
                        title: L10n.BookDetail.failed,
                        message: error.userFacingMessage,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.bootstrapDependencies()
                    }
                }
            }
        }
    }

    private func toggleBookshelfState() {
        guard isShelfMutationInFlight == false else { return }
        loadingTask?.cancel()
        let wasInBookshelf = isInBookshelf
        isShelfMutationInFlight = true
        expectedShelfStateAfterMutation = !wasInBookshelf
        isInBookshelf = !wasInBookshelf
        updateHeader()
        stateView.showLoading(message: L10n.BookDetail.shelfUpdateLoading)
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var addedBook: Book?
                if wasInBookshelf {
                    try await self.screen.removeFromBookshelf()
                } else {
                    addedBook = try await self.screen.addToBookshelf()
                }
                await MainActor.run {
                    self.completeShelfMutation(finalState: !wasInBookshelf)
                    if let addedBook {
                        self.book = addedBook
                    }
                    self.stateView.hide()
                    self.updateHeader()
                }
            } catch {
                await MainActor.run {
                    self.completeShelfMutation(finalState: wasInBookshelf)
                    self.updateHeader()
                    self.presentRecoverableFailure(
                        title: L10n.BookDetail.shelfUpdateFailed,
                        error: error,
                        retry: { [weak self] in
                            self?.toggleBookshelfState()
                        }
                    )
                }
            }
        }
    }

    private func continueReading() {
        openReader(at: readingChapterIndex())
    }

    private func openChapterList(chapters overrideChapters: [BookChapter]? = nil) {
        let resolvedChapters = overrideChapters ?? chapters
        guard resolvedChapters.isEmpty == false else {
            if overrideChapters != nil {
                stateView.showMessage(
                    title: L10n.BookDetail.emptyChaptersTitle,
                    message: L10n.BookDetail.emptyChapters,
                    actionTitle: L10n.BookDetail.refreshChapters
                ) { [weak self] in
                    self?.refreshChapters(openReaderAfterRefresh: false, openChapterListAfterRefresh: true)
                }
                return
            }
            refreshChapters(openReaderAfterRefresh: false, openChapterListAfterRefresh: true)
            return
        }

        let currentIndex = min(max(readingChapterIndex(), 0), resolvedChapters.count - 1)
        let items = resolvedChapters.map { chapter in
            ReaderChapterListItem(
                chapter: chapter,
                displayTitle: chapter.title,
                isCurrent: Int(chapter.index) == currentIndex,
                isCached: false
            )
        }
        let controller = ChapterListViewController(items: items, bookURL: book?.bookUrl ?? bookURL) { [weak self] index in
            self?.openReader(at: index)
        }.configuredForDrillDownPresentation()
        navigationController?.pushViewController(controller, animated: true)
    }

    private func refreshChapters(openReaderAfterRefresh: Bool = false, openChapterListAfterRefresh: Bool = false) {
        loadingTask?.cancel()
        stateView.showLoading(message: L10n.BookDetail.refreshChaptersLoading)
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.screen.refreshChapters()
                await MainActor.run {
                    self.stateView.hide()
                    self.applyBookDetailRefreshResult(result)
                    if openChapterListAfterRefresh {
                        self.openChapterList(chapters: result.chapters)
                    } else if openReaderAfterRefresh {
                        self.openReader(at: self.readingChapterIndex())
                    }
                }
            } catch {
                await MainActor.run {
                    self.presentRecoverableFailure(
                        title: L10n.BookDetail.refreshChaptersFailed,
                        error: error,
                        retry: { [weak self] in
                            self?.refreshChapters(
                                openReaderAfterRefresh: openReaderAfterRefresh,
                                openChapterListAfterRefresh: openChapterListAfterRefresh
                            )
                        }
                    )
                }
            }
        }
    }

    private func refreshInfo() {
        loadingTask?.cancel()
        if refreshControl.isRefreshing == false {
            stateView.showLoading(message: L10n.BookDetail.refreshInfoLoading)
        }
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await self.screen.refreshInfo()
                var refreshedChapterResult: BookDetailRefreshResult?
                if refreshed.isLocal == false {
                    refreshedChapterResult = try await self.screen.refreshChapters()
                }
                await MainActor.run {
                    if let refreshedChapterResult {
                        self.applyBookDetailRefreshResult(refreshedChapterResult)
                    } else {
                        self.book = refreshed
                        self.title = refreshed.name
                        self.scaffoldView.titleBarView.setTitle(refreshed.name)
                        self.updateHeader()
                    }
                    self.stateView.hide()
                    self.refreshControl.endRefreshing()
                    self.updateDebugMarker("refreshInfo:\(refreshed.bookUrl)")
                }
            } catch {
                await MainActor.run {
                    self.refreshControl.endRefreshing()
                    self.presentRecoverableFailure(
                        title: L10n.BookDetail.refreshInfoFailed,
                        error: error,
                        retry: { [weak self] in
                            self?.refreshInfo()
                        }
                    )
                }
            }
        }
    }

    private func openReader(at chapterIndex: Int) {
        // F14: 区分音频/漫画/文本阅读器
        if let book, book.isAudio {
            let audioVC = AudioPlayViewController(bookUrl: book.bookUrl)
            present(audioVC, animated: true)
            return
        }
        didNavigateToReader = true
        let controller = ReaderContainerViewController(
            bookURL: book?.bookUrl ?? bookURL,
            initialChapterIndex: chapterIndex
        )
        // F159: 传递书架状态，不在书架上时退出阅读器会弹出加入书架提示
        controller.isInBookshelf = isInBookshelf
        _ = controller.configuredForDrillDownPresentation()
        navigationController?.pushViewController(controller, animated: true)
    }

    private func openRelatedSearch(keyword: String?) {
        guard let searchKeyword = keyword?.sanitizedDisplayText.nilIfEmpty else { return }
        let preferredSourceURL = book?.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let controller = SearchViewController(
            initialKeyword: searchKeyword,
            preferredSourceURL: preferredSourceURL
        ).configuredForDrillDownPresentation()
        navigationController?.pushViewController(controller, animated: true)
    }

    private func updateHeader() {
        headerView.configure(
            book: book,
            chapterCount: chapters.count,
            isInBookshelf: isInBookshelf,
            readingHint: readingHintText(),
            chapterHint: chapterListHintText(),
            groupName: groupDisplayName(),
            latestChapter: book?.latestChapterTitle?.sanitizedDisplayText.nilIfEmpty
        )
        updateBottomActions()
        updateHeaderLayout()
    }

    private func updateBottomActions() {
        let shelfTitle = isInBookshelf ? L10n.BookDetail.primaryActionShelfRemove : L10n.BookDetail.primaryActionShelfAdd
        var shelfConfiguration = bottomShelfButton.configuration ?? .plain()
        shelfConfiguration.title = shelfTitle
        shelfConfiguration.image = UIImage(systemName: isInBookshelf ? "books.vertical.fill" : "books.vertical")
        bottomShelfButton.configuration = shelfConfiguration
        bottomShelfButton.setTitle(shelfTitle, for: .normal)
        bottomShelfButton.accessibilityLabel = shelfTitle
        bottomShelfButton.accessibilityValue = shelfTitle

        var readConfiguration = bottomReadButton.configuration ?? .filled()
        readConfiguration.title = L10n.BookDetail.primaryActionRead
        readConfiguration.image = UIImage(systemName: "book.fill")
        bottomReadButton.configuration = readConfiguration
    }

    private func applyBookDetailRefreshResult(_ result: BookDetailRefreshResult) {
        book = result.book
        chapters = result.chapters
        title = result.book.name
        scaffoldView.titleBarView.setTitle(result.book.name)
        updateDebugMarker("chapters:\(result.chapters.count)")
        updateHeader()
    }

    private func updateHeaderLayout() {
        guard isUpdatingHeaderLayout == false else { return }
        let targetWidth = contentView.bounds.width
        guard targetWidth > 0 else { return }

        let targetHeight = headerView.fittingHeight(for: targetWidth)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        guard abs(lastHeaderLayoutSize.width - targetSize.width) > 0.5 ||
                abs(lastHeaderLayoutSize.height - targetSize.height) > 0.5 else {
            return
        }

        isUpdatingHeaderLayout = true
        defer {
            lastHeaderLayoutSize = targetSize
            isUpdatingHeaderLayout = false
        }

        headerHeightConstraint?.constant = targetSize.height
    }

    private func readingChapterIndex() -> Int {
        guard chapters.isEmpty == false else { return max(Int(book?.durChapterIndex ?? 0), 0) }
        let storedIndex = Int(book?.durChapterIndex ?? 0)
        return min(max(storedIndex, 0), chapters.count - 1)
    }

    private func readingHintText() -> String {
        if let title = book?.durChapterTitle?.sanitizedDisplayText.nilIfEmpty {
            return String(format: L10n.BookDetail.readingHintLast, title)
        }
        guard chapters.isEmpty == false else {
            return L10n.BookDetail.readingHintEmpty
        }
        let index = readingChapterIndex()
        return String(format: L10n.BookDetail.readingHintStart, index + 1, chapters[index].title)
    }

    private func chapterListHintText() -> String {
        if let title = book?.durChapterTitle?.sanitizedDisplayText.nilIfEmpty {
            return title
        }
        if let latest = book?.latestChapterTitle?.sanitizedDisplayText.nilIfEmpty {
            return latest
        }
        guard chapters.isEmpty == false else {
            return L10n.BookDetail.openChapterListFirst
        }
        return chapters[readingChapterIndex()].title
    }

    private func groupDisplayName() -> String {
        guard let book else { return L10n.BookDetail.groupFallbackRemote }
        return book.isLocal ? L10n.BookDetail.groupFallbackLocal : L10n.BookDetail.groupFallbackRemote
    }

    private func ensureDefaultChapterPreloadIfNeeded() {
        guard hasAttemptedDefaultChapterPreload == false else { return }
        guard isDefaultChapterPreloadRunning == false else { return }
        guard shouldDefaultPreloadChapters() else { return }

        hasAttemptedDefaultChapterPreload = true
        isDefaultChapterPreloadRunning = true
        defaultChapterPreloadTask?.cancel()
        defaultChapterPreloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.screen.preloadChapters()
                await MainActor.run {
                    self.applyBookDetailRefreshResult(result)
                    self.updateDebugMarker("preloadChapters:\(result.chapters.count)")
                    self.isDefaultChapterPreloadRunning = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isDefaultChapterPreloadRunning = false
                }
            } catch {
                await MainActor.run {
                    self.isDefaultChapterPreloadRunning = false
                    self.updateDebugMarker("preloadChaptersFailed")
                }
            }
        }
    }

    private func shouldDefaultPreloadChapters() -> Bool {
        guard let book else { return false }
        if book.isLocal {
            return chapters.isEmpty
        }
        if book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return chapters.isEmpty
    }

    private func presentSourceChangePicker() {
        let currentOrigin = book?.origin ?? ""
        let screenRef = screen
        let vc = ChangeSourceViewController(
            currentSourceUrl: currentOrigin,
            sessionFactory: { onCandidate, onProgress, onFinished in
                try await screenRef.createSourceChangeSearchSession(
                    onCandidate: onCandidate,
                    onProgress: onProgress,
                    onFinished: onFinished
                )
            }
        )
        vc.delegate = self
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func applySourceChange(_ candidate: BookSourceChangeCandidate) {
        stateView.showLoading(message: L10n.BookDetail.changeSourceLoading)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.screen.changeSource(candidateBookUrl: candidate.bookUrl, sourceUrl: candidate.sourceUrl)
                await MainActor.run {
                    self.applyBookDetailRefreshResult(result)
                    self.stateView.hide()
                }
            } catch {
                await MainActor.run {
                    self.presentRecoverableFailure(title: L10n.BookDetail.changeSource, error: error)
                }
            }
        }
    }

    // MARK: - ChangeSourceDelegate

    func changeSourceDidSelect(_ candidate: BookSourceChangeCandidate) {
        applySourceChange(candidate)
    }

    private func presentGroupPicker() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let groups = try await self.screen.loadGroups()
                await MainActor.run {
                    let validGroups = groups.filter { $0.groupId > 0 }
                    let currentGroupId = self.book?.group ?? 0

                    let alert = UIAlertController(title: L10n.BookDetail.selectGroups, message: nil, preferredStyle: .actionSheet)

                    // No group option
                    let noGroupTitle = (currentGroupId == 0) ? "✓ \(L10n.BookDetail.groupFallbackRemote)" : L10n.BookDetail.groupFallbackRemote
                    alert.addAction(UIAlertAction(title: noGroupTitle, style: .default) { _ in
                        self.applyGroupChange(0)
                    })

                    // Existing groups with checkmarks for selected
                    for group in validGroups {
                        let isSelected = (currentGroupId & group.groupId) != 0
                        let title = isSelected ? "✓ \(group.groupName)" : group.groupName
                        alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                            let newGroupId: Int64
                            if isSelected {
                                newGroupId = currentGroupId & ~group.groupId
                            } else {
                                newGroupId = currentGroupId | group.groupId
                            }
                            self.applyGroupChange(newGroupId)
                        })
                    }

                    // F97: New group option
                    alert.addAction(UIAlertAction(title: L10n.BookDetail.newGroup, style: .default) { _ in
                        self.presentNewGroupDialog()
                    })

                    alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    self.presentRecoverableFailure(title: L10n.BookDetail.changeGroup, error: error)
                }
            }
        }
    }

    private func presentNewGroupDialog() {
        let alert = UIAlertController(title: L10n.BookDetail.newGroup, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = L10n.BookDetail.groupNamePlaceholder
        }
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  name.isEmpty == false else { return }
            self?.createNewGroup(name: name)
        })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func createNewGroup(name: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let newGroup = try await self.screen.createGroup(name: name)
                await MainActor.run {
                    if let currentGroupId = self.book?.group {
                        self.applyGroupChange(currentGroupId | newGroup.groupId)
                    } else {
                        self.applyGroupChange(newGroup.groupId)
                    }
                }
            } catch {
                await MainActor.run {
                    self.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func applyGroupChange(_ groupId: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.screen.updateGroup(groupId: groupId)
                await MainActor.run {
                    self.book = updated
                    self.updateHeader()
                }
            } catch {
                await MainActor.run {
                    self.presentRecoverableFailure(title: L10n.BookDetail.changeGroup, error: error)
                }
            }
        }
    }

    private func presentRecoverableFailure(
        title: String,
        error: Error,
        retry: (() -> Void)? = nil
    ) {
        if hasResolvedPrimaryContent {
            stateView.hide()
            showTransientMessage(error.userFacingMessage)
            return
        }
        stateView.showMessage(
            title: title,
            message: error.userFacingMessage,
            actionTitle: retry == nil ? nil : L10n.Common.retry,
            action: retry
        )
    }

    private var hasResolvedPrimaryContent: Bool {
        book != nil || chapters.isEmpty == false
    }

    private func configureDebugMarkerIfNeeded() {
    }

    private func updateDebugMarker(_ value: String) {
    }

    private func shouldIgnoreBookWatchUpdate(nextIsInBookshelf: Bool) -> Bool {
        guard isShelfMutationInFlight, let expectedShelfStateAfterMutation else {
            return false
        }
        guard nextIsInBookshelf != expectedShelfStateAfterMutation else {
            return false
        }
        return true
    }

    private func completeShelfMutation(finalState: Bool) {
        isShelfMutationInFlight = false
        expectedShelfStateAfterMutation = nil
        isInBookshelf = finalState
    }

    @objc private func handleBottomShelfTap() {
        if isInBookshelf && bookInfoDeleteAlertEnabled {
            let alert = UIAlertController(
                title: L10n.BookDetail.confirmRemoveTitle,
                message: L10n.BookDetail.confirmRemoveMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.BookDetail.removeFromShelf, style: .destructive) { [weak self] _ in
                self?.toggleBookshelfState()
            })
            alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
            present(alert, animated: true)
        } else {
            toggleBookshelfState()
        }
    }

    @objc private func handleBottomReadTap() {
        continueReading()
    }

    @objc private func handlePullToRefresh() {
        refreshInfo()
    }

    @objc private func handleMoreTapped() {
        let alert = UIAlertController(title: L10n.BookDetail.moreActions, message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: L10n.BookDetail.shareBook, style: .default) { [weak self] _ in
            self?.shareBook()
        })
        alert.addAction(UIAlertAction(title: L10n.BookDetail.copyBookUrl, style: .default) { [weak self] _ in
            UIPasteboard.general.string = self?.book?.bookUrl ?? self?.bookURL
            self?.showTransientMessage(L10n.BookDetail.copied)
        })
        if let tocUrl = book?.tocUrl, tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            alert.addAction(UIAlertAction(title: L10n.BookDetail.copyTocUrl, style: .default) { [weak self] _ in
                UIPasteboard.general.string = tocUrl
                self?.showTransientMessage(L10n.BookDetail.copied)
            })
        }

        // F24 置顶书籍
        if isInBookshelf {
            alert.addAction(UIAlertAction(title: L10n.BookDetail.pinToTop, style: .default) { [weak self] _ in
                self?.performPinToTop()
            })
        }

        // F29 允许更新开关
        if isInBookshelf {
            let canUpdate = book?.canUpdate ?? true
            let canUpdateTitle = canUpdate ? L10n.BookDetail.canUpdateOn : L10n.BookDetail.canUpdateOff
            alert.addAction(UIAlertAction(title: canUpdateTitle, style: .default) { [weak self] _ in
                self?.performToggleCanUpdate()
            })
        }

        // F31 清除缓存
        if isInBookshelf {
            alert.addAction(UIAlertAction(title: L10n.BookDetail.clearCache, style: .default) { [weak self] _ in
                self?.presentClearCacheConfirmation()
            })
        }

        // F37 编辑书源
        if let origin = book?.origin, origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, book?.isLocal != true {
            alert.addAction(UIAlertAction(title: L10n.BookDetail.editSource, style: .default) { [weak self] _ in
                self?.navigateToEditSource()
            })
        }

        // F20 编辑书籍信息
        alert.addAction(UIAlertAction(title: L10n.BookDetail.editBookInfo, style: .default) { [weak self] _ in
            self?.presentBookInfoEditor()
        })

        // F23 书源登录
        if let origin = book?.origin, origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, book?.isLocal != true {
            alert.addAction(UIAlertAction(title: L10n.BookDetail.loginSource, style: .default) { [weak self] _ in
                self?.executeSourceLogin()
            })
        }

        // F34 上传到WebDav
        if book?.isLocal == true, isInBookshelf {
            alert.addAction(UIAlertAction(title: L10n.WebDav.uploadBookTitle, style: .default) { [weak self] _ in
                self?.uploadBookToWebDav()
            })
        }

        let deleteAlertEnabled = bookInfoDeleteAlertEnabled
        let toggleTitle = deleteAlertEnabled ? L10n.BookDetail.deleteAlertToggleOn : L10n.BookDetail.deleteAlertToggleOff
        alert.addAction(UIAlertAction(title: toggleTitle, style: .default) { [weak self] _ in
            self?.setBookInfoDeleteAlert(enabled: !deleteAlertEnabled)
        })

        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - F24 置顶书籍

    private func setBookInfoDeleteAlert(enabled: Bool) {
        bookInfoDeleteAlertEnabled = enabled
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.setBookInfoDeleteAlert(enabled: enabled)
            } catch {
                await MainActor.run {
                    self.bookInfoDeleteAlertEnabled.toggle()
                    self.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func performPinToTop() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let pinned = try await self.screen.pinToTop()
                await MainActor.run {
                    self.book = pinned
                    self.updateHeader()
                    self.showTransientMessage(L10n.BookDetail.pinToTopDone)
                }
            } catch {
                await MainActor.run {
                    self.showTransientMessage(L10n.BookDetail.pinToTopFailed)
                }
            }
        }
    }

    // MARK: - F29 允许更新开关

    private func performToggleCanUpdate() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let toggled = try await self.screen.toggleCanUpdate()
                await MainActor.run {
                    self.book = toggled
                    self.updateHeader()
                    // 显示切换后的状态
                    let message = toggled.canUpdate ? L10n.BookDetail.canUpdateOn : L10n.BookDetail.canUpdateOff
                    self.showTransientMessage(message)
                }
            } catch {
                await MainActor.run {
                    self.showTransientMessage(L10n.BookDetail.canUpdateFailed)
                }
            }
        }
    }

    // MARK: - F31 清除缓存

    private func presentClearCacheConfirmation() {
        let alert = UIAlertController(
            title: L10n.BookDetail.clearCacheConfirmTitle,
            message: L10n.BookDetail.clearCacheConfirmMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
            self?.performClearCache()
        })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func performClearCache() {
        stateView.showLoading(message: L10n.BookDetail.clearCacheLoading)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.clearCache()
                await MainActor.run {
                    self.stateView.hide()
                    self.showTransientMessage(L10n.BookDetail.clearCacheDone)
                }
            } catch {
                await MainActor.run {
                    self.stateView.hide()
                    self.showTransientMessage(L10n.BookDetail.clearCacheFailed)
                }
            }
        }
    }

    private func shareBook() {
        var shareItems: [Any] = []
        if let name = book?.name {
            shareItems.append(name)
        }
        let url = book?.bookUrl ?? bookURL
        shareItems.append(url)
        let activityVC = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        present(activityVC, animated: true)
    }

    private func presentCoverFullscreen(image: UIImage?) {
        guard let image else { return }
        let fullscreenVC = CoverFullscreenViewController(image: image)
        present(fullscreenVC, animated: true)
    }

    // MARK: - F35 更换封面

    private func presentChangeCoverOptions() {
        let alert = UIAlertController(title: L10n.BookDetail.changeCover, message: nil, preferredStyle: .actionSheet)
        // F72: 封面搜索 — search covers across all sources
        if book?.isLocal != true {
            alert.addAction(UIAlertAction(title: L10n.BookDetail.changeCoverSource, style: .default) { [weak self] _ in
                self?.presentCoverSearchPicker()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.BookDetail.fromPhotoLibrary, style: .default) { [weak self] _ in
            self?.presentPhotoLibraryPicker()
        })
        alert.addAction(UIAlertAction(title: L10n.BookDetail.inputCoverUrl, style: .default) { [weak self] _ in
            self?.presentCoverUrlInput()
        })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func presentCoverSearchPicker() {
        let screenRef = screen
        let currentBookURL = bookURL
        let name = book?.name ?? ""
        let author = book?.author ?? ""
        let coverUrl = book?.displayCoverUrl
        let vc = ChangeCoverViewController(
            bookURL: currentBookURL,
            bookName: name,
            bookAuthor: author,
            originalCoverUrl: coverUrl,
            sessionFactory: { onResult, onProgress, onFinished in
                try await screenRef.createCoverSearchSession(
                    onResult: onResult,
                    onProgress: onProgress,
                    onFinished: onFinished
                )
            }
        )
        vc.delegate = self
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // MARK: - ChangeCoverDelegate

    func changeCoverDidSelect(_ coverUrl: String) {
        if coverUrl.isEmpty {
            // Reset to default cover (clear customCoverUrl)
            applyNewCoverUrl("")
        } else {
            applyNewCoverUrl(coverUrl)
        }
    }

    private func presentPhotoLibraryPicker() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        picker.allowsEditing = false
        present(picker, animated: true)
    }

    private func presentCoverUrlInput() {
        let alert = UIAlertController(title: L10n.BookDetail.inputCoverUrl, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L10n.BookDetail.inputCoverUrlPlaceholder
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self] _ in
            guard let urlText = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlText.isEmpty else { return }
            self?.applyNewCoverUrl(urlText)
        })
        present(alert, animated: true)
    }

    private func handlePickedCoverImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let fileName = "cover_\(UUID().uuidString).jpg"
        let coverDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let fileURL = coverDir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            applyNewCoverUrl(fileURL.absoluteString)
        } catch {
            showTransientMessage(L10n.BookDetail.changeCoverFailed)
        }
    }

    private func applyNewCoverUrl(_ coverUrl: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.screen.updateBookInfo(name: nil, author: nil, coverUrl: coverUrl, intro: nil)
                await MainActor.run {
                    self.book = updated
                    self.updateHeader()
                    self.showTransientMessage(L10n.BookDetail.changeCoverDone)
                }
            } catch {
                await MainActor.run {
                    self.showTransientMessage(L10n.BookDetail.changeCoverFailed)
                }
            }
        }
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        handlePickedCoverImage(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    // MARK: - F20 编辑书籍信息

    private func presentBookInfoEditor() {
        guard let book else { return }
        let editor = BookInfoEditViewController(
            book: book,
            saveBookInfo: { [screen] name, author, coverUrl, intro in
                try await screen.updateBookInfo(name: name, author: author, coverUrl: coverUrl, intro: intro)
            },
            onSave: { [weak self] updated in
                self?.book = updated
                self?.title = updated.name
                self?.scaffoldView.titleBarView.setTitle(updated.name)
                self?.updateHeader()
            }
        )
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    // MARK: - F23 书源登录

    private func executeSourceLogin() {
        guard let origin = book?.origin, origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            showTransientMessage(L10n.BookDetail.editSourceUnavailable)
            return
        }
        SourceLoginEntry.open(sourceURL: origin, from: self)
    }

    // MARK: - F34 上传到WebDav

    private func uploadBookToWebDav() {
        guard let book else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard try await self.screen.isWebDavConfigured() else {
                    await MainActor.run { self.showTransientMessage(L10n.WebDav.notConfigured) }
                    return
                }
                let bookUrl = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                guard bookUrl.isEmpty == false else {
                    await MainActor.run { self.showTransientMessage(L10n.WebDav.uploadBookFailed) }
                    return
                }
                _ = try await self.screen.uploadBookToWebDav(bookUrl: bookUrl)
                await MainActor.run {
                    self.showTransientMessage(L10n.WebDav.uploadBookSuccess)
                }
            } catch {
                await MainActor.run {
                    self.showTransientMessage(L10n.WebDav.uploadBookFailed)
                }
            }
        }
    }

    // MARK: - F37 编辑书源

    private func navigateToEditSource() {
        guard let origin = book?.origin, origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            showTransientMessage(L10n.BookDetail.editSourceUnavailable)
            return
        }
        let sourceManagementScreen = SourceManagementScreenAdapter()
        switch sourceManagementScreen.bootstrap() {
        case .success:
            let editor = BookSourceEditViewController(
                mode: .edit(origin),
                screen: sourceManagementScreen
            ).configuredForDrillDownPresentation()
            navigationController?.pushViewController(editor, animated: true)
        case .failure:
            showTransientMessage(L10n.BookDetail.editSourceUnavailable)
        }
    }
}

private final class CoverFullscreenViewController: UIViewController {
    private let coverImage: UIImage

    init(image: UIImage) {
        self.coverImage = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let imageView = UIImageView(image: coverImage)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapToDismiss))
        view.addGestureRecognizer(tapGesture)
    }

    @objc private func handleTapToDismiss() {
        dismiss(animated: true)
    }
}

private final class BookDetailScreenAdapter {
    private var observedBookURL: String
    private let bindings = ScreenBindingController(owner: "BookDetailScreen")
    private var facade: BookDetailFacade?
    private var settingsFacade: SettingsFacade?
    private var bookshelfFacade: BookshelfFacade?
    private var remoteBookFacade: RemoteBookFacade?
    private var lastBookSignature: String?
    private var lastChaptersSignature: String?

    var onBookChange: ((Book?) -> Void)?
    var onChaptersChange: (([BookChapter]) -> Void)?
    var onBookInfoDeleteAlertChange: ((Bool) -> Void)?

    init(bookURL: String) {
        self.observedBookURL = bookURL
    }

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()
        lastBookSignature = nil
        lastChaptersSignature = nil

        switch SharedRuntime.bookDetailFacade() {
        case .success(let facade):
            self.facade = facade
            switch SharedRuntime.settingsFacade() {
            case .success(let settings):
                self.settingsFacade = settings
            case .failure(let error):
                return .failure(error)
            }
            switch SharedRuntime.bookshelfFacade() {
            case .success(let bookshelf):
                self.bookshelfFacade = bookshelf
            case .failure(let error):
                return .failure(error)
            }
            switch SharedRuntime.remoteBookFacade() {
            case .success(let remoteBook):
                self.remoteBookFacade = remoteBook
            case .failure(let error):
                return .failure(error)
            }
            bind(to: observedBookURL)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindings.cancelAll()
    }

    func resolveInitialBook() async throws -> Book? {
        guard let facade else { throw runtimeNotReadyError() }
        let resolved = try await facade.resolveBookAsync(bookUrl: observedBookURL)
        if let resolved, resolved.bookUrl != observedBookURL {
            observedBookURL = resolved.bookUrl
            bind(to: observedBookURL)
        }
        return resolved
    }

    func refreshChapters() async throws -> BookDetailRefreshResult {
        guard let facade else { throw runtimeNotReadyError() }
        let result = try await facade.refreshChaptersAsync(bookUrl: observedBookURL)
        await MainActor.run {
            handleBook(result.book)
            handleChapters(result.chapters)
        }
        return result
    }

    func preloadChapters() async throws -> BookDetailRefreshResult {
        guard let facade else { throw runtimeNotReadyError() }
        let result = try await facade.preloadChaptersAsync(bookUrl: observedBookURL)
        await MainActor.run {
            handleChapters(result.chapters)
        }
        return result
    }

    func refreshInfo() async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        let result = try await facade.refreshInfoAsync(bookUrl: observedBookURL)
        await MainActor.run {
            handleBook(result)
        }
        return result
    }

    func addToBookshelf() async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        let added = try await facade.addToBookshelfAsync(bookUrl: observedBookURL)
        if added.bookUrl != observedBookURL {
            observedBookURL = added.bookUrl
            bind(to: observedBookURL)
        }
        return added
    }

    func removeFromBookshelf() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.removeFromBookshelfAsync(bookUrl: observedBookURL)
    }

    func updateGroup(groupId: Int64) async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.updateGroupAsync(bookUrl: observedBookURL, groupId: groupId)
    }

    func loadGroups() async throws -> [BookGroup] {
        guard let bookshelfFacade else { throw runtimeNotReadyError() }
        return try await bookshelfFacade.loadGroupsAsync()
    }

    func createGroup(name: String) async throws -> BookGroup {
        guard let bookshelfFacade else { throw runtimeNotReadyError() }
        return try await bookshelfFacade.saveGroupAsync(groupId: 0, name: name, show: true)
    }

    func isWebDavConfigured() async throws -> Bool {
        guard let settingsFacade else { throw runtimeNotReadyError() }
        return await settingsFacade.isWebDavConfiguredAsync()
    }

    func uploadBookToWebDav(bookUrl: String) async throws -> RemoteBook {
        guard let remoteBookFacade else { throw runtimeNotReadyError() }
        return try await remoteBookFacade.uploadShelfBookAsync(bookUrl: bookUrl)
    }

    func loadSourceChangeCandidates() async throws -> [BookSourceChangeCandidate] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadSourceChangeCandidatesAsync(bookUrl: observedBookURL)
    }

    func createSourceChangeSearchSession(
        onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
        onProgress: @escaping (SourceChangeSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> SourceChangeSearchSession {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.createSourceChangeSearchSessionAsync(
            bookUrl: observedBookURL,
            onCandidate: onCandidate,
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    func changeSource(candidateBookUrl: String, sourceUrl: String) async throws -> BookDetailRefreshResult {
        guard let facade else { throw runtimeNotReadyError() }
        let result = try await facade.changeSourceAsync(bookUrl: observedBookURL, candidateBookUrl: candidateBookUrl, sourceUrl: sourceUrl)
        observedBookURL = result.book.bookUrl
        bind(to: observedBookURL)
        return result
    }

    // F24 置顶书籍
    func pinToTop() async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.pinToTopAsync(bookUrl: observedBookURL)
    }

    // F29 切换允许更新
    func toggleCanUpdate() async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.toggleCanUpdateAsync(bookUrl: observedBookURL)
    }

    // F31 清除缓存
    func clearCache() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.clearCacheAsync(bookUrl: observedBookURL)
    }

    func setBookInfoDeleteAlert(enabled: Bool) async throws {
        guard let settingsFacade else { throw runtimeNotReadyError() }
        try await settingsFacade.setBookInfoDeleteAlertAsync(enabled: enabled)
    }

    // F20/F41-F49 编辑书籍信息
    func updateBookInfo(name: String?, author: String?, coverUrl: String?, intro: String?) async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.updateBookInfoAsync(bookUrl: observedBookURL, name: name, author: author, coverUrl: coverUrl, intro: intro)
    }

    // F72-F75 封面搜索
    func createCoverSearchSession(
        onResult: @escaping (CoverSearchResult) -> Void,
        onProgress: @escaping (CoverSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> CoverSearchSession {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.createCoverSearchSessionAsync(
            bookUrl: observedBookURL,
            onResult: onResult,
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    private func handleBook(_ book: Book?) {
        let signature: String
        if let book {
            signature = [
                book.bookUrl,
                book.name,
                book.author,
                "\(book.durChapterIndex)",
                "\(book.durChapterPos)",
                book.durChapterTitle ?? "",
                book.latestChapterTitle ?? "",
                "\(book.totalChapterNum)",
                "\(book.group)",
                book.customCoverUrl ?? "",
                book.customIntro ?? "",
            ].joined(separator: "|")
        } else {
            signature = "nil"
        }
        guard signature != lastBookSignature else { return }
        lastBookSignature = signature
        onBookChange?(book)
    }

    private func handleChapters(_ chapters: [BookChapter]) {
        let signature = chapters.map { "\($0.bookUrl)#\($0.index)#\($0.title)" }.joined(separator: "|")
        guard signature != lastChaptersSignature else { return }
        lastChaptersSignature = signature
        onChaptersChange?(chapters)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.BookDetail.unavailable]
        )
    }

    private func bind(to bookURL: String) {
        guard let facade else { return }
        bindings.replaceBinding(key: "book", with: facade.watchBook(bookUrl: bookURL) { [weak self] book in
            DispatchQueue.main.async {
                self?.handleBook(book)
            }
        })
        bindings.replaceBinding(key: "chapters", with: facade.watchChapters(bookUrl: bookURL) { [weak self] chapters in
            DispatchQueue.main.async {
                self?.handleChapters(chapters)
            }
        })
        if let settingsFacade {
            bindings.replaceBinding(key: "runtimeConfig", with: settingsFacade.watchRuntimeConfig { [weak self] runtimeConfig in
                DispatchQueue.main.async {
                    self?.onBookInfoDeleteAlertChange?(runtimeConfig.bookInfoDeleteAlert)
                }
            })
        }
    }
}
