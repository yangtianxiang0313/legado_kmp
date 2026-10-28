import UIKit
import shared

@MainActor
final class CoverRuleConfigurationViewController: UITableViewController {
    private enum Field: String, CaseIterable {
        case enable, searchUrl, coverRule, concurrentRate, loginUrl, loginUi, header, jsLib, enabledCookieJar

        var title: String {
            switch self {
            case .enable: return "启用封面搜索"
            case .searchUrl: return "搜索 URL"
            case .coverRule: return "封面解析规则"
            case .concurrentRate: return "并发速率"
            case .loginUrl: return "登录 URL"
            case .loginUi: return "登录 UI"
            case .header: return "请求头"
            case .jsLib: return "JavaScript 库"
            case .enabledCookieJar: return "启用 Cookie"
            }
        }
    }

    private var facade: BookImageFacade?
    private var draft: [String: Any] = [:]
    private var original: [String: Any] = [:]
    private var hasSaved = false
    private let sections: [[Field]] = [
        [.enable, .searchUrl, .coverRule], [.concurrentRate, .loginUrl, .loginUi, .header, .jsLib, .enabledCookieJar],
    ]

    init() {
        super.init(style: .grouped)
        title = "封面搜索规则"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.accessibilityIdentifier = "coverConfiguration.ruleTable"
        view.tintColor = AndroidReplicaTheme.accent
        tableView.backgroundColor = AndroidReplicaTheme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "保存封面搜索规则"
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "coverConfiguration.ruleSave"
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.leftItemsSupplementBackButton = false
        navigationItem.backButtonDisplayMode = .minimal
        do {
            let facade = try SharedRuntime.bookImageFacade().get()
            self.facade = facade
            if let raw = facade.exportCoverRuleJson(), let data = raw.data(using: .utf8),
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                draft = value
            } else {
                let rule = facade.getCoverRule()
                draft = ["enable": rule.enable, "searchUrl": rule.searchUrl, "coverRule": rule.coverRule]
            }
            original = draft
            navigationItem.rightBarButtonItem?.isEnabled = true
        } catch {
            DispatchQueue.main.async { [weak self] in self?.showError(error.localizedDescription) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 2 ? 1 : sections[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "请求与脚本" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.summaryText
        cell.detailTextLabel?.numberOfLines = 2
        guard indexPath.section < 2 else {
            cell.textLabel?.text = "恢复默认搜索规则"
            cell.textLabel?.textColor = .systemRed
            return cell
        }
        let field = sections[indexPath.section][indexPath.row]
        cell.textLabel?.text = field.title
        cell.accessibilityIdentifier = "coverConfiguration.rule.\(field.rawValue)"
        if field == .enable || field == .enabledCookieJar {
            let toggle = UISwitch()
            toggle.isOn = (draft[field.rawValue] as? NSNumber)?.boolValue ?? false
            toggle.accessibilityLabel = field.title
            toggle.isEnabled = facade != nil
            toggle.addAction(
                UIAction { [weak self, weak toggle] _ in
                    guard let toggle else { return }
                    self?.draft[field.rawValue] = toggle.isOn
                }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else {
            cell.detailTextLabel?.text = (draft[field.rawValue] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未设置"
            cell.accessoryType = .disclosureIndicator
        }
        cell.isUserInteractionEnabled = facade != nil
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard facade != nil else { return }
        if indexPath.section == 2 {
            let alert = UIAlertController(title: "恢复默认搜索规则？", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(
                UIAlertAction(title: "恢复", style: .destructive) { [weak self] _ in
                    guard let self, let facade = self.facade else { return }
                    facade.deleteCoverRule()
                    self.hasSaved = true
                    self.navigationController?.popViewController(animated: true)
                })
            present(alert, animated: true)
            return
        }
        let field = sections[indexPath.section][indexPath.row]
        guard field != .enable, field != .enabledCookieJar else { return }
        let editor = CoverConfigurationTextEditorViewController(
            title: field.title, text: draft[field.rawValue] as? String ?? "",
            identifier: "coverConfiguration.ruleEditor.\(field.rawValue)"
        ) { [weak self] text in
            guard let self else { return }
            if text.isEmpty && field != .searchUrl && field != .coverRule {
                self.draft.removeValue(forKey: field.rawValue)
            } else {
                self.draft[field.rawValue] = text
            }
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    @objc private func save() {
        guard let facade else { return }
        let search = (draft[Field.searchUrl.rawValue] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = (draft[Field.coverRule.rawValue] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty, !rule.isEmpty else {
            showError("搜索 URL 和封面解析规则不能为空。")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else { return }
            facade.saveCoverRuleFromJson(json: json)
            hasSaved = true
            navigationController?.popViewController(animated: true)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func cancel() {
        guard !hasSaved, !NSDictionary(dictionary: original).isEqual(to: draft) else {
            navigationController?.popViewController(animated: true)
            return
        }
        let alert = UIAlertController(title: "放弃未保存的搜索规则？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "放弃", style: .destructive) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "无法保存封面规则", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
