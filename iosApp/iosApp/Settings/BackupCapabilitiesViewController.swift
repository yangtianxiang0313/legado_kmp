import UIKit

@MainActor
final class BackupCapabilitiesViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "订阅与服务"
        tableView.accessibilityIdentifier = "backup.capabilities"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 5 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if indexPath.row < ConfigurationManagementCategory.allCases.count {
            let category = ConfigurationManagementCategory.allCases[indexPath.row]
            cell.textLabel?.text = category.title
            cell.accessibilityIdentifier = "backup.capabilities.\(category.rawValue)"
        } else {
            cell.textLabel?.text = "直链上传"
            cell.accessibilityIdentifier = "backup.capabilities.upload"
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let controller: UIViewController
        if indexPath.row < ConfigurationManagementCategory.allCases.count {
            controller = ConfigurationManagementViewController(category: ConfigurationManagementCategory.allCases[indexPath.row])
        } else {
            controller = DirectLinkUploadViewController(style: .insetGrouped)
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}
