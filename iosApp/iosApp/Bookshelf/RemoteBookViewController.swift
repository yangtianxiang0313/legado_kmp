import shared
import UIKit
import UniformTypeIdentifiers

final class RemoteBookViewController: UIViewController, NavigationCustomToolbarProviding, UITableViewDataSource,
    UITableViewDelegate, UIDocumentPickerDelegate
{
    private let screen: BookshelfScreenAdapter
    private let path: String?
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

    init(screen: BookshelfScreenAdapter, path: String? = nil) {
        self.screen = screen
        self.path = path
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
        loadRemoteBooks()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
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
        tableView.register(AndroidReplicaRemoteBookCell.self, forCellReuseIdentifier: AndroidReplicaRemoteBookCell.reuseIdentifier)
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

            refreshButton.trailingAnchor.constraint(equalTo: path == nil ? uploadButton.leadingAnchor : topBar.trailingAnchor, constant: -8),
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
        navigationController?.popViewController(animated: true)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        remoteBooks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let remoteBook = remoteBooks[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: AndroidReplicaRemoteBookCell.reuseIdentifier, for: indexPath) as! AndroidReplicaRemoteBookCell
        cell.configure(remoteBook: remoteBook)
        cell.onMore = { [weak self] in
            self?.showRemoteBookActionSheet(remoteBook)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let remoteBook = remoteBooks[indexPath.row]
        if remoteBook.isDir {
            navigationController?.pushViewController(
                RemoteBookViewController(screen: screen, path: remoteBook.path).configuredForDrillDownPresentation(),
                animated: true
            )
        } else {
            downloadAndImport(remoteBook)
        }
    }

    @objc private func handleRemoteBookLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        guard gestureRecognizer.state == .began else { return }
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
        var actions: [AndroidReplicaOptionSheetViewController.Option] = []
        if remoteBook.isDir == false {
            actions.append(
                AndroidReplicaOptionSheetViewController.Option(
                    title: L10n.Bookshelf.remoteDownload,
                    systemImage: "square.and.arrow.down",
                    isSelected: false
                ) { [weak self] in
                    self?.downloadAndImport(remoteBook)
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
                self?.confirmDelete(remoteBook)
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
        loadRemoteBooks()
    }

    @objc private func openUploadPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .text, .epub], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        uploadLocalBooks(from: urls)
    }

    private func loadRemoteBooks() {
        showLoading(message: L10n.Bookshelf.remoteLoading)
        tableView.isHidden = remoteBooks.isEmpty
        stateView.apply(.loading(L10n.Bookshelf.remoteLoading))
        Task { [weak self] in
            guard let self else { return }
            do {
                let books = try await self.screen.loadRemoteBooks(path: self.path)
                await MainActor.run {
                    self.remoteBooks = books.sorted { lhs, rhs in
                        if lhs.isDir != rhs.isDir { return lhs.isDir && !rhs.isDir }
                        return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
                    }
                    self.hideLoading()
                    self.tableView.reloadData()
                    if self.remoteBooks.isEmpty {
                        self.tableView.isHidden = true
                        self.stateView.apply(.empty(L10n.Bookshelf.remoteEmpty))
                    } else {
                        self.tableView.isHidden = false
                        self.stateView.apply(.hidden)
                    }
                }
            } catch {
                await MainActor.run {
                    self.hideLoading()
                    self.tableView.isHidden = self.remoteBooks.isEmpty
                    self.stateView.apply(self.remoteBooks.isEmpty ? .error(error.userFacingMessage) : .hidden)
                    self.showMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func downloadAndImport(_ remoteBook: RemoteBook) {
        showLoading(message: L10n.Bookshelf.remoteDownloading)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.screen.downloadAndImportRemoteBook(remoteBook)
                await MainActor.run {
                    self.hideLoading()
                    self.showMessage(String(format: L10n.Bookshelf.remoteImported, remoteBook.filename))
                }
            } catch {
                await MainActor.run {
                    self.hideLoading()
                    self.showMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func uploadLocalBooks(from urls: [URL]) {
        guard urls.isEmpty == false else { return }
        showLoading(message: L10n.Bookshelf.remoteUploading)
        Task { [weak self] in
            guard let self else { return }
            var successCount = 0
            var failedCount = 0
            for url in urls {
                do {
                    let uploaded = try await self.screen.uploadRemoteBook(path: url.path)
                    successCount += 1
                    await MainActor.run {
                        self.remoteBooks.removeAll { $0.path == uploaded.path || $0.filename == uploaded.filename }
                        self.remoteBooks.append(uploaded)
                    }
                } catch {
                    failedCount += 1
                }
            }
            await MainActor.run {
                self.hideLoading()
                self.loadRemoteBooks()
                if urls.count == 1, failedCount == 0, let filename = urls.first?.lastPathComponent {
                    self.showMessage(String(format: L10n.Bookshelf.remoteUploaded, filename))
                } else {
                    self.showMessage(L10n.Bookshelf.batchResult(successCount: successCount, failedCount: failedCount))
                }
            }
        }
    }

    private func confirmDelete(_ remoteBook: RemoteBook) {
        let controller = AndroidReplicaRemoteBookConfirmSheetViewController(
            titleText: L10n.Bookshelf.remoteDeleteTitle,
            messageText: String(format: L10n.Bookshelf.remoteDeleteMessage, remoteBook.filename),
            confirmTitle: L10n.Common.delete
        ) { [weak self] in
            self?.deleteRemoteBook(remoteBook)
        }
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: 300),
            animated: true
        )
    }

    private func deleteRemoteBook(_ remoteBook: RemoteBook) {
        showLoading()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.deleteRemoteBook(remoteBook)
                await MainActor.run {
                    self.remoteBooks.removeAll { $0.path == remoteBook.path }
                    self.hideLoading()
                    self.tableView.reloadData()
                    if self.remoteBooks.isEmpty {
                        self.tableView.isHidden = true
                        self.stateView.apply(.empty(L10n.Bookshelf.remoteEmpty))
                    } else {
                        self.tableView.isHidden = false
                        self.stateView.apply(.hidden)
                    }
                }
            } catch {
                await MainActor.run {
                    self.hideLoading()
                    self.showMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func showLoading(message: String = L10n.Bookshelf.remoteLoading) {
        loadingIndicator.startAnimating()
        titleLabel.text = message
        refreshButton.isEnabled = false
        uploadButton.isEnabled = false
        refreshButton.alpha = 0.45
        uploadButton.alpha = 0.45
    }

    private func hideLoading() {
        loadingIndicator.stopAnimating()
        titleLabel.text = headerTitleText
        refreshButton.isEnabled = true
        uploadButton.isEnabled = true
        refreshButton.alpha = 1
        uploadButton.alpha = path == nil ? 1 : 0
    }

    private func showMessage(_ message: String) {
        showTransientMessage(message)
    }
}
