import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class CoverConfigurationViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Row {
        case wifi, useDefault, rule, background, removeBackground, name, author, resetMode, resetAll
    }

    private let store: CoverConfigurationStore
    private let preview = CoverConfigurationPreviewView()
    private var observers: [NSObjectProtocol] = []
    private var importTask: Task<Void, Never>?
    private var importID = UUID()
    private var importMode: CoverConfigurationMode?
    private var isImporting = false
    private var active = false

    init(store: CoverConfigurationStore? = nil) {
        self.store = store ?? .shared
        super.init(style: .grouped)
        title = "封面配置"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        importTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.accessibilityIdentifier = "coverConfiguration.table"
        preview.onChange = { [weak self] in self?.refresh() }
        tableView.tableHeaderView = preview
        for name in [CoverConfigurationStore.didChange, UserDefaults.didChangeNotification, .androidReplicaThemeDidChange] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in Task { @MainActor in self?.refresh() }
                })
        }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        active = true
        refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true || isBeingDismissed {
            active = false
            cancelImport()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = preview.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if preview.frame.width != width || abs(preview.frame.height - size.height) > 0.5 {
            preview.frame = CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
            tableView.tableHeaderView = preview
        }
    }

    private var mode: CoverConfigurationMode {
        CoverConfigurationMode(rawValue: preview.modeControl.selectedSegmentIndex) ?? .day
    }

    private var sections: [[Row]] {
        var background: [Row] = [.background]
        if store.configuration(for: mode).backgroundPath != nil { background.append(.removeBackground) }
        return [[.wifi, .useDefault, .rule], background, [.name, .author], [.resetMode, .resetAll]]
    }

    private func refresh() {
        guard isViewLoaded else { return }
        preview.render(configuration: store.configuration(for: mode), mode: mode)
        view.tintColor = AndroidReplicaTheme.accent
        tableView.backgroundColor = AndroidReplicaTheme.background
        preview.modeControl.isEnabled = !isImporting
        tableView.reloadData()
        view.setNeedsLayout()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [nil, "\(mode.title)底图", "\(mode.title)文字", nil][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section][indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.summaryText
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        let config = store.configuration(for: mode)
        switch row {
        case .wifi:
            cell.textLabel?.text = "仅 Wi-Fi 加载封面"
            setSwitch(cell, identifier: "wifi", value: store.loadsOnlyOnWiFi) { [weak self] in
                self?.store.setLoadsOnlyOnWiFi($0)
            }
        case .useDefault:
            cell.textLabel?.text = "使用默认封面"
            setSwitch(cell, identifier: "useDefault", value: store.usesDefaultCover) { [weak self] in
                self?.store.setUsesDefaultCover($0)
            }
        case .rule:
            cell.textLabel?.text = "封面搜索规则"
            cell.accessoryType = .disclosureIndicator
        case .background:
            cell.textLabel?.text = "默认封面底图"
            cell.detailTextLabel?.text = isImporting ? "正在导入" : config.backgroundPath == nil ? "内置" : "自定义"
            cell.accessoryType = .disclosureIndicator
        case .removeBackground:
            cell.textLabel?.text = "移除底图"
        case .name:
            cell.textLabel?.text = "显示书名"
            let selectedMode = mode
            setSwitch(cell, identifier: "showName", value: config.showsName) { [weak self] in
                self?.store.setShowsName($0, mode: selectedMode)
            }
        case .author:
            cell.textLabel?.text = "显示作者"
            let selectedMode = mode
            setSwitch(cell, identifier: "showAuthor", value: config.showsAuthor, enabled: config.showsName) { [weak self] in
                self?.store.setShowsAuthor($0, mode: selectedMode)
            }
            cell.textLabel?.isEnabled = config.showsName
        case .resetMode:
            cell.textLabel?.text = "恢复\(mode.title)默认封面"
        case .resetAll:
            cell.textLabel?.text = "恢复全部封面配置"
            cell.textLabel?.textColor = .systemRed
        }
        if isImporting { cell.isUserInteractionEnabled = false }
        return cell
    }

    private func setSwitch(
        _ cell: UITableViewCell, identifier: String, value: Bool, enabled: Bool = true,
        changed: @escaping (Bool) -> Void
    ) {
        let toggle = UISwitch()
        toggle.isOn = value
        toggle.isEnabled = enabled && !isImporting
        toggle.accessibilityIdentifier = "coverConfiguration.\(identifier)"
        toggle.accessibilityLabel = cell.textLabel?.text
        toggle.addAction(
            UIAction { [weak toggle] _ in
                guard let toggle else { return }
                changed(toggle.isOn)
            }, for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isImporting else { return }
        view.endEditing(true)
        switch sections[indexPath.section][indexPath.row] {
        case .rule:
            navigationController?.pushViewController(CoverRuleConfigurationViewController(), animated: true)
        case .background:
            importMode = mode
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            present(picker, animated: true)
        case .removeBackground:
            confirm(title: "移除\(mode.title)底图？", actionTitle: "移除") { [weak self, mode = mode] in
                self?.store.setBackgroundPath(nil, mode: mode)
            }
        case .resetMode:
            confirm(title: "恢复\(mode.title)默认封面？") { [weak self, mode = mode] in self?.store.restore(mode: mode) }
        case .resetAll:
            confirm(title: "恢复全部封面配置？") { [weak self] in
                guard let self else { return }
                do {
                    let facade = try SharedRuntime.bookImageFacade().get()
                    facade.deleteCoverRule()
                    self.store.restoreAll()
                } catch { self.showError(error) }
            }
        default: break
        }
    }

    private func confirm(title: String, actionTitle: String = "恢复", action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in action() })
        present(alert, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { importMode = nil }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let selectedMode = importMode, active, !isImporting else { return }
        importMode = nil
        let id = UUID()
        importID = id
        isImporting = true
        refresh()
        importTask = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { try CoverConfigurationImageFiles.importImage(at: url) }
            do {
                let path = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard let self, self.active, self.importID == id, !Task.isCancelled else {
                    CoverConfigurationImageFiles.removeOwnedImage(path)
                    return
                }
                self.importTask = nil
                self.isImporting = false
                self.store.setBackgroundPath(path, mode: selectedMode)
                self.refresh()
            } catch {
                guard let self, self.importID == id else { return }
                self.importTask = nil
                self.isImporting = false
                self.refresh()
                guard self.active, !Task.isCancelled else { return }
                self.showError(error)
            }
        }
    }

    private func cancelImport() {
        importID = UUID()
        importTask?.cancel()
        importTask = nil
        isImporting = false
        importMode = nil
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "封面配置失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
