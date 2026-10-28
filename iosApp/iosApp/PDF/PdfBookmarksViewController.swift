import UIKit
import shared

@MainActor
final class PdfBookmarksViewController: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    var onSelection: ((Bookmark) -> Void)?
    var canSubmit: (() -> Bool)? {
        didSet {
            deliveryID = nil
            acceptedConfirmationID = nil
            pendingDeletion = nil
            cancelRequests()
            needsReload = true
            if isViewLoaded { refreshAvailability() }
        }
    }

    private enum SortOrder: String, CaseIterable {
        case page = "按页码"
        case time = "按时间"
    }

    private let client: PdfBookmarkClient
    private let currentPage: Int
    private let excerpt: String
    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let emptyLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let sortButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    private lazy var presentationGuard = PdfBookmarkPresentationGuard(controller: self)
    private var bookmarks: [Bookmark] = []
    private var rows: [Bookmark] = []
    private var sortOrder = SortOrder.page
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var loadID = UUID()
    private var actionID = UUID()
    private var deliveryID: UUID?
    private var editorID: UUID?
    private weak var activeEditor: ReaderTocBookmarkEditorViewController?
    private var confirmationID: UUID?
    private var acceptedConfirmationID: UUID?
    private var pendingDeletion: Bookmark?
    private weak var confirmation: UIAlertController?
    private var refreshTimer: Timer?
    private var isVisible = false
    private var isClosing = false
    private var isCheckingSubmission = false
    private var needsReload = true
    private var hasLoaded = false
    private var message: String?
    private var retry: (() -> Void)?

    init(client: PdfBookmarkClient, currentPage: Int, excerpt: String) {
        self.client = client
        self.currentPage = currentPage
        self.excerpt = excerpt
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("Use init(client:currentPage:excerpt:)") }

    deinit {
        loadTask?.cancel()
        actionTask?.cancel()
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书签"
        configureViews()
        configureNavigation()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didActivateNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeKeyNotification, .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        isClosing = false
        needsReload = true
        presentationGuard.bindIfNeeded()
        startRefreshTimer()
        refreshAvailability()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        cancelRequests()
        view.endEditing(true)
        // Presenting an editor is not retirement; its submission guard remains bound to the original host.
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            isClosing = true
            editorID = nil
            confirmationID = nil
            acceptedConfirmationID = nil
            pendingDeletion = nil
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isClosing || (activeEditor == nil && confirmation == nil) {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true
        {
            tableView.reloadData()
        }
    }

    private func configureNavigation() {
        configureButton(addButton, symbol: "plus", title: "添加书签", action: #selector(addBookmark))
        configureButton(sortButton, symbol: "arrow.up.arrow.down", title: "书签排序", action: nil)
        configureButton(closeButton, symbol: "xmark", title: "关闭书签", action: #selector(close))
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                completion(
                    SortOrder.allCases.map { order in
                        UIAction(
                            title: order.rawValue, image: UIImage(systemName: order == .page ? "doc" : "clock"),
                            state: self.sortOrder == order ? .on : .off
                        ) { [weak self] _ in
                            guard let self, self.canInteract else { return }
                            self.sortOrder = order
                            self.applyFilter()
                        }
                    })
            }
        ])
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: addButton), UIBarButtonItem(customView: sortButton)]
        if navigationController?.viewControllers.first === self || navigationController == nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(customView: closeButton)
        }
    }

    private func configureButton(_ button: UIButton, symbol: String, title: String, action: Selector?) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = AndroidReplicaTheme.accent
        button.accessibilityLabel = title
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
    }

    private func configureViews() {
        view.accessibilityIdentifier = "pdf.bookmarks"
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = "搜索摘录、备注或章名"
        searchBar.delegate = self
        searchBar.searchTextField.autocorrectionType = .no
        searchBar.searchTextField.autocapitalizationType = .none
        searchBar.searchTextField.spellCheckingType = .no
        searchBar.searchTextField.accessibilityIdentifier = "pdf.bookmarks.query"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "pdf.bookmarks.status"
        spinner.hidesWhenStopped = true
        configureButton(retryButton, symbol: "arrow.clockwise", title: "重试", action: #selector(retryOperation))
        let status = UIStackView(arrangedSubviews: [spinner, statusLabel, retryButton])
        status.alignment = .center
        status.spacing = 8
        status.isLayoutMarginsRelativeArrangement = true
        status.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 8)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 112
        tableView.keyboardDismissMode = .interactive
        tableView.tableFooterView = UIView()
        tableView.register(PdfBookmarkCell.self, forCellReuseIdentifier: PdfBookmarkCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "pdf.bookmarks.list"
        refreshControl.addTarget(self, action: #selector(refreshBookmarks), for: .valueChanged)
        tableView.refreshControl = refreshControl
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = "pdf.bookmarks.empty"
        let empty = UIView()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: empty.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: empty.trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
        ])
        tableView.backgroundView = empty
        let stack = UIStackView(arrangedSubviews: [searchBar, status, tableView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        refreshPalette()
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        searchBar.tintColor = AndroidReplicaTheme.accent
        searchBar.searchTextField.textColor = AndroidReplicaTheme.primaryText
        for button in [addButton, sortButton, closeButton, retryButton] { button.tintColor = AndroidReplicaTheme.accent }
        tableView.reloadData()
    }

    private var permitsSubmission: Bool {
        guard !isCheckingSubmission else { return false }
        isCheckingSubmission = true
        defer { isCheckingSubmission = false }
        return canSubmit?() ?? true
    }

    private var canInteract: Bool {
        isVisible && !isClosing && presentationGuard.allows() && permitsSubmission && presentationGuard.allows()
    }

    private func canEdit(_ token: UUID, editor: ReaderTocBookmarkEditorViewController) -> Bool {
        !isClosing && editorID == token && activeEditor === editor
            && presentationGuard.allows(cover: editor) && permitsSubmission
            && editorID == token && presentationGuard.allows(cover: editor)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.2, target: RefreshTarget(owner: self),
            selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshAvailability() {
        guard !isClosing else { return }
        if editorID != nil, activeEditor?.presentingViewController == nil, activeEditor?.isBeingPresented != true {
            editorID = nil
            activeEditor = nil
            needsReload = true
        }
        if acceptedConfirmationID != nil, confirmation?.presentingViewController == nil,
            confirmation?.isBeingPresented != true, isVisible
        {
            let bookmark = pendingDeletion
            let accepted = acceptedConfirmationID == confirmationID
            acceptedConfirmationID = nil
            pendingDeletion = nil
            confirmationID = nil
            confirmation = nil
            if accepted, let bookmark, canInteract {
                delete(bookmark)
                return
            }
        }
        if confirmationID != nil, acceptedConfirmationID == nil,
            confirmation?.presentingViewController == nil, confirmation?.isBeingPresented != true
        {
            confirmationID = nil
            confirmation = nil
        }
        let allowed = canInteract
        if !allowed { cancelRequests() }
        addButton.isEnabled = allowed && actionTask == nil && (0..<max(client.pageCount, 0)).contains(currentPage)
        sortButton.isEnabled = allowed && actionTask == nil
        retryButton.isEnabled = allowed && actionTask == nil
        if allowed && needsReload && loadTask == nil && actionTask == nil { loadBookmarks() }
    }

    private func cancelRequests() {
        if loadTask != nil { needsReload = true }
        loadID = UUID()
        actionID = UUID()
        loadTask?.cancel()
        actionTask?.cancel()
        loadTask = nil
        actionTask = nil
        refreshControl.endRefreshing()
        spinner.stopAnimating()
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIWindow.didResignKeyNotification, .appLockWillCover:
            deliveryID = nil
            acceptedConfirmationID = nil
            pendingDeletion = nil
            cancelRequests()
            view.endEditing(true)
        default:
            needsReload = true
            break
        }
        refreshAvailability()
    }

    @objc private func refreshBookmarks() {
        guard canInteract, actionTask == nil else { refreshControl.endRefreshing(); return }
        needsReload = true
        loadBookmarks()
    }

    private func loadBookmarks() {
        guard canInteract, actionTask == nil else { return }
        loadTask?.cancel()
        let token = UUID()
        loadID = token
        needsReload = false
        message = nil
        retry = nil
        loadTask = Task { @MainActor [weak self, client] in
            do {
                try Task.checkCancellation()
                guard self?.loadID == token, self?.canInteract == true else { return }
                let result = try await client.getBookmarks()
                try Task.checkCancellation()
                guard let self, self.loadID == token else { return }
                self.loadTask = nil
                guard self.canInteract else { self.needsReload = true; return }
                self.bookmarks = result
                self.hasLoaded = true
                self.refreshControl.endRefreshing()
                self.applyFilter()
            } catch {
                guard let self, self.loadID == token else { return }
                self.loadTask = nil
                self.refreshControl.endRefreshing()
                guard !Task.isCancelled, self.canInteract else { self.needsReload = true; return }
                self.showFailure(error) { [weak self] in self?.refreshBookmarks() }
            }
        }
        render()
    }

    private func applyFilter() {
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rows = bookmarks.filter { bookmark in
            query.isEmpty
                || [bookmark.bookText, bookmark.content, bookmark.chapterName].contains {
                    $0.localizedStandardContains(query)
                }
        }.sorted { left, right in
            if sortOrder == .time, left.time != right.time { return left.time > right.time }
            if left.chapterIndex != right.chapterIndex { return left.chapterIndex < right.chapterIndex }
            if left.chapterPos != right.chapterPos { return left.chapterPos < right.chapterPos }
            return left.time > right.time
        }
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        if loadTask != nil || actionTask != nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        statusLabel.text = message ?? (loadTask != nil ? "正在加载书签" : "\(rows.count) 个书签")
        retryButton.isHidden = retry == nil
        if !rows.isEmpty || loadTask != nil {
            emptyLabel.text = nil
        } else if let message, !hasLoaded {
            emptyLabel.text = message
        } else if hasLoaded {
            emptyLabel.text = bookmarks.isEmpty ? "暂无书签" : "未找到匹配书签"
        } else {
            emptyLabel.text = nil
        }
        addButton.isEnabled = canInteract && actionTask == nil && (0..<max(client.pageCount, 0)).contains(currentPage)
        sortButton.isEnabled = canInteract && actionTask == nil
    }

    private func showFailure(_ error: Error, retry: @escaping () -> Void) {
        message = error.userFacingMessage.isEmpty ? "操作失败，请重试" : error.userFacingMessage
        self.retry = retry
        render()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    @objc private func retryOperation() {
        guard canInteract, actionTask == nil else { return }
        retry?()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard searchBar.searchTextField.markedTextRange == nil else { return }
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard canInteract, searchBar.searchTextField.markedTextRange == nil else { return }
        applyFilter()
        searchBar.resignFirstResponder()
    }

    @objc private func addBookmark() {
        guard canInteract, actionTask == nil, (0..<max(client.pageCount, 0)).contains(currentPage) else { return }
        cancelRequests()
        let token = UUID()
        actionID = token
        actionTask = Task { @MainActor [weak self, client, currentPage, excerpt] in
            do {
                try Task.checkCancellation()
                guard self?.actionID == token, self?.canInteract == true else { return }
                let draft = try await client.makeDraft(pageIndex: currentPage, excerpt: excerpt)
                try Task.checkCancellation()
                guard let self, self.actionID == token else { return }
                self.actionTask = nil
                guard self.canInteract else { return }
                self.presentEditor(draft, isNew: true)
            } catch {
                guard let self, self.actionID == token else { return }
                self.actionTask = nil
                guard !Task.isCancelled, self.canInteract else { return }
                self.showFailure(error) { [weak self] in self?.addBookmark() }
            }
        }
        render()
    }

    private func presentEditor(_ bookmark: Bookmark, isNew: Bool) {
        guard canInteract, actionTask == nil else { return }
        cancelRequests()
        view.endEditing(true)
        let token = UUID()
        editorID = token
        let editor = ReaderTocBookmarkEditorViewController(
            bookmark: bookmark,
            onSave: { @MainActor [weak self, client] bookText, note in
                guard let self, let editor = self.activeEditor, self.canEdit(token, editor: editor) else {
                    throw CancellationError()
                }
                // The editor owns an accepted write. It alone decides whether its own completion may dismiss it.
                let updated = try await client.save(bookmark, bookText: bookText, note: note, isNew: isNew)
                self.needsReload = true
                guard self.editorID == token, self.activeEditor === editor else { return }
                if let index = self.bookmarks.firstIndex(where: { $0.time == updated.time }) {
                    self.bookmarks[index] = updated
                } else {
                    self.bookmarks.append(updated)
                }
            })
        activeEditor = editor
        editor.canSubmit = { [weak self, weak editor] in
            guard let self, let editor else { return false }
            return self.canEdit(token, editor: editor)
        }
        editor.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        present(editor, animated: true)
        render()
    }

    private func confirmDeletion(_ bookmark: Bookmark) {
        guard canInteract, actionTask == nil else { return }
        cancelRequests()
        view.endEditing(true)
        let token = UUID()
        confirmationID = token
        let alert = UIAlertController(
            title: L10n.Reader.bookmarkDeleteTitle, message: L10n.AllBookmark.deleteConfirm, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.delete, style: .destructive) { [weak self, weak alert] _ in
                guard let self, let alert, self.confirmationID == token, self.confirmation === alert,
                    !self.isClosing, self.permitsSubmission,
                    let presenter = alert.presentingViewController, presenter.presentedViewController === alert
                else { return }
                self.acceptedConfirmationID = token
                self.pendingDeletion = bookmark
                // UIAlertController owns dismissal. The availability tick submits only after this exact alert has left.
            })
        confirmation = alert
        present(alert, animated: true)
    }

    private func delete(_ bookmark: Bookmark) {
        guard canInteract, actionTask == nil, bookmarks.contains(where: { $0.time == bookmark.time }) else { return }
        cancelRequests()
        let token = UUID()
        actionID = token
        actionTask = Task { @MainActor [weak self, client] in
            do {
                try Task.checkCancellation()
                guard self?.actionID == token, self?.canInteract == true else { return }
                try await client.delete(bookmark)
                guard let self else { return }
                self.needsReload = true
                guard !Task.isCancelled, self.actionID == token else { return }
                self.actionTask = nil
                guard self.canInteract else { return }
                self.bookmarks.removeAll { $0.time == bookmark.time }
                self.applyFilter()
                self.refreshAvailability()
            } catch {
                guard let self else { return }
                self.needsReload = true
                guard !Task.isCancelled, self.actionID == token else { return }
                self.actionTask = nil
                guard self.canInteract else { return }
                self.needsReload = false
                self.showFailure(error) { [weak self] in self?.refreshBookmarks() }
            }
        }
        render()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(withIdentifier: PdfBookmarkCell.reuseIdentifier, for: indexPath)
                as? PdfBookmarkCell
        else {
            return UITableViewCell()
        }
        let bookmark = rows[indexPath.row]
        let date = dateFormatter.string(from: Date(timeIntervalSince1970: Double(bookmark.time) / 1000))
        cell.configure(bookmark: bookmark, currentPage: currentPage, pageCount: client.pageCount, date: date)
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.Common.edit) { [weak self] _ in
                guard let self, self.canInteract, self.actionTask == nil else { return false }
                self.presentEditor(bookmark, isNew: false)
                return true
            },
            UIAccessibilityCustomAction(name: L10n.Common.delete) { [weak self] _ in
                guard let self, self.canInteract, self.actionTask == nil else { return false }
                self.confirmDeletion(bookmark)
                return true
            },
        ]
        return cell
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard canInteract, actionTask == nil, rows.indices.contains(indexPath.row) else { return nil }
        let bookmark = rows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: L10n.Common.edit, image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                    self?.presentEditor(bookmark, isNew: false)
                },
                UIAction(title: L10n.Common.delete, image: UIImage(systemName: "trash"), attributes: .destructive) {
                    [weak self] _ in
                    self?.confirmDeletion(bookmark)
                },
            ])
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        select(rows[indexPath.row])
    }

    private func select(_ bookmark: Bookmark) {
        guard canInteract, actionTask == nil, bookmark.chapterPos == 0,
            (0..<max(client.pageCount, 0)).contains(Int(bookmark.chapterIndex))
        else { return }
        cancelRequests()
        let token = UUID()
        actionID = token
        actionTask = Task { @MainActor [weak self, client] in
            do {
                try Task.checkCancellation()
                guard self?.actionID == token, self?.canInteract == true else { return }
                let page = try await client.page(for: bookmark)
                try Task.checkCancellation()
                guard let self, self.actionID == token else { return }
                self.actionTask = nil
                guard self.canInteract, (0..<max(client.pageCount, 0)).contains(page),
                    self.bookmarks.contains(where: { $0.time == bookmark.time })
                else { return }
                self.deliverSelection(bookmark)
            } catch {
                guard let self, self.actionID == token else { return }
                self.actionTask = nil
                guard !Task.isCancelled, self.canInteract else { return }
                self.showFailure(error) { [weak self] in self?.select(bookmark) }
            }
        }
        render()
    }

    private func deliverSelection(_ bookmark: Bookmark) {
        guard canInteract, let owner = presentationOwner, let presenter = owner.presentingViewController,
            presenter.presentedViewController === owner, owner.presentedViewController == nil,
            owner.transitionCoordinator == nil
        else { return }
        let token = UUID()
        let source = presentationGuard.deliverySource(from: presenter)
        deliveryID = token
        let callback = onSelection
        isClosing = true
        cancelRequests()
        view.endEditing(true)
        owner.dismiss(animated: true) { [self, weak presenter, weak owner, weak source] in
            guard deliveryID == token, let presenter, let source, owner?.presentingViewController == nil,
                permitsSubmission, deliveryID == token,
                presentationGuard.allowsDelivery(from: presenter, expectedSource: source)
            else { return }
            deliveryID = nil
            callback?(bookmark)
        }
    }

    private var presentationOwner: UIViewController? {
        var owner: UIViewController = self
        while let parent = owner.parent { owner = parent }
        return owner.presentingViewController == nil ? nil : owner
    }

    @objc private func close() {
        guard canInteract, let owner = presentationOwner, owner.presentedViewController == nil else { return }
        deliveryID = nil
        isClosing = true
        cancelRequests()
        view.endEditing(true)
        owner.dismiss(animated: true)
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: PdfBookmarksViewController?

        init(owner: PdfBookmarksViewController) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else { timer.invalidate(); return }
            owner.refreshAvailability()
        }
    }
}
