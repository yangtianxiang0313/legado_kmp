import UIKit

@MainActor
final class PdfSearchViewController: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    var onSelection: ((PdfSearchMatch) -> Void)?
    var onQueryChange: ((String) -> Void)?

    private let initialQuery: String
    private let coordinator: PdfSearchCoordinator
    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stopButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private var matches: [PdfSearchMatch] = []
    private var hasAppeared = false
    private var isPresentationActive = false
    private var isClosing = false

    init(fileURL: URL, initialQuery: String = "") {
        self.initialQuery = initialQuery
        coordinator = PdfSearchCoordinator(fileURL: fileURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "正文查找"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeSearch))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "关闭查找"
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "pdf.search.close"
        configureViews()
        coordinator.onUpdate = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationActive = true
        guard !hasAppeared else { return }
        hasAppeared = true
        if initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchBar.becomeFirstResponder()
        } else {
            submit()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationActive = false
        coordinator.cancel()
        view.endEditing(true)
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = "pdf.search"
        view.accessibilityViewIsModal = true
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = "搜索正文"
        searchBar.text = initialQuery
        searchBar.showsCancelButton = false
        searchBar.tintColor = AndroidReplicaTheme.accent
        searchBar.searchTextField.autocorrectionType = .no
        searchBar.searchTextField.autocapitalizationType = .none
        searchBar.searchTextField.spellCheckingType = .no
        searchBar.searchTextField.clearButtonMode = .whileEditing
        searchBar.searchTextField.textColor = AndroidReplicaTheme.primaryText
        searchBar.searchTextField.accessibilityIdentifier = "pdf.search.query"

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "pdf.search.status"
        spinner.hidesWhenStopped = true
        configureButton(stopButton, symbol: "stop.circle", label: "停止查找", action: #selector(stopSearch))
        configureButton(retryButton, symbol: "arrow.clockwise", label: "重试", action: #selector(retrySearch))
        let status = UIStackView(arrangedSubviews: [spinner, statusLabel, stopButton, retryButton])
        status.axis = .horizontal
        status.alignment = .center
        status.spacing = 8
        status.isLayoutMarginsRelativeArrangement = true
        status.layoutMargins = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 8)
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.keyboardDismissMode = .interactive
        tableView.tableFooterView = UIView()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "pdf.search.match")
        tableView.accessibilityIdentifier = "pdf.search.results"

        let emptyView = UIView()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = "pdf.search.empty"
        emptyView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: emptyView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: emptyView.trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor),
        ])
        tableView.backgroundView = emptyView

        for item in [searchBar, status, tableView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            status.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: status.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func configureButton(_ button: UIButton, symbol: String, label: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = AndroidReplicaTheme.accent
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func render() {
        matches = coordinator.results
        tableView.reloadData()
        emptyLabel.text = nil
        stopButton.isHidden = coordinator.status != .searching
        retryButton.isHidden = true
        if coordinator.status == .searching { spinner.startAnimating() } else { spinner.stopAnimating() }

        switch coordinator.status {
        case .idle:
            statusLabel.text = nil
        case .searching:
            statusLabel.text = "正在查找 · \(matches.count) 个结果"
        case .completed:
            statusLabel.text = "\(matches.count) 个结果"
            if matches.isEmpty { emptyLabel.text = "未找到匹配内容" }
        case .cancelled:
            statusLabel.text = "查找已停止 · \(matches.count) 个结果"
            if matches.isEmpty { emptyLabel.text = "查找已停止" }
        case .truncated:
            statusLabel.text = "达到上限，显示前\(PdfSearchCoordinator.maximumResults)项"
        case .failed(let message):
            statusLabel.text = matches.isEmpty ? "查找失败" : "\(message)（保留 \(matches.count) 个结果）"
            if matches.isEmpty { emptyLabel.text = message }
            retryButton.isHidden = false
        }
    }

    private func submit() {
        guard canInteract, searchBar.searchTextField.markedTextRange == nil else { return }
        let query = searchBar.text ?? ""
        onQueryChange?(query)
        guard canInteract else { return }
        view.endEditing(true)
        tableView.setContentOffset(.zero, animated: false)
        coordinator.search(query: query)
    }

    private var canInteract: Bool {
        isPresentationActive && !isClosing && viewIfLoaded?.window != nil
            && !isBeingDismissed && navigationController?.isBeingDismissed != true
            && UIApplication.shared.applicationState == .active
    }

    private var presentationOwner: UIViewController? {
        var owner: UIViewController = self
        while let parent = owner.parent { owner = parent }
        return owner.presentingViewController == nil ? nil : owner
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { submit() }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard !isClosing else { return }
        coordinator.search(query: searchText.utf16.count > PdfSearchCoordinator.maximumQueryLength ? searchText : "")
        onQueryChange?(searchText)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        guard canInteract, let owner = presentationOwner, owner.transitionCoordinator == nil else { return }
        onQueryChange?(searchBar.text ?? "")
        guard canInteract else { return }
        isClosing = true
        coordinator.cancel()
        view.endEditing(true)
        owner.dismiss(animated: true)
    }

    @objc private func stopSearch() {
        guard canInteract else { return }
        coordinator.cancel()
    }

    @objc private func retrySearch() { submit() }

    @objc private func closeSearch() { searchBarCancelButtonClicked(searchBar) }

    @objc private func appWillResignActive() {
        coordinator.cancel()
        view.endEditing(true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { matches.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pdf.search.match", for: indexPath)
        let match = matches[indexPath.row]
        let lastPage = match.ranges.map(\.pageIndex).max() ?? match.pageIndex
        let pageText =
            lastPage == match.pageIndex
            ? "第 \(match.pageIndex + 1) 页" : "第 \(match.pageIndex + 1)–\(lastPage + 1) 页"
        var content = cell.defaultContentConfiguration()
        content.text = pageText
        content.secondaryText = match.text
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textProperties.color = AndroidReplicaTheme.secondaryText
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.color = AndroidReplicaTheme.primaryText
        content.secondaryTextProperties.numberOfLines = 4
        cell.contentConfiguration = content
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "pdf.search.match.\(indexPath.row)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canInteract, matches.indices.contains(indexPath.row),
            coordinator.query == searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let owner = presentationOwner, owner.transitionCoordinator == nil,
            owner.presentedViewController == nil, !owner.isBeingDismissed
        else { return }
        let match = matches[indexPath.row]
        let callback = onSelection
        isClosing = true
        coordinator.cancel()
        view.endEditing(true)
        owner.dismiss(animated: true) { [weak owner] in
            guard owner?.presentingViewController == nil else { return }
            callback?(match)
        }
    }
}
