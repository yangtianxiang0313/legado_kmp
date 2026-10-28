import UIKit
import SnapKit
import SafariServices
import shared

// MARK: - RSS 文章列表布局样式（F12）
// 对齐 Android 端 articleStyle: 0=标题+图片+描述, 1=标题+描述, 2=仅标题
private enum RssArticleLayoutStyle: Int {
    case titleImageDescription = 0  // 标题+图片+描述（卡片式，默认）
    case titleDescription = 1       // 标题+描述
    case titleOnly = 2              // 仅标题（紧凑）

    // 循环切换，对齐 Android switchLayout 逻辑
    var next: RssArticleLayoutStyle {
        RssArticleLayoutStyle(rawValue: (rawValue + 1) % 3) ?? .titleImageDescription
    }

    var displayName: String {
        switch self {
        case .titleImageDescription: return L10n.RSS.layoutTitleImageDescription
        case .titleDescription: return L10n.RSS.layoutTitleDescription
        case .titleOnly: return L10n.RSS.layoutTitleOnly
        }
    }
}

// MARK: - 已读记录管理（F11）
// 对齐 Android RssReadRecord，用 UserDefaults 持久化已读文章链接
private final class RssReadRecordStore {
    private static let key = "io.legado.kmp.ios.rss.readRecords"
    // 对齐 RssArticle.DEFAULT_GROUP
    static let defaultGroup = "默认分组"

    // 标记文章为已读
    static func markRead(origin: String, link: String) {
        var records = allRecords()
        let identifier = "\(origin)#\(link)"
        records.insert(identifier)
        UserDefaults.standard.set(Array(records), forKey: key)
    }

    // 检查文章是否已读
    static func isRead(origin: String, link: String) -> Bool {
        let identifier = "\(origin)#\(link)"
        return allRecords().contains(identifier)
    }

    // 清除全部已读记录
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func allRecords() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(array)
    }
}

// MARK: - 布局样式持久化
private enum RssLayoutStore {
    private static let key = "io.legado.kmp.ios.rss.articleLayoutStyle"

    static var current: RssArticleLayoutStyle {
        get {
            let raw = UserDefaults.standard.integer(forKey: key)
            return RssArticleLayoutStyle(rawValue: raw) ?? .titleImageDescription
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

final class RssViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let screen = RssScreenAdapter()
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let controlStackView = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var sources: [RssSource] = []
    private var favorites: [RssStar] = []
    private var articles: [RssArticle] = []
    private var selectedSource: RssSource?
    private var sorts: [(name: String, url: String)] = []
    private var selectedSort: (name: String, url: String)?
    private var showingFavorites = false
    // F22: 收藏分组
    private var favoriteGroups: [String] = []
    private var selectedFavoriteGroup: String?
    private var filteredFavorites: [RssStar] = []
    private var currentPage: Int32 = 1
    private var nextPageUrl: String?
    private var isLoadingMore = false
    private var lastItemsSignature: String?
    // F12: 当前布局样式
    private var layoutStyle: RssArticleLayoutStyle = RssLayoutStore.current
    private lazy var favoritesButton = makeLegacyBarButton(title: L10n.RSS.favoritesTitle, imageSystemName: "star", target: self, action: #selector(toggleFavoritesMode))
    private lazy var sourceButton = makeLegacyBarButton(title: L10n.RSS.sourceFallback, imageSystemName: "dot.radiowaves.left.and.right", target: self, action: #selector(handleSourceButton))
    private lazy var sortButton = makeLegacyBarButton(title: L10n.RSS.sortFallback, imageSystemName: "list.bullet", target: self, action: #selector(handleSortButton))
    private lazy var refreshButton = makeLegacyBarButton(title: nil, imageSystemName: "arrow.clockwise", target: self, action: #selector(handleRefresh))
    // F12/F29: 更多菜单按钮
    private lazy var moreButton: UIButton = {
        let button = makeLegacyBarButton(title: nil, imageSystemName: "ellipsis.circle", target: self, action: #selector(handleMoreButton))
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.RSS.title
        view.backgroundColor = .systemBackground
        scaffoldView.titleBarView.setTitle(L10n.RSS.title)
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        controlStackView.axis = .horizontal
        controlStackView.spacing = AppUI.Spacing.small
        controlStackView.distribution = .fillEqually
        controlStackView.layoutMargins = .init(top: 12, left: 12, bottom: 8, right: 12)
        controlStackView.isLayoutMarginsRelativeArrangement = true
        controlStackView.addArrangedSubview(favoritesButton)
        controlStackView.addArrangedSubview(sourceButton)
        controlStackView.addArrangedSubview(sortButton)
        controlStackView.addArrangedSubview(refreshButton)
        controlStackView.addArrangedSubview(moreButton)
        favoritesButton.accessibilityIdentifier = UIIdentifiers.RSS.favoritesButton
        sourceButton.accessibilityIdentifier = UIIdentifiers.RSS.sourceButton
        sortButton.accessibilityIdentifier = UIIdentifiers.RSS.sortButton
        refreshButton.accessibilityIdentifier = UIIdentifiers.RSS.refreshButton

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "rss")
        tableView.register(BookCoverTableViewCell.self, forCellReuseIdentifier: BookCoverTableViewCell.reuseIdentifier)
        tableView.setPlaceholder(nil)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.table
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
        stateView.setTestingIdentifier(UIIdentifiers.RSS.state)
        scaffoldView.contentView.addSubview(controlStackView)
        scaffoldView.contentView.addSubview(tableView)
        scaffoldView.contentView.addSubview(stateView)
        controlStackView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(controlStackView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        updateMoreMenu()
        bootstrapDependencies()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    deinit {
        screen.unbind()
    }

    @objc private func handleSourceButton() {
        guard sourceButton.menu != nil else {
            showTransientMessage(L10n.RSS.sourceUnavailable)
            return
        }
    }

    @objc private func handleSortButton() {
        guard sortButton.menu != nil else {
            showTransientMessage(L10n.RSS.sortUnavailable)
            return
        }
    }

    @objc private func handleMoreButton() {
        // 菜单通过 showsMenuAsPrimaryAction 自动弹出
    }

    // MARK: - F12/F26/F27/F29 更多菜单
    private func updateMoreMenu() {
        // F12: 布局切换子菜单
        let layoutActions = [
            RssArticleLayoutStyle.titleOnly,
            RssArticleLayoutStyle.titleDescription,
            RssArticleLayoutStyle.titleImageDescription
        ].map { style in
            UIAction(
                title: style.displayName,
                state: style == self.layoutStyle ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.layoutStyle = style
                RssLayoutStore.current = style
                self.updateMoreMenu()
                self.render(force: true)
            }
        }
        let layoutMenu = UIMenu(
            title: L10n.RSS.switchLayout,
            image: UIImage(systemName: "rectangle.grid.1x2"),
            children: layoutActions
        )

        // F27: 分组管理
        let groupManageAction = UIAction(
            title: L10n.RSS.groupManageAction,
            image: UIImage(systemName: "folder")
        ) { [weak self] _ in
            self?.handleGroupManage()
        }

        // F26: 导出订阅源
        let exportAction = UIAction(
            title: L10n.RSS.exportSources,
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.handleExportSources()
        }

        // F26: 导入订阅源
        let importAction = UIAction(
            title: L10n.RSS.importSources,
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [weak self] _ in
            self?.handleImportSources()
        }

        // F20: 清除阅读记录
        let clearReadRecordsAction = UIAction(
            title: L10n.RSS.clearReadRecords,
            image: UIImage(systemName: "eye.slash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmClearReadRecords()
        }

        // F29: 清除缓存
        let clearCacheAction = UIAction(
            title: L10n.RSS.clearCache,
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmClearCache()
        }

        // F30: 登录书源
        let loginSourceAction = UIAction(
            title: L10n.RSS.loginSource,
            image: UIImage(systemName: "person.crop.circle")
        ) { [weak self] _ in
            self?.executeSourceLogin()
        }

        // F23: 源管理入口
        let sourceManagementAction = UIAction(
            title: L10n.RSS.sourceManagementAction,
            image: UIImage(systemName: "gearshape")
        ) { [weak self] _ in
            self?.openSourceManagement()
        }

        let importExportMenu = UIMenu(title: "", options: .displayInline, children: [exportAction, importAction])
        moreButton.menu = UIMenu(children: [layoutMenu, sourceManagementAction, groupManageAction, importExportMenu, loginSourceAction, clearReadRecordsAction, clearCacheAction])
    }

    // MARK: - F20 清除阅读记录确认
    private func confirmClearReadRecords() {
        let alert = UIAlertController(
            title: L10n.RSS.clearReadRecordsConfirmTitle,
            message: L10n.RSS.clearReadRecordsConfirmMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
            self?.performClearReadRecords()
        })
        present(alert, animated: true)
    }

    private func performClearReadRecords() {
        // 清除本地 UserDefaults 已读记录
        RssReadRecordStore.clearAll()
        // 清除 shared 层数据库已读记录
        Task { [weak self] in
            do {
                try await self?.screen.clearReadRecords()
            } catch {
                // 数据库清除失败不影响本地已读状态
            }
            await MainActor.run {
                self?.render(force: true)
            }
        }
    }

    // MARK: - F27 分组管理

    private func extractSourceGroups() -> [String] {
        var groups = Set<String>()
        for source in sources {
            guard let sourceGroup = source.sourceGroup, !sourceGroup.isEmpty else { continue }
            for g in sourceGroup.components(separatedBy: CharacterSet(charactersIn: ",;，；")) {
                let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    groups.insert(trimmed)
                }
            }
        }
        return groups.sorted()
    }

    private func handleGroupManage() {
        let groups = extractSourceGroups()
        let alert = UIAlertController(
            title: L10n.RSS.groupManageTitle,
            message: nil,
            preferredStyle: .actionSheet
        )

        for group in groups {
            let count = sources.filter { source in
                guard let sg = source.sourceGroup else { return false }
                return sg.components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .contains(group)
            }.count
            alert.addAction(UIAlertAction(title: "\(group) (\(count))", style: .default) { [weak self] _ in
                self?.showGroupActions(for: group)
            })
        }

        alert.addAction(UIAlertAction(title: L10n.RSS.addGroupTitle, style: .default) { [weak self] _ in
            self?.showAddGroupDialog()
        })

        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = moreButton
            popover.sourceRect = moreButton.bounds
        }
        present(alert, animated: true)
    }

    private func showGroupActions(for group: String) {
        let alert = UIAlertController(title: group, message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: L10n.RSS.renameGroupTitle, style: .default) { [weak self] _ in
            self?.showRenameGroupDialog(oldName: group)
        })

        alert.addAction(UIAlertAction(title: L10n.RSS.deleteGroupTitle, style: .destructive) { [weak self] _ in
            self?.confirmDeleteGroup(name: group)
        })

        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }

    private func showAddGroupDialog() {
        let alert = UIAlertController(title: L10n.RSS.addGroupTitle, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = L10n.RSS.groupNamePlaceholder }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self, weak alert] _ in
            let groupName = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.presentGroupSourcePicker(groupName: groupName)
        })
        present(alert, animated: true)
    }

    private func showRenameGroupDialog(oldName: String) {
        let alert = UIAlertController(title: L10n.RSS.renameGroupTitle, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = oldName; $0.placeholder = L10n.RSS.groupNamePlaceholder }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self, weak alert] _ in
            let newName = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.renameGroup(oldName: oldName, newName: newName)
        })
        present(alert, animated: true)
    }

    private func confirmDeleteGroup(name: String) {
        let message = String(format: L10n.RSS.deleteGroupConfirmMessage, name)
        let alert = UIAlertController(
            title: L10n.RSS.deleteGroupTitle,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
            self?.deleteGroup(name: name)
        })
        present(alert, animated: true)
    }

    private func presentGroupSourcePicker(groupName: String) {
        guard !groupName.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let allSources = try await self.screen.loadAllSources()
                await MainActor.run {
                    let picker = RssGroupSourcePickerViewController(
                        groupName: groupName,
                        sources: allSources
                    ) { [weak self] sourceUrls in
                        self?.addSources(sourceUrls: sourceUrls, toGroup: groupName)
                    }
                    self.navigationController?.pushViewController(picker, animated: true)
                }
            } catch {
                await MainActor.run {
                    self.presentError(error)
                }
            }
        }
    }

    private func addSources(sourceUrls: [String], toGroup groupName: String) {
        guard !sourceUrls.isEmpty else {
            showTransientMessage(L10n.RSS.groupNoSourcesSelected)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.screen.addSources(sourceUrls: sourceUrls, toGroup: groupName)
                await MainActor.run {
                    self.showTransientMessage(String(format: L10n.RSS.groupUpdated, count))
                }
            } catch {
                await MainActor.run {
                    self.presentError(error)
                }
            }
        }
    }

    private func renameGroup(oldName: String, newName: String) {
        guard !newName.isEmpty, newName != oldName else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.screen.renameGroup(oldName: oldName, newName: newName)
                await MainActor.run {
                    self.showTransientMessage(String(format: L10n.RSS.groupUpdated, count))
                }
            } catch {
                await MainActor.run {
                    self.presentError(error)
                }
            }
        }
    }

    private func deleteGroup(name: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.screen.deleteGroup(name: name)
                await MainActor.run {
                    self.showTransientMessage(String(format: L10n.RSS.groupUpdated, count))
                }
            } catch {
                await MainActor.run {
                    self.presentError(error)
                }
            }
        }
    }

    // MARK: - F26 源导入/导出

    private func handleExportSources() {
        guard !sources.isEmpty else {
            let alert = UIAlertController(
                title: L10n.RSS.exportSources,
                message: L10n.RSS.exportSourcesEmpty,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            present(alert, animated: true)
            return
        }
        // 将所有 RSS 源序列化为 JSON
        let jsonArray = sources.map { source -> [String: Any] in
            var dict: [String: Any] = [
                "sourceUrl": source.sourceUrl,
                "sourceName": source.sourceName,
                "enabled": source.enabled,
                "enableJs": source.enableJs,
                "loadWithBaseUrl": source.loadWithBaseUrl,
                "enabledCookieJar": source.enabledCookieJar,
                "singleUrl": source.singleUrl,
                "articleStyle": source.articleStyle,
                "lastUpdateTime": source.lastUpdateTime,
                "customOrder": source.customOrder,
            ]
            if !source.sourceIcon.isEmpty { dict["sourceIcon"] = source.sourceIcon }
            if let v = source.sourceGroup { dict["sourceGroup"] = v }
            if let v = source.sourceComment { dict["sourceComment"] = v }
            if let v = source.variableComment { dict["variableComment"] = v }
            if let v = source.jsLib { dict["jsLib"] = v }
            if let v = source.concurrentRate { dict["concurrentRate"] = v }
            if let v = source.header { dict["header"] = v }
            if let v = source.loginUrl { dict["loginUrl"] = v }
            if let v = source.loginUi { dict["loginUi"] = v }
            if let v = source.loginCheckJs { dict["loginCheckJs"] = v }
            if let v = source.coverDecodeJs { dict["coverDecodeJs"] = v }
            if let v = source.sortUrl { dict["sortUrl"] = v }
            if let v = source.ruleArticles { dict["ruleArticles"] = v }
            if let v = source.ruleNextPage { dict["ruleNextPage"] = v }
            if let v = source.ruleTitle { dict["ruleTitle"] = v }
            if let v = source.rulePubDate { dict["rulePubDate"] = v }
            if let v = source.ruleDescription { dict["ruleDescription"] = v }
            if let v = source.ruleImage { dict["ruleImage"] = v }
            if let v = source.ruleLink { dict["ruleLink"] = v }
            if let v = source.ruleContent { dict["ruleContent"] = v }
            if let v = source.contentWhitelist { dict["contentWhitelist"] = v }
            if let v = source.contentBlacklist { dict["contentBlacklist"] = v }
            if let v = source.shouldOverrideUrlLoading { dict["shouldOverrideUrlLoading"] = v }
            if let v = source.style { dict["style"] = v }
            if let v = source.injectJs { dict["injectJs"] = v }
            return dict
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let activityVC = UIActivityViewController(activityItems: [jsonString], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = moreButton
            popover.sourceRect = moreButton.bounds
        }
        present(activityVC, animated: true)
    }

    private func handleImportSources() {
        let alert = UIAlertController(
            title: L10n.RSS.importSourcesTitle,
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = L10n.RSS.importSourcesPlaceholder
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self] _ in
            guard let jsonText = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonText.isEmpty else { return }
            self?.performImportSources(jsonText: jsonText)
        })
        // 从剪贴板粘贴
        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty,
           clipboard.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            alert.textFields?.first?.text = clipboard
        }
        present(alert, animated: true)
    }

    private func performImportSources(jsonText: String) {
        guard let data = jsonText.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            let errorAlert = UIAlertController(
                title: L10n.RSS.importSourcesFailed,
                message: L10n.RSS.importSourcesInvalidJSON,
                preferredStyle: .alert
            )
            errorAlert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            present(errorAlert, animated: true)
            return
        }

        // seedBundledRssSourcesIfEmpty 仅在数据库为空时生效，已有源时返回 false
        do {
            _ = try BootstrapApiKt.seedBundledRssSourcesIfEmpty(payload: jsonText)
            let resultAlert = UIAlertController(
                title: L10n.RSS.importSources,
                message: String(format: L10n.RSS.importSourcesSuccess, sources.count),
                preferredStyle: .alert
            )
            resultAlert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            present(resultAlert, animated: true)
        } catch {
            let errorAlert = UIAlertController(
                title: L10n.RSS.importSourcesFailed,
                message: error.userFacingMessage,
                preferredStyle: .alert
            )
            errorAlert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            present(errorAlert, animated: true)
        }
    }

    // MARK: - F29 清除缓存确认
    private func confirmClearCache() {
        let alert = UIAlertController(
            title: L10n.RSS.clearCacheConfirmTitle,
            message: L10n.RSS.clearCacheConfirmMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
            self?.performClearCache()
        })
        present(alert, animated: true)
    }

    private func performClearCache() {
        // 清除本地已加载的文章列表和已读记录
        articles = []
        RssReadRecordStore.clearAll()
        render(force: true)
        // 重新加载文章
        if selectedSource != nil, selectedSort != nil {
            loadArticles(page: 1, append: false)
        }
    }

    // MARK: - F30 登录书源

    private func executeSourceLogin() {
        guard let source = selectedSource else {
            showTransientMessage(L10n.RSS.loginSourceUnavailable)
            return
        }
        let loginUrl = source.loginUrl
        guard let loginUrl, !loginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showTransientMessage(L10n.RSS.loginSourceUnavailable)
            return
        }
        let sourceManagementScreen = SourceManagementScreenAdapter()
        switch sourceManagementScreen.bootstrap() {
        case .success:
            Task { [weak self] in
                do {
                    let result = try await sourceManagementScreen.executeLogin(sourceUrl: source.sourceUrl)
                    await MainActor.run {
                        guard let self else { return }
                        if let webURL = result.webUrl, let url = URL(string: webURL) {
                            self.present(SFSafariViewController(url: url), animated: true)
                        } else {
                            self.showTransientMessage(result.executedJs ? L10n.SourceEdit.loginExecutedMessage : L10n.RSS.loginSourceUnavailable)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self?.showTransientMessage(L10n.RSS.loginSourceFailed)
                    }
                }
            }
        case .failure:
            showTransientMessage(L10n.RSS.loginSourceFailed)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if showingFavorites {
            return filteredFavorites.count
        }
        return articles.count + (shouldShowLoadMoreCell ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 收藏列表不受布局样式影响
        if showingFavorites {
            let cell = tableView.dequeueReusableCell(withIdentifier: "rss", for: indexPath)
            var content = cell.defaultContentConfiguration()
            let star = filteredFavorites[indexPath.row]
            content.text = star.title
            let groupLabel = star.group.isEmpty || star.group == RssReadRecordStore.defaultGroup ? nil : star.group
            content.secondaryText = [star.pubDate, groupLabel].compactMap { $0 }.joined(separator: " · ")
            if content.secondaryText?.isEmpty ?? true {
                content.secondaryText = String(format: L10n.RSS.sourceSection, star.origin)
            }
            content.secondaryTextProperties.numberOfLines = 2
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = UIIdentifiers.RSS.articleCell
            return cell
        }
        // "加载更多"单元格
        if shouldShowLoadMoreCell, indexPath.row == articles.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: "rss", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = isLoadingMore ? L10n.RSS.loadingNextPage : L10n.Common.loadMore
            content.secondaryText = nil
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = UIIdentifiers.RSS.loadMoreCell
            cell.accessoryType = .none
            return cell
        }
        let article = articles[indexPath.row]
        // F11: 判断是否已读
        let isRead = RssReadRecordStore.isRead(origin: article.origin, link: article.link)

        switch layoutStyle {
        case .titleOnly:
            // 仅标题（紧凑模式）
            return configureTitleOnlyCell(for: article, at: indexPath, isRead: isRead)
        case .titleDescription:
            // 标题+描述（不显示图片）
            return configureTitleDescriptionCell(for: article, at: indexPath, isRead: isRead)
        case .titleImageDescription:
            // 标题+图片+描述（卡片式，有图时显示图片）
            return configureTitleImageDescriptionCell(for: article, at: indexPath, isRead: isRead)
        }
    }

    // MARK: - F12 布局样式 0: 仅标题
    private func configureTitleOnlyCell(for article: RssArticle, at indexPath: IndexPath, isRead: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "rss", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = article.title
        content.secondaryText = article.pubDate
        content.secondaryTextProperties.numberOfLines = 1
        // F11: 已读文章标题灰色
        if isRead {
            content.textProperties.color = .secondaryLabel
        } else {
            content.textProperties.color = .label
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = UIIdentifiers.RSS.articleCell
        return cell
    }

    // MARK: - F12 布局样式 1: 标题+描述
    private func configureTitleDescriptionCell(for article: RssArticle, at indexPath: IndexPath, isRead: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "rss", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = article.title
        let metadata = [article.pubDate, article.description_]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
        content.secondaryText = metadata.isEmpty ? String(format: L10n.RSS.sourceSection, article.origin) : metadata
        content.secondaryTextProperties.numberOfLines = 2
        // F11: 已读文章标题灰色
        if isRead {
            content.textProperties.color = .secondaryLabel
        } else {
            content.textProperties.color = .label
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = UIIdentifiers.RSS.articleCell
        return cell
    }

    // MARK: - F12 布局样式 2: 标题+图片+描述（卡片式）
    private func configureTitleImageDescriptionCell(for article: RssArticle, at indexPath: IndexPath, isRead: Bool) -> UITableViewCell {
        let hasImage = !(article.image?.isEmpty ?? true)
        if hasImage {
            let cell = tableView.dequeueReusableCell(withIdentifier: BookCoverTableViewCell.reuseIdentifier, for: indexPath) as! BookCoverTableViewCell
            cell.configure(
                title: article.title,
                subtitle: article.pubDate,
                tertiary: article.description_?.replacingOccurrences(of: "\n", with: " "),
                coverURL: article.image
            )
            // F11: 已读文章标题灰色（通过 tintAdjustmentMode 间接处理）
            if isRead {
                cell.contentView.alpha = 0.6
            } else {
                cell.contentView.alpha = 1.0
            }
            cell.accessibilityIdentifier = UIIdentifiers.RSS.articleCell
            cell.onActivate = { [weak self] in
                self?.openArticle(article)
            }
            return cell
        }
        // 无图时退化为标题+描述样式
        return configureTitleDescriptionCell(for: article, at: indexPath, isRead: isRead)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if showingFavorites {
            let star = filteredFavorites[indexPath.row]
            let article = star.toRssArticle(read: false)
            openArticle(article)
            return
        }
        if shouldShowLoadMoreCell, indexPath.row == articles.count {
            loadArticles(page: currentPage + 1, append: true)
            return
        }
        openArticle(articles[indexPath.row])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let article = showingFavorites ? filteredFavorites[indexPath.row].toRssArticle(read: false) : articles[indexPath.row]
        let isFavorite = favorites.contains(where: { $0.origin == article.origin && $0.link == article.link })
        let title = isFavorite ? L10n.RSS.unmarkFavorite : L10n.RSS.markFavorite
        let favoriteAction = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completion in
            self?.toggleFavorite(article)
            completion(true)
        }

        // F21: 收藏模式下可编辑标题和分组
        if showingFavorites {
            let star = filteredFavorites[indexPath.row]
            let editAction = UIContextualAction(style: .normal, title: L10n.Common.edit) { [weak self] _, _, completion in
                self?.presentEditFavorite(star)
                completion(true)
            }
            editAction.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [favoriteAction, editAction])
        }

        return UISwipeActionsConfiguration(actions: [favoriteAction])
    }

    private func bootstrapDependencies() {
        stateView.showLoading(message: L10n.RSS.loading)
        screen.onSourcesChange = { [weak self] sources in
            self?.handleSources(sources)
        }
        screen.onFavoritesChange = { [weak self] favorites in
            self?.favorites = favorites
            self?.applyFavoriteGroupFilter()
            self?.render()
        }
        screen.watchFavoriteGroups { [weak self] groups in
            self?.favoriteGroups = groups
            self?.updateNavigation()
        }

        switch screen.bootstrap() {
        case .success:
            updateNavigation()
        case .failure(let error):
            stateView.showMessage(
                title: L10n.RSS.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    private func handleSources(_ sources: [RssSource]) {
        self.sources = sources
        if let selectedSource,
           sources.contains(where: { $0.sourceUrl == selectedSource.sourceUrl }) == false {
            self.selectedSource = nil
        }
        if selectedSource == nil {
            selectedSource = sources.first
        }
        updateNavigation()
        render()
        if selectedSource != nil, sorts.isEmpty {
            loadSorts(forceRefresh: false)
        }
    }

    private func updateNavigation() {
        let favoritesTitle = showingFavorites ? "\(L10n.RSS.favoritesTitle) \u{2713}" : L10n.RSS.favoritesTitle
        var favoritesConfiguration = favoritesButton.configuration ?? .plain()
        favoritesConfiguration.title = favoritesTitle
        favoritesButton.configuration = favoritesConfiguration

        // F22: 收藏模式下的分组按钮
        if showingFavorites, !favoriteGroups.isEmpty {
            var groupBtnConfig = sortButton.configuration ?? .plain()
            groupBtnConfig.title = selectedFavoriteGroup ?? L10n.RSS.allGroups
            sortButton.configuration = groupBtnConfig

            var groupActions: [UIAction] = []
            // "全部" 选项
            groupActions.append(UIAction(
                title: L10n.RSS.allGroups,
                state: selectedFavoriteGroup == nil ? .on : .off
            ) { [weak self] _ in
                self?.selectedFavoriteGroup = nil
                self?.applyFavoriteGroupFilter()
                self?.updateNavigation()
                self?.render(force: true)
            })
            // 各分组选项
            for group in favoriteGroups {
                groupActions.append(UIAction(
                    title: group,
                    state: selectedFavoriteGroup == group ? .on : .off
                ) { [weak self] _ in
                    self?.selectedFavoriteGroup = group
                    self?.applyFavoriteGroupFilter()
                    self?.updateNavigation()
                    self?.render(force: true)
                })
            }
            sortButton.menu = UIMenu(children: groupActions)
            sortButton.showsMenuAsPrimaryAction = true
        } else {
            var sortConfiguration = sortButton.configuration ?? .plain()
            sortConfiguration.title = selectedSort?.name ?? L10n.RSS.sortFallback
            sortButton.configuration = sortConfiguration
            sortButton.menu = UIMenu(children: sorts.map { sort in
                        UIAction(
                            title: sort.name,
                            state: sort.name == selectedSort?.name ? .on : .off
                        ) { [weak self] _ in
                            self?.selectedSort = sort
                            self?.showingFavorites = false
                            self?.updateNavigation()
                            self?.loadArticles()
                        }
                    })
            sortButton.showsMenuAsPrimaryAction = true
        }

        var sourceConfiguration = sourceButton.configuration ?? .plain()
        sourceConfiguration.title = selectedSource?.sourceName ?? L10n.RSS.sourceFallback
        sourceButton.configuration = sourceConfiguration
        sourceButton.menu = UIMenu(children: sources.map { source in
                    UIAction(
                        title: source.displayNameGroup,
                        state: source.sourceUrl == selectedSource?.sourceUrl ? .on : .off
                    ) { [weak self] _ in
                        self?.selectedSource = source
                        self?.selectedSort = nil
                        self?.sorts = []
                        self?.showingFavorites = false
                        self?.updateNavigation()
                        self?.loadSorts(forceRefresh: false)
                    }
                })
        sourceButton.showsMenuAsPrimaryAction = true
    }

    @objc private func toggleFavoritesMode() {
        showingFavorites.toggle()
        if !showingFavorites {
            selectedFavoriteGroup = nil
        }
        applyFavoriteGroupFilter()
        updateNavigation()
        render(force: true)
    }

    // MARK: - F22 收藏分组过滤
    private func applyFavoriteGroupFilter() {
        if let group = selectedFavoriteGroup {
            filteredFavorites = favorites.filter { $0.group == group }
        } else {
            filteredFavorites = favorites
        }
    }

    @objc private func handleRefresh() {
        if selectedSource == nil {
            return
        }
        loadSorts(forceRefresh: true)
    }

    @objc private func handlePullToRefresh() {
        tableView.refreshControl?.endRefreshing()
        if showingFavorites { return }
        handleRefresh()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView, shouldShowLoadMoreCell, !isLoadingMore else { return }
        let threshold: CGFloat = 100
        if scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - threshold {
            isLoadingMore = true
            tableView.reloadData()
            loadArticles(page: currentPage + 1, append: true)
        }
    }

    private func loadSorts(forceRefresh: Bool) {
        guard let selectedSource else {
            render(force: true)
            return
        }
        stateView.showLoading(message: L10n.RSS.loadingSorts)
        Task { [weak self] in
            do {
                let sorts = try await self?.screen.loadSorts(source: selectedSource, forceRefresh: forceRefresh) ?? []
                await MainActor.run {
                    guard let self else { return }
                    self.sorts = sorts
                    self.selectedSort = sorts.first
                    self.currentPage = 1
                    self.nextPageUrl = nil
                    self.isLoadingMore = false
                    self.updateNavigation()
                    self.loadArticles(page: 1, append: false)
                }
            } catch {
                await MainActor.run {
                    self?.stateView.showMessage(
                        title: L10n.RSS.loadArticlesFailed,
                        message: error.userFacingMessage,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.loadSorts(forceRefresh: forceRefresh)
                    }
                }
            }
        }
    }

    private func loadArticles(page: Int32 = 1, append: Bool = false) {
        guard let selectedSource, let selectedSort else {
            render(force: true)
            return
        }
        if append == false {
            stateView.showLoading(message: L10n.RSS.loadingArticles)
        }
        Task { [weak self] in
            do {
                let payload = try await self?.screen.loadArticles(
                    sortName: selectedSort.name,
                    sortUrl: selectedSort.url,
                    source: selectedSource,
                    page: page
                )
                await MainActor.run {
                    if append {
                        self?.articles.append(contentsOf: payload?.articles ?? [])
                    } else {
                        self?.articles = payload?.articles ?? []
                    }
                    self?.currentPage = page
                    self?.nextPageUrl = payload?.nextPageUrl
                    self?.isLoadingMore = false
                    self?.showingFavorites = false
                    self?.stateView.hide()
                    self?.render(force: true)
                }
            } catch {
                await MainActor.run {
                    self?.isLoadingMore = false
                    self?.stateView.showMessage(
                        title: L10n.RSS.loadArticlesFailed,
                        message: error.userFacingMessage,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.loadArticles(page: page, append: append)
                    }
                }
            }
        }
    }

    private func render(force: Bool = false) {
        if sources.isEmpty {
            stateView.showMessage(
                title: L10n.RSS.emptySourcesTitle,
                message: L10n.RSS.emptySourcesMessage
            )
            tableView.setPlaceholder(L10n.RSS.emptySourcesPlaceholder)
            reloadIfNeeded(signature: "empty-sources", force: force)
            return
        }

        stateView.hide()
        if showingFavorites {
            tableView.setPlaceholder(filteredFavorites.isEmpty ? L10n.RSS.favoritesEmpty : nil)
            reloadIfNeeded(
                signature: filteredFavorites.map { "\($0.origin)#\($0.link)#\($0.title)#\($0.group)" }.joined(separator: "|"),
                force: force
            )
            return
        }

        if selectedSort == nil {
            tableView.setPlaceholder(L10n.RSS.emptySortPlaceholder)
            reloadIfNeeded(signature: "empty-sort", force: force)
            return
        }

        tableView.setPlaceholder(articles.isEmpty ? L10n.RSS.emptyArticles : nil)
        reloadIfNeeded(
            signature: articles.map { "\($0.origin)#\($0.link)#\($0.title)" }.joined(separator: "|"),
            force: force
        )
    }

    private var shouldShowLoadMoreCell: Bool {
        showingFavorites == false && (nextPageUrl?.isEmpty == false)
    }

    private func reloadIfNeeded(signature: String, force: Bool) {
        guard force || signature != lastItemsSignature else { return }
        lastItemsSignature = signature
        tableView.reloadData()
    }

    private func openArticle(_ article: RssArticle) {
        // F11: 打开文章时标记为已读，对齐 Android activityViewModel.read(rssArticle)
        RssReadRecordStore.markRead(origin: article.origin, link: article.link)
        // 刷新当前行以显示灰色标题
        if let index = articles.firstIndex(where: { $0.origin == article.origin && $0.link == article.link }) {
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
        // F16: 使用 WKWebView 渲染 RSS 文章内容，对齐 Android ReadRssActivity
        let source = sources.first(where: { $0.sourceUrl == article.origin })
        let controller = RssWebViewController(
            article: article,
            source: source,
            screen: screen,
            favorites: favorites
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    // MARK: - F23 源管理入口
    private func openSourceManagement() {
        let vc = AndroidReplicaRssSourceManagementViewController().configuredForDrillDownPresentation()
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - F21 编辑收藏
    private func presentEditFavorite(_ star: RssStar) {
        let alert = UIAlertController(
            title: L10n.RSS.editFavoriteTitle,
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = L10n.RSS.editFavoriteTitleField
            textField.text = star.title
        }
        alert.addTextField { textField in
            textField.placeholder = L10n.RSS.editFavoriteGroupField
            textField.text = star.group == RssReadRecordStore.defaultGroup ? "" : star.group
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.save, style: .default) { [weak self] _ in
            let newTitle = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? star.title
            let newGroup = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let updatedStar = RssStar(
                origin: star.origin,
                sort: star.sort,
                title: newTitle.isEmpty ? star.title : newTitle,
                starTime: star.starTime,
                link: star.link,
                pubDate: star.pubDate,
                description: star.description_,
                content: star.content,
                image: star.image,
                group: newGroup.isEmpty ? RssReadRecordStore.defaultGroup : newGroup,
                variable: star.variable
            )
            self?.performUpdateFavorite(updatedStar)
        })
        present(alert, animated: true)
    }

    private func performUpdateFavorite(_ star: RssStar) {
        Task { [weak self] in
            do {
                try await self?.screen.updateFavorite(star: star)
                await MainActor.run {
                    self?.applyFavoriteGroupFilter()
                    self?.render(force: true)
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    private func toggleFavorite(_ article: RssArticle) {
        Task { [weak self] in
            do {
                _ = try await self?.screen.toggleFavorite(article: article)
                await MainActor.run {
                    self?.render(force: true)
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }
}

private final class RssArticleViewController: UIViewController {
    private let article: RssArticle
    private let sources: [RssSource]
    private let screen: RssScreenAdapter
    private let initialFavorites: [RssStar]
    private let stateView = ContentStateView()
    private let textView = UITextView()
    private var isFavorite = false

    init(article: RssArticle, sources: [RssSource], screen: RssScreenAdapter, favorites: [RssStar]) {
        self.article = article
        self.sources = sources
        self.screen = screen
        self.initialFavorites = favorites
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = article.title.isEmpty ? L10n.RSS.articleReaderTitle : article.title
        textView.isEditable = false
        textView.font = .preferredFont(forTextStyle: .body)
        view.addSubview(textView)
        view.addSubview(stateView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        stateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppUI.Spacing.medium),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -AppUI.Spacing.medium),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let favoriteItem = UIBarButtonItem(
            title: L10n.RSS.markFavorite,
            style: .plain,
            target: self,
            action: #selector(toggleFavorite)
        )
        favoriteItem.accessibilityIdentifier = UIIdentifiers.RSS.articleFavoriteButton
        isFavorite = initialFavorites.contains(where: { $0.origin == article.origin && $0.link == article.link })
        favoriteItem.title = isFavorite ? L10n.RSS.unmarkFavorite : L10n.RSS.markFavorite

        var moreActions: [UIAction] = []
        if !article.link.isEmpty {
            let link = article.link
            moreActions.append(UIAction(title: L10n.RSS.shareLink, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self, let url = URL(string: link) else { return }
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                self.present(activityVC, animated: true)
            })
            moreActions.append(UIAction(title: L10n.RSS.openInBrowser, image: UIImage(systemName: "safari")) { _ in
                guard let url = URL(string: link) else { return }
                UIApplication.shared.open(url)
            })
        }
        if moreActions.isEmpty {
            navigationItem.rightBarButtonItem = favoriteItem
        } else {
            let moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: moreActions))
            navigationItem.rightBarButtonItems = [moreItem, favoriteItem]
        }
        loadContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    private func loadContent() {
        if let content = article.content, !content.isEmpty {
            textView.text = content
            stateView.hide()
            return
        }
        guard let source = sources.first(where: { $0.sourceUrl == article.origin }) else {
            textView.text = article.description
            stateView.hide()
            return
        }

        stateView.showLoading(message: L10n.RSS.loadingContent)
        Task { [weak self] in
            do {
                guard let self else { return }
                let content = try await self.screen.loadContent(article: self.article, source: source)
                await MainActor.run {
                    self.textView.text = content
                    self.stateView.hide()
                }
            } catch {
                await MainActor.run {
                    self?.stateView.showMessage(
                        title: L10n.RSS.contentFailed,
                        message: error.userFacingMessage,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.loadContent()
                    }
                }
            }
        }
    }

    @objc private func toggleFavorite() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let nowFavorite = try await self.screen.toggleFavorite(article: self.article)
                await MainActor.run {
                    self.isFavorite = nowFavorite
                    let favoriteItem = self.navigationItem.rightBarButtonItems?.first(where: {
                        $0.accessibilityIdentifier == UIIdentifiers.RSS.articleFavoriteButton
                    }) ?? self.navigationItem.rightBarButtonItem
                    favoriteItem?.title = nowFavorite ? L10n.RSS.unmarkFavorite : L10n.RSS.markFavorite
                }
            } catch {
                await MainActor.run {
                    self.presentError(error)
                }
            }
        }
    }
}

private final class RssGroupSourcePickerViewController: UITableViewController {
    private let groupName: String
    private let sources: [RssSource]
    private let onConfirm: ([String]) -> Void
    private var selectedSourceUrls = Set<String>()

    init(groupName: String, sources: [RssSource], onConfirm: @escaping ([String]) -> Void) {
        self.groupName = groupName
        self.sources = sources.sorted { $0.sourceName.localizedCompare($1.sourceName) == .orderedAscending }
        self.onConfirm = onConfirm
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(groupName:sources:onConfirm:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(L10n.RSS.selectGroupSourcesTitle) - \(groupName)"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "rssGroupSource")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.Common.ok,
            style: .done,
            target: self,
            action: #selector(confirmSelection)
        )
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sources.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "rssGroupSource", for: indexPath)
        let source = sources[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = source.sourceName
        content.secondaryText = source.sourceGroup ?? source.sourceUrl
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = selectedSourceUrls.contains(source.sourceUrl) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let sourceUrl = sources[indexPath.row].sourceUrl
        if selectedSourceUrls.contains(sourceUrl) {
            selectedSourceUrls.remove(sourceUrl)
        } else {
            selectedSourceUrls.insert(sourceUrl)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    @objc private func confirmSelection() {
        let selected = sources.map(\.sourceUrl).filter { selectedSourceUrls.contains($0) }
        guard !selected.isEmpty else {
            showTransientMessage(L10n.RSS.groupNoSourcesSelected)
            return
        }
        onConfirm(selected)
        navigationController?.popViewController(animated: true)
    }
}
