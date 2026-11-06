import UIKit
import shared

enum SourceNetworkCopy {
    static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, tableName: "SourceNetwork", value: fallback, comment: "Source network policy")
    }
}

@MainActor
final class SourceNetworkSettingsViewController: UITableViewController {
    private let sourceURL: String?
    private let sourceName: String?
    private var options: [String: Any] = [:]
    private var defaultOptions: [String: Any] = [:]
    private var effective: SourceNetworkOptions?
    private var issues: [SourceCertificateIssue] = []
    private var grants: [SourceCertificateGrant] = []
    private enum Section: Int, CaseIterable { case options, sources, issues, grants, reset }
    private enum Option: Int, CaseIterable { case timeout, retry, concurrent, agent, proxy }

    init(sourceURL: String? = nil, sourceName: String? = nil) {
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        super.init(style: .plain)
        title = sourceName ?? SourceNetworkCopy.text("title", "书源网络设置")
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityIdentifier = "source.network.settings"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }

    private func reload() {
        do {
            let value = try SourceNetworkPolicy.shared.optionsJson(sourceUrl: sourceURL)
            options = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] ?? [:]
            let defaults = try SourceNetworkPolicy.shared.optionsJson(sourceUrl: nil)
            defaultOptions = try JSONSerialization.jsonObject(with: Data(defaults.utf8)) as? [String: Any] ?? [:]
            effective = try SourceNetworkPolicy.shared.effective(sourceUrl: sourceURL)
            issues = SourceNetworkPolicy.shared.issues(sourceUrl: sourceURL)
            grants = try SourceNetworkPolicy.shared.certificateGrants(sourceUrl: sourceURL)
            tableView.reloadData()
        } catch { showTransientMessage(error.userFacingMessage) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .options: return Option.allCases.count
        case .sources: return sourceURL == nil ? 1 : 0
        case .issues: return issues.count
        case .grants: return max(1, grants.count)
        case .reset: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .options:
            return sourceURL == nil
                ? SourceNetworkCopy.text("defaults", "全局书源默认值")
                : SourceNetworkCopy.text("overrides", "此书源覆盖设置")
        case .sources: return nil
        case .issues: return issues.isEmpty ? nil : SourceNetworkCopy.text("certificate_errors", "证书错误")
        case .grants: return SourceNetworkCopy.text("certificate_grants", "已授权证书")
        case .reset: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .grants else { return nil }
        return SourceNetworkCopy.text("certificate_scope", "授权仅匹配书源、域名、端口及证书，30 天后过期。登录、上传和云备份仍严格校验证书。")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 2
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = .disclosureIndicator
        switch Section(rawValue: indexPath.section)! {
        case .options:
            let option = Option(rawValue: indexPath.row)!
            let key = ["timeoutSeconds", "retryCount", "maxConcurrent", "userAgent", "proxyMode"][option.rawValue]
            cell.textLabel?.text =
                [
                    SourceNetworkCopy.text("timeout", "请求超时"), SourceNetworkCopy.text("retry", "重试次数"),
                    SourceNetworkCopy.text("concurrent", "单书源并发数"), SourceNetworkCopy.text("agent", "User-Agent"),
                    SourceNetworkCopy.text("proxy", "代理"),
                ][option.rawValue]
            let inherited = options[key] == nil || options[key] is NSNull
            let prefix = inherited && sourceURL != nil ? SourceNetworkCopy.text("inherited_prefix", "跟随默认：") : ""
            switch option {
            case .timeout:
                cell.detailTextLabel?.text =
                    (options[key] as? NSNumber ?? defaultOptions[key] as? NSNumber).map {
                        prefix + "\($0.intValue) " + SourceNetworkCopy.text("seconds", "秒")
                    } ?? SourceNetworkCopy.text("source_default", "使用书源或应用默认值")
            case .retry:
                cell.detailTextLabel?.text =
                    (options[key] as? NSNumber ?? defaultOptions[key] as? NSNumber).map {
                        prefix + "\($0.intValue)"
                    } ?? SourceNetworkCopy.text("source_default", "使用书源或应用默认值")
            case .concurrent: cell.detailTextLabel?.text = prefix + "\(effective?.maxConcurrent?.intValue ?? 6)"
            case .agent:
                cell.detailTextLabel?.text = prefix + (effective?.userAgent ?? SourceNetworkCopy.text("source_agent", "使用书源或应用默认值"))
            case .proxy:
                cell.detailTextLabel?.text = prefix + proxyTitle(effective?.proxyMode ?? "rule")
                if effective?.proxyMode == "custom", let raw = effective?.proxy, let url = URLComponents(string: raw) {
                    cell.detailTextLabel?.text = prefix + "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? 0)"
                }
            }
            cell.accessibilityIdentifier = "source.network.\(key)"
        case .sources: cell.textLabel?.text = SourceNetworkCopy.text("choose_source", "按书源设置")
        case .issues:
            let issue = issues[indexPath.row]
            cell.textLabel?.text = "\(issue.host):\(issue.port)"
            cell.detailTextLabel?.text = sourceURL == nil ? issue.sourceUrl : SourceNetworkCopy.text("allow_action", "允许此书源证书兼容")
            cell.accessibilityIdentifier = "source.network.issue.\(issue.id)"
        case .grants:
            if grants.isEmpty {
                cell.textLabel?.text = SourceNetworkCopy.text("strict_default", "未授权，严格校验证书")
                cell.accessoryType = .none
                cell.selectionStyle = .none
            } else {
                let grant = grants[indexPath.row]
                cell.textLabel?.text = "\(grant.host):\(grant.port)"
                cell.detailTextLabel?.text =
                    (sourceURL == nil ? grant.sourceUrl + "\n" : "") + SourceNetworkCopy.text("expires", "到期：")
                    + DateFormatter.localizedString(
                        from: Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000), dateStyle: .medium, timeStyle: .none)
            }
        case .reset:
            cell.textLabel?.text =
                sourceURL == nil
                ? SourceNetworkCopy.text("reset_defaults", "恢复全局默认值")
                : SourceNetworkCopy.text("reset_source", "清除此书源覆盖与证书授权")
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canPerformNavigationAction else { return }
        switch Section(rawValue: indexPath.section)! {
        case .options:
            switch Option(rawValue: indexPath.row)! {
            case .timeout: editNumber(key: "timeoutSeconds", values: [5, 10, 30, 60, 120, 300], range: 5...300)
            case .retry: editNumber(key: "retryCount", values: Array(0...5), range: 0...5)
            case .concurrent: editNumber(key: "maxConcurrent", values: [1, 2, 4, 6, 8, 16, 32], range: 1...32)
            case .agent: editAgent()
            case .proxy: editProxyMode()
            }
        case .sources:
            navigationController?.pushViewController(SourceNetworkSourcePicker(), animated: true)
        case .issues:
            SourceNetworkCertificatePrompt.confirm(issues[indexPath.row], in: self) { [weak self] in self?.reload() }
        case .grants:
            if !grants.isEmpty { confirmRevocation(grants[indexPath.row]) }
        case .reset:
            let alert = UIAlertController(title: tableView.cellForRow(at: indexPath)?.textLabel?.text, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
            alert.addAction(
                UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
                    guard let self else { return }
                    do {
                        try SourceNetworkPolicy.shared.reset(sourceUrl: self.sourceURL)
                        self.reload()
                    } catch { self.showTransientMessage(error.userFacingMessage) }
                })
            present(alert, animated: true)
        }
    }

    private func save(_ changes: [String: Any]) {
        do {
            let updated = options.merging(changes) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: updated)
            try SourceNetworkPolicy.shared.saveOptionsJson(sourceUrl: sourceURL, value: String(decoding: data, as: UTF8.self))
            reload()
        } catch { showTransientMessage(error.userFacingMessage) }
    }

    private func editNumber(key: String, values: [Int], range: ClosedRange<Int>) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: SourceNetworkCopy.text("inherit", "跟随默认"), style: .default) { [weak self] _ in self?.save([key: NSNull()])
            })
        for value in values {
            sheet.addAction(UIAlertAction(title: "\(value)", style: .default) { [weak self] _ in self?.save([key: value]) })
        }
        sheet.addAction(
            UIAlertAction(title: SourceNetworkCopy.text("custom", "自定义"), style: .default) { [weak self] _ in
                guard let self else { return }
                let alert = UIAlertController(title: "\(range.lowerBound)–\(range.upperBound)", message: nil, preferredStyle: .alert)
                alert.addTextField { field in
                    field.keyboardType = .numberPad
                    field.text = (self.options[key] as? NSNumber)?.stringValue
                }
                alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
                alert.addAction(
                    UIAlertAction(title: L10n.Common.save, style: .default) { [weak self, weak alert] _ in
                        guard let value = alert?.textFields?.first?.text.flatMap(Int.init), range.contains(value) else {
                            self?.showTransientMessage(SourceNetworkCopy.text("invalid_value", "输入值不在允许范围内"))
                            return
                        }
                        self?.save([key: value])
                    })
                self.present(alert, animated: true)
            })
        sheet.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        showSheet(sheet)
    }

    private func editAgent() {
        let alert = UIAlertController(title: SourceNetworkCopy.text("agent", "User-Agent"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.options["userAgent"] as? String
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.placeholder = SourceNetworkCopy.text("inherit", "跟随默认")
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: SourceNetworkCopy.text("inherit", "跟随默认"), style: .default) { [weak self] _ in
                self?.save(["userAgent": NSNull()])
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.save, style: .default) { [weak self, weak alert] _ in
                let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self?.save(["userAgent": value.isEmpty ? NSNull() : value])
            })
        present(alert, animated: true)
    }

    private func proxyTitle(_ mode: String) -> String {
        switch mode {
        case "direct": return SourceNetworkCopy.text("proxy_system", "跟随系统，不使用书源代理")
        case "custom": return SourceNetworkCopy.text("proxy_custom", "自定义代理")
        default: return SourceNetworkCopy.text("proxy_rule", "跟随书源或系统")
        }
    }

    private func editProxyMode() {
        let sheet = UIAlertController(title: SourceNetworkCopy.text("proxy", "代理"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: SourceNetworkCopy.text("inherit", "跟随默认"), style: .default) { [weak self] _ in
                self?.save(["proxyMode": NSNull(), "proxy": NSNull()])
            })
        for mode in ["rule", "direct"] {
            sheet.addAction(
                UIAlertAction(title: proxyTitle(mode), style: .default) { [weak self] _ in
                    self?.save(["proxyMode": mode, "proxy": NSNull()])
                })
        }
        sheet.addAction(UIAlertAction(title: proxyTitle("custom"), style: .default) { [weak self] _ in self?.editProxy() })
        sheet.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        showSheet(sheet)
    }

    private func editProxy() {
        let existing = (options["proxy"] as? String).flatMap(URLComponents.init(string:))
        let alert = UIAlertController(
            title: SourceNetworkCopy.text("proxy_custom", "自定义代理"),
            message: SourceNetworkCopy.text("proxy_platform", "HTTP / SOCKS5。WebView 代理需要 iOS 17 或更高版本。"), preferredStyle: .alert)
        alert.addTextField { field in
            var address = existing
            address?.user = nil
            address?.password = nil
            field.text = address?.string
            field.placeholder = "http://127.0.0.1:8080"
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addTextField { field in
            field.text = existing?.user
            field.placeholder = SourceNetworkCopy.text("proxy_user", "代理账号（可选）")
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addTextField { field in
            field.text = existing?.password
            field.placeholder = SourceNetworkCopy.text("proxy_password", "代理密码（可选）")
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.save, style: .default) { [weak self, weak alert] _ in
                guard let fields = alert?.textFields, let raw = fields[0].text,
                    var address = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                    ["http", "socks5"].contains(address.scheme?.lowercased() ?? ""), address.host != nil, address.port != nil
                else {
                    self?.showTransientMessage(SourceNetworkCopy.text("invalid_proxy", "代理地址无效"))
                    return
                }
                address.user = fields[1].text?.isEmpty == false ? fields[1].text : nil
                address.password = address.user == nil ? nil : fields[2].text
                guard let value = address.string else { return }
                self?.save(["proxyMode": "custom", "proxy": value])
            })
        present(alert, animated: true)
    }

    private func showSheet(_ sheet: UIAlertController) {
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    private func confirmRevocation(_ grant: SourceCertificateGrant) {
        let alert = UIAlertController(
            title: SourceNetworkCopy.text("revoke", "撤销证书兼容"), message: "\(grant.host):\(grant.port)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
                do {
                    try SourceNetworkPolicy.shared.revokeCertificate(sourceUrl: grant.sourceUrl, host: grant.host, port: grant.port)
                    self?.reload()
                } catch { self?.showTransientMessage(error.userFacingMessage) }
            })
        present(alert, animated: true)
    }
}

@MainActor
private final class SourceNetworkSourcePicker: UITableViewController, UISearchResultsUpdating {
    private var sources: [BookSource] = []
    private var filtered: [BookSource] = []
    private var task: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SourceNetworkCopy.text("choose_source", "按书源设置")
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.backgroundColor = AndroidReplicaTheme.background
        task = Task { [weak self] in
            do {
                let sources = try await SharedRuntime.sourceManagementFacade().get().getAllSourcesAsync()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.sources = sources
                self.updateSearchResults(for: self.search)
            } catch { self?.showTransientMessage(error.userFacingMessage) }
        }
    }

    deinit { task?.cancel() }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filtered =
            query.isEmpty
            ? sources
            : sources.filter {
                $0.bookSourceName.localizedCaseInsensitiveContains(query) || $0.bookSourceUrl.localizedCaseInsensitiveContains(query)
            }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let source = filtered[indexPath.row]
        cell.textLabel?.text = source.bookSourceName
        cell.detailTextLabel?.text = source.bookSourceUrl
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let source = filtered[indexPath.row]
        navigationController?.pushViewController(
            SourceNetworkSettingsViewController(
                sourceURL: source.bookSourceUrl,
                sourceName: source.bookSourceName), animated: true)
    }
}
