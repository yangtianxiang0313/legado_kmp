import UIKit

@MainActor
final class ForegroundWebViewController: UITableViewController {
    private let server = ForegroundWebServer.shared
    private var localNetwork = false
    private var writes = false

    init() { super.init(style: .insetGrouped); title = "Web 服务" }
    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "settings.webService"
        tableView.backgroundColor = AndroidReplicaTheme.background
        server.onChange = { [weak self] in self?.tableView.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 5 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        switch indexPath.row {
        case 0:
            cell.textLabel?.text = server.isRunning ? "停止服务" : "启动服务"
            cell.imageView?.image = UIImage(systemName: server.isRunning ? "stop.fill" : "play.fill")
            cell.accessibilityIdentifier = "web.toggle"
        case 1, 2:
            cell.textLabel?.text = indexPath.row == 1 ? "局域网访问" : "允许修改书源"
            let toggle = UISwitch()
            toggle.tag = indexPath.row
            toggle.isOn = indexPath.row == 1 ? localNetwork : writes
            toggle.isEnabled = !server.isRunning
            toggle.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case 3:
            cell.textLabel?.text = server.accessURL?.absoluteString.components(separatedBy: "#").first ?? "已停止"
            cell.detailTextLabel?.text = server.isRunning ? "前台运行；锁定或退到后台即停止" : nil
            cell.accessibilityIdentifier = "web.address"
        default:
            cell.textLabel?.text = "复制访问地址"
            cell.imageView?.image = UIImage(systemName: "doc.on.doc")
            cell.textLabel?.isEnabled = server.isRunning
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            if server.isRunning {
                server.stop()
            } else if localNetwork || writes {
                let alert = UIAlertController(
                    title: "启动 Web 服务", message: "访问地址含临时密钥。持有密钥者可读取书籍和书源\(writes ? "并修改书源" : "")；请勿在不可信网络使用或转发。",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                alert.addAction(UIAlertAction(title: "启动", style: .default) { [weak self] _ in self?.start() })
                present(alert, animated: true)
            } else {
                start()
            }
        } else if indexPath.row == 4, let url = server.accessURL {
            UIPasteboard.general.url = url
            showTransientMessage("已复制访问地址")
        }
    }

    private func start() {
        do { try server.start(localNetwork: localNetwork, allowsWrites: writes) } catch { presentError(error) }
    }
    @objc private func changed(_ toggle: UISwitch) {
        if toggle.tag == 1 { localNetwork = toggle.isOn } else { writes = toggle.isOn }
    }
}
