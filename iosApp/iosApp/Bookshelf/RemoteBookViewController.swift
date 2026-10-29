import shared
import UIKit

@MainActor
final class RemoteBookViewController: UIViewController, NavigationCustomToolbarProviding, UITableViewDataSource,
    UITableViewDelegate
{
    private let screen: BookshelfScreenAdapter
    private let path: String?
    private let browser: Result<RemoteBookBrowserClient, Error>
    private lazy var operation = RemoteBookOperation(owner: self, screen: screen, browser: browser)
    private var hasLoaded = false
    private var remoteBooks: [RemoteBook] = []
    private let topBar = NavigationToolbarView()
    private let titleLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let backButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private let uploadButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let stateView = AndroidReplicaRemoteBookStateView()
    private var headerTitleText: String {
        path == nil ? L10n.Bookshelf.remoteTitle : path?.remoteBookLastPathComponentFallback ?? L10n.Bookshelf.remoteTitle
    }

    convenience init(screen: BookshelfScreenAdapter, path: String? = nil) {
        self.init(screen: screen, path: path, browser: Result { try RemoteBookBrowserClient() })
    }

    private init(screen: BookshelfScreenAdapter, path: String?, browser: Result<RemoteBookBrowserClient, Error>) {
        self.screen = screen
        self.path = path
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
        title = headerTitleText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        operation.onStateChanged = { [weak self] message, canCancel in
            self?.renderOperation(message: message, canCancel: canCancel)
        }
        operation.onBooksLoaded = { [weak self] books in
            guard let self else { return }
            self.hasLoaded = true
            self.remoteBooks = books.sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir { return lhs.isDir && !rhs.isDir }
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
            }
            self.renderBooks()
        }
        operation.onLoadFailed = { [weak self] message in
            guard let self else { return }
            self.tableView.isHidden = self.remoteBooks.isEmpty
            self.stateView.apply(self.remoteBooks.isEmpty ? .error(message) : .hidden)
        }
        operation.onReady = { [weak self] in self?.resumeBrowser() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.operation.appear()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true
            || navigationController?.topViewController !== self
        {
            operation.disappear()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        operation.ownerDidDisappear()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, isViewLoaded { operation.disappear() }
    }

    private func resumeBrowser() {
        guard !operation.isBusy else { return }
        if !hasLoaded || operation.needsReload { loadRemoteBooks() }
    }

    private func configureViews() {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        topBar.translatesAutoresizingMaskIntoConstraints = false

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        titleLabel.text = headerTitleText
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.lineBreakMode = .byTruncatingMiddle

        loadingIndicator.color = AndroidReplicaTheme.toolbarText
        loadingIndicator.hidesWhenStopped = true

        configureHeaderButton(refreshButton, imageName: "arrow.clockwise", action: #selector(refreshRemoteBooks))
        configureHeaderButton(uploadButton, imageName: "square.and.arrow.up", action: #selector(openUploadPicker))
        refreshButton.accessibilityLabel = L10n.Common.refresh
        uploadButton.isHidden = path != nil
        uploadButton.accessibilityLabel = L10n.Bookshelf.remoteUpload

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            AndroidReplicaRemoteBookCell.self, forCellReuseIdentifier: AndroidReplicaRemoteBookCell.reuseIdentifier)
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleRemoteBookLongPress(_:)))
        tableView.addGestureRecognizer(longPressRecognizer)

        stateView.onRetry = { [weak self] in
            self?.loadRemoteBooks()
        }

        view.addSubview(topBar)
        view.addSubview(tableView)
        view.addSubview(stateView)
        for item in [backButton, titleLabel, loadingIndicator, refreshButton, uploadButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }
        tableView.translatesAutoresizingMaskIntoConstraints = false
        stateView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 48),
            backButton.heightAnchor.constraint(equalToConstant: 48),

            uploadButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            uploadButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            uploadButton.widthAnchor.constraint(equalToConstant: 40),
            uploadButton.heightAnchor.constraint(equalToConstant: 40),

            refreshButton.trailingAnchor.constraint(
                equalTo: path == nil ? uploadButton.leadingAnchor : topBar.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 40),
            refreshButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: loadingIndicator.leadingAnchor, constant: -8),

            loadingIndicator.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -10),
            loadingIndicator.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stateView.topAnchor.constraint(equalTo: tableView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
        ])
    }

    private func configureHeaderButton(_ button: UIButton, imageName: String, action: Selector) {
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.backgroundColor = AndroidReplicaTheme.menuBackground
        button.layer.cornerRadius = 20
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func handleBack() {
        operation.disappear()
        navigationController?.popViewController(animated: true)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        remoteBooks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let remoteBook = remoteBooks[indexPath.row]
        let cell =
            tableView.dequeueReusableCell(withIdentifier: AndroidReplicaRemoteBookCell.reuseIdentifier, for: indexPath)
            as! AndroidReplicaRemoteBookCell
        cell.configure(remoteBook: remoteBook)
        cell.isUserInteractionEnabled = !operation.isBusy
        cell.onMore = { [weak self] in
            self?.showRemoteBookActionSheet(remoteBook)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard operation.canStart, remoteBooks.indices.contains(indexPath.row) else { return }
        let remoteBook = remoteBooks[indexPath.row]
        if remoteBook.isDir {
            navigationController?.pushViewController(
                RemoteBookViewController(screen: screen, path: remoteBook.path, browser: browser)
                    .configuredForDrillDownPresentation(),
                animated: true
            )
        } else {
            downloadAndImport(remoteBook)
        }
    }

    @objc private func handleRemoteBookLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        guard gestureRecognizer.state == .began, operation.canStart else { return }
        let location = gestureRecognizer.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: location),
            remoteBooks.indices.contains(indexPath.row)
        else {
            return
        }

        let remoteBook = remoteBooks[indexPath.row]
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        showRemoteBookActionSheet(remoteBook)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private func showRemoteBookActionSheet(_ remoteBook: RemoteBook) {
        guard operation.canStart else { return }
        let generation = operation.interactionGeneration
        var actions: [AndroidReplicaOptionSheetViewController.Option] = []
        if remoteBook.isDir == false {
            actions.append(
                AndroidReplicaOptionSheetViewController.Option(
                    title: L10n.Bookshelf.remoteDownload,
                    systemImage: "square.and.arrow.down",
                    isSelected: false
                ) { [weak self] in
                    guard let self, self.operation.acceptsInteraction(generation) else { return }
                    self.downloadAndImport(remoteBook)
                }
            )
        }
        actions.append(
            AndroidReplicaOptionSheetViewController.Option(
                title: L10n.Common.delete,
                systemImage: "trash",
                isSelected: false,
                isDestructive: true
            ) { [weak self] in
                guard let self, self.operation.acceptsInteraction(generation) else { return }
                self.confirmDelete(remoteBook)
            }
        )
        actions.append(
            AndroidReplicaOptionSheetViewController.Option(
                title: L10n.Common.cancel,
                systemImage: "chevron.down.circle",
                isSelected: false
            ) {}
        )

        let controller = AndroidReplicaOptionSheetViewController(
            titleText: remoteBook.filename,
            options: actions
        )
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: actions.count)
            ),
            animated: true
        )
    }

    @objc private func refreshRemoteBooks() {
        if operation.isBusy { operation.cancel() } else { loadRemoteBooks() }
    }

    @objc private func openUploadPicker() {
        guard path == nil else { return }
        operation.chooseUploads()
    }

    private func loadRemoteBooks() {
        guard operation.canStart else { return }
        tableView.isHidden = remoteBooks.isEmpty
        stateView.apply(.loading(L10n.Bookshelf.remoteLoading))
        operation.load(path: path)
    }

    private func downloadAndImport(_ remoteBook: RemoteBook) {
        operation.downloadAndImport(remoteBook, groupID: max(0, screen.currentSelectedGroupId))
    }

    private func confirmDelete(_ remoteBook: RemoteBook) {
        guard operation.canStart else { return }
        let generation = operation.interactionGeneration
        let controller = AndroidReplicaRemoteBookConfirmSheetViewController(
            titleText: L10n.Bookshelf.remoteDeleteTitle,
            messageText: String(format: L10n.Bookshelf.remoteDeleteMessage, remoteBook.filename),
            confirmTitle: L10n.Common.delete
        ) { [weak self] in
            guard let self, self.operation.acceptsInteraction(generation) else { return }
            self.operation.delete(remoteBook)
        }
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: 300),
            animated: true
        )
    }

    private func renderOperation(message: String?, canCancel: Bool) {
        let wasBusy = loadingIndicator.isAnimating
        if message != nil { loadingIndicator.startAnimating() } else { loadingIndicator.stopAnimating() }
        titleLabel.text = message ?? headerTitleText
        refreshButton.setImage(UIImage(systemName: message == nil ? "arrow.clockwise" : "stop.fill"), for: .normal)
        refreshButton.accessibilityLabel = message == nil ? L10n.Common.refresh : L10n.Common.cancel
        refreshButton.isEnabled = message == nil || canCancel
        refreshButton.alpha = refreshButton.isEnabled ? 1 : 0.45
        uploadButton.isEnabled = message == nil
        uploadButton.alpha = message == nil ? 1 : 0.45
        tableView.isUserInteractionEnabled = message == nil
        tableView.accessibilityElementsHidden = message != nil
        stateView.isUserInteractionEnabled = message == nil
        if wasBusy != (message != nil) { tableView.reloadData() }
        if message == nil { renderBooks() }
    }

    private func renderBooks() {
        tableView.reloadData()
        tableView.isHidden = remoteBooks.isEmpty
        stateView.apply(remoteBooks.isEmpty ? .empty(L10n.Bookshelf.remoteEmpty) : .hidden)
    }
}
