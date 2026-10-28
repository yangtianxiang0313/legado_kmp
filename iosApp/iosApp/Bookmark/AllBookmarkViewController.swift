import UIKit
import shared

/// AllBookmarkActivity, BookmarkAdapter and BookmarkDecoration at Legado 5f5d314.
final class AllBookmarkViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private struct BookGroup {
        let bookName: String
        let bookAuthor: String
        var bookmarks: [Bookmark]

        var title: String { "\(bookName)(\(bookAuthor))" }
    }

    private let screen = AllBookmarkScreenAdapter()
    private let topBar = AllBookmarkToolbarView(frame: .zero)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let overflowMenu = SearchOverflowMenuView()
    private let errorLabel = UILabel()
    private var bookmarks: [Bookmark] = []
    private var groups: [BookGroup] = []
    private var exportTask: Task<Void, Never>?
    private var exportGeneration = UUID()
    private var openTask: Task<Void, Never>?
    private var openGeneration = UUID()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AllBookmarkToolbarView.title
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        bootstrapDependencies()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        overflowMenu.dismiss()
        cancelOpeningBookmark()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelExport()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // applyNavigationBarPadding: the list scrolls behind the home indicator.
        tableView.contentInset.bottom = view.safeAreaInsets.bottom
        tableView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
    }

    deinit {
        exportTask?.cancel()
        openTask?.cancel()
        screen.unbind()
    }

    private func configureViews() {
        topBar.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        topBar.moreButton.addTarget(self, action: #selector(showMoreActions), for: .touchUpInside)

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionHeaderHeight = AndroidReplicaBookmarkSectionHeader.height
        tableView.sectionFooterHeight = .leastNormalMagnitude
        tableView.estimatedSectionFooterHeight = 0
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.contentInset.bottom = view.safeAreaInsets.bottom
        tableView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            AndroidReplicaAllBookmarkCell.self, forCellReuseIdentifier: AndroidReplicaAllBookmarkCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "all_bookmark_table"

        errorLabel.textAlignment = .center
        errorLabel.textColor = AndroidReplicaTheme.secondaryText
        errorLabel.font = .systemFont(ofSize: 14)
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "all_bookmark_load_error"
        overflowMenu.accessibilityIdentifier = "all_bookmark_overflow_menu"

        for item in [topBar, tableView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func bootstrapDependencies() {
        screen.onBookmarksChange = { [weak self] bookmarks in
            self?.updateData(bookmarks)
        }
        screen.onLoadFailure = { [weak self] error in
            self?.showLoadFailure(error)
        }
        if case .failure(let error) = screen.bootstrap() {
            showLoadFailure(error)
        }
    }

    private func showLoadFailure(_ error: Error) {
        errorLabel.text = error.userFacingMessage
        tableView.backgroundView = errorLabel
    }

    private func updateData(_ bookmarks: [Bookmark]) {
        self.bookmarks = bookmarks
        // The shared stream is time-ordered; Android BookmarkDao.flowAll sorts
        // by localized book/author, chapter and position before decorating runs.
        let ordered = bookmarks.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            for (a, b) in [(left.bookName, right.bookName), (left.bookAuthor, right.bookAuthor)] where a != b {
                let comparison = a.localizedCompare(b)
                return comparison == .orderedSame ? a < b : comparison == .orderedAscending
            }
            if left.chapterIndex != right.chapterIndex { return left.chapterIndex < right.chapterIndex }
            if left.chapterPos != right.chapterPos { return left.chapterPos < right.chapterPos }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var result: [BookGroup] = []
        for bookmark in ordered {
            if let last = result.last, last.bookName == bookmark.bookName, last.bookAuthor == bookmark.bookAuthor {
                result[result.count - 1].bookmarks.append(bookmark)
            } else {
                result.append(
                    BookGroup(bookName: bookmark.bookName, bookAuthor: bookmark.bookAuthor, bookmarks: [bookmark]))
            }
        }
        groups = result
        // The Android empty state is the empty RecyclerView, not a menu item.
        tableView.backgroundView = nil
        tableView.reloadData()
    }

    @objc private func handleBack() {
        overflowMenu.dismiss()
        cancelExport()
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func showMoreActions() {
        guard exportTask == nil, presentedViewController == nil else { return }
        overflowMenu.show(
            in: view, anchor: topBar.moreButton,
            items: [
                .init(
                    id: "export",
                    title: NSLocalizedString("all_bookmark.android.export", value: "导出", comment: "Legado export")),
                .init(
                    id: "export_md",
                    title: NSLocalizedString(
                        "all_bookmark.android.export_md", value: "导出(MD)", comment: "Legado export_md")),
            ]
        ) { [weak self] id in
            self?.exportBookmarks(markdown: id == "export_md")
        }
    }

    private func exportBookmarks(markdown: Bool) {
        guard exportTask == nil, presentedViewController == nil else { return }
        let generation = UUID()
        exportGeneration = generation
        topBar.moreButton.isEnabled = false
        exportTask = Task { @MainActor [weak self, screen] in
            defer {
                if self?.exportGeneration == generation {
                    self?.exportTask = nil
                    self?.topBar.moreButton.isEnabled = true
                }
            }
            do {
                let text = try await screen.exportBookmarks(markdown: markdown)
                try Task.checkCancellation()
                guard let self, self.exportGeneration == generation,
                    self.viewIfLoaded?.window != nil, !self.isBeingDismissed,
                    self.presentedViewController == nil
                else { return }
                try self.shareText(text, markdown: markdown)
            } catch {
                guard !Task.isCancelled, let self, self.exportGeneration == generation,
                    self.viewIfLoaded?.window != nil
                else { return }
                self.showTransientMessage("\(L10n.AllBookmark.exportFailed): \(error.userFacingMessage)")
            }
        }
    }

    private func shareText(_ text: String, markdown: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyMMddHHmmss"
            let fileName = "bookmark-\(formatter.string(from: Date())).\(markdown ? "md" : "json")"
            let url = directory.appendingPathComponent(fileName)
            try text.write(to: url, atomically: true, encoding: .utf8)
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = topBar.moreButton
            controller.popoverPresentationController?.sourceRect = topBar.moreButton.bounds
            controller.completionWithItemsHandler = { [weak self] _, _, _, error in
                try? FileManager.default.removeItem(at: directory)
                guard let error else { return }
                DispatchQueue.main.async {
                    self?.showTransientMessage("\(L10n.AllBookmark.exportFailed): \(error.userFacingMessage)")
                }
            }
            present(controller, animated: true)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func cancelExport() {
        exportGeneration = UUID()
        exportTask?.cancel()
        exportTask = nil
        topBar.moreButton.isEnabled = true
    }

    private func cancelOpeningBookmark() {
        openGeneration = UUID()
        openTask?.cancel()
        openTask = nil
    }

    private func openForReading(_ bookmark: Bookmark) {
        guard openTask == nil, presentedViewController == nil, canPerformNavigationAction else { return }
        cancelExport()
        let generation = UUID()
        openGeneration = generation
        weak var window = view.window
        openTask = Task { @MainActor [weak self] in
            defer { if self?.openGeneration == generation { self?.openTask = nil } }
            do {
                let book = try await BookmarkReadingResolver.resolve(bookmark)
                try Task.checkCancellation()
                guard let self, self.openGeneration == generation, self.view.window === window,
                    let window, AppLockManager.shared.isUnlocked(in: window),
                    self.navigationController?.topViewController === self, self.presentedViewController == nil,
                    self.canPerformNavigationAction
                else { return }
                self.openTask = nil
                BookReadingDestination.open(
                    book, from: self, chapterIndex: Int(bookmark.chapterIndex), chapterPosition: Int(bookmark.chapterPos))
            } catch is CancellationError {} catch {
                guard let self, self.openGeneration == generation, self.view.window === window,
                    self.navigationController?.topViewController === self
                else { return }
                self.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func presentBookmarkEditor(_ bookmark: Bookmark) {
        guard presentedViewController == nil else { return }
        cancelExport()
        let controller = ReaderTocBookmarkEditorViewController(
            bookmark: bookmark,
            onSave: { @MainActor [weak self, screen] bookText, content in
                let updated = ReaderTocBookmarkEditCoordinator.updatedBookmark(
                    bookmark, bookText: bookText, content: content)
                try await screen.updateBookmark(updated)
                guard let self else { return }
                var next = self.bookmarks
                if let index = next.firstIndex(where: { $0.time == updated.time }) {
                    next[index] = updated
                } else {
                    next.append(updated)
                }
                self.updateData(next)
            },
            onDelete: { @MainActor [weak self, screen] in
                try await screen.deleteBookmark(bookmark)
                guard let self else { return }
                self.updateData(self.bookmarks.filter { $0.time != bookmark.time })
            }
        )
        controller.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        present(controller, animated: true)
    }

    func numberOfSections(in _: UITableView) -> Int { groups.count }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups[section].bookmarks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: AndroidReplicaAllBookmarkCell.reuseIdentifier,
                for: indexPath
            ) as! AndroidReplicaAllBookmarkCell
        cell.configure(with: groups[indexPath.section].bookmarks[indexPath.row])
        cell.accessibilityIdentifier = "all_bookmark_cell"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        presentBookmarkEditor(groups[indexPath.section].bookmarks[indexPath.row])
    }

    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard groups.indices.contains(indexPath.section), groups[indexPath.section].bookmarks.indices.contains(indexPath.row)
        else {
            return nil
        }
        let bookmark = groups[indexPath.section].bookmarks[indexPath.row]
        return UIContextMenuConfiguration(identifier: NSNumber(value: bookmark.time), previewProvider: nil) { [weak self] _ in
            let read = UIAction(title: "开始阅读", image: UIImage(systemName: "book")) { [weak self] _ in
                self?.openForReading(bookmark)
            }
            let edit = UIAction(title: L10n.Common.edit, image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.presentBookmarkEditor(bookmark)
            }
            return UIMenu(children: [read, edit])
        }
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        AndroidReplicaBookmarkSectionHeader(title: groups[section].title)
    }

    func tableView(_: UITableView, heightForHeaderInSection _: Int) -> CGFloat {
        AndroidReplicaBookmarkSectionHeader.height
    }

    func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat {
        .leastNormalMagnitude
    }
}
