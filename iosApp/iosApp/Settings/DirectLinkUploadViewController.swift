import UIKit
import UniformTypeIdentifiers
import shared

/// Manages the upload rule and applies it only to a file explicitly selected by the user.
@MainActor
final class DirectLinkUploadViewController: UITableViewController, UIDocumentPickerDelegate {
    private var facade: DirectLinkUploadFacade?
    private var rule: DirectLinkUploadRule?
    private var resultURL: URL?
    private var uploading = false
    private var isLoadingRule = false
    private var isDeletingRule = false
    private var loadError: String?
    private var loadGeneration = UUID()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if !uploading && !isDeletingRule { loadRule() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "直链上传"
        tableView.accessibilityIdentifier = "backup.directLinkUpload"
        do {
            facade = try BootstrapApiKt.sharedDirectLinkUploadFacade()
        } catch { showError("无法加载上传配置") }
    }

    private func loadRule() {
        guard let facade, !uploading, !isDeletingRule else { return }
        let generation = UUID()
        loadGeneration = generation
        isLoadingRule = true
        loadError = nil
        updateActions()
        Task {
            do {
                let loaded: DirectLinkUploadRule? = try await SharedAsync.optionalValue {
                    facade.loadRule(completionHandler: $0)
                }
                guard loadGeneration == generation else { return }
                rule = loaded
                isLoadingRule = false
                updateActions()
                tableView.reloadData()
            } catch {
                guard loadGeneration == generation else { return }
                isLoadingRule = false
                loadError = error.userFacingMessage
                updateActions()
                tableView.reloadData()
            }
        }
    }

    private var isBusy: Bool { uploading || isLoadingRule || isDeletingRule }

    private func updateActions() {
        let edit = UIBarButtonItem(
            image: UIImage(systemName: rule == nil ? "plus" : "square.and.pencil"),
            style: .plain, target: self, action: #selector(editRule))
        edit.accessibilityLabel = rule == nil ? "新建上传规则" : "编辑上传规则"
        edit.accessibilityIdentifier = "uploadRule.edit"
        edit.isEnabled = !isBusy
        var actions = [edit]
        if rule != nil {
            let delete = UIBarButtonItem(
                image: UIImage(systemName: "trash"), style: .plain,
                target: self, action: #selector(confirmDeleteRule))
            delete.accessibilityLabel = "删除上传规则"
            delete.accessibilityIdentifier = "uploadRule.delete"
            delete.isEnabled = !isBusy
            actions.append(delete)
        }
        navigationItem.rightBarButtonItems = actions
    }

    @objc private func editRule() {
        guard !isBusy, let facade else { return }
        let editor = DirectLinkUploadRuleEditorViewController(facade: facade, rule: rule)
        editor.onSaved = { [weak self] rule in
            self?.rule = rule
            self?.resultURL = nil
            self?.loadError = nil
            self?.tableView.reloadData()
        }
        navigationController?.pushViewController(editor.configuredForDrillDownPresentation(), animated: true)
    }

    @objc private func confirmDeleteRule() {
        guard !isBusy, rule != nil, let facade else { return }
        let alert = UIAlertController(title: "删除上传规则", message: "是否确认删除？", preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "uploadRule.delete.confirmation"
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        let action = UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self, !self.isBusy, self.isVisibleInNavigationStack else { return }
            self.isDeletingRule = true
            self.updateActions()
            Task {
                defer { self.isDeletingRule = false; self.updateActions(); self.tableView.reloadData() }
                do {
                    try await SharedAsync.void { facade.deleteRule(completionHandler: $0) }
                    self.rule = nil
                    self.resultURL = nil
                    self.loadError = nil
                } catch { self.showError(error.userFacingMessage) }
            }
        }
        alert.addAction(action)
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { resultURL == nil ? 1 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 1 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        if rule == nil { return nil }
        let destination = rule.flatMap { URL(string: $0.uploadUrl.components(separatedBy: ",").first ?? "")?.host } ?? "配置中的服务"
        return "所选文件会上传至 \(destination)，再按规则生成可分享的下载链接。单个文件最大 32 MB。"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.detailTextLabel?.numberOfLines = 2
        if indexPath.section == 1 {
            cell.textLabel?.text = "分享下载链接"
            cell.detailTextLabel?.text = resultURL?.absoluteString
            cell.accessoryType = .disclosureIndicator
        } else if indexPath.row == 0 {
            cell.textLabel?.text = isLoadingRule ? "正在加载…" : rule?.summary ?? "尚未配置上传规则"
            cell.detailTextLabel?.text = loadError ?? (rule == nil ? nil : rule?.compress == true ? "上传前压缩为 ZIP" : "按原始格式上传")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "uploadRule.summaryRow"
        } else {
            cell.textLabel?.text = uploading ? "正在上传…" : "选择文件并生成链接"
            cell.textLabel?.textColor = rule == nil || isBusy ? .secondaryLabel : .systemBlue
            cell.isUserInteractionEnabled = rule != nil && !isBusy
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "uploadRule.chooseFile"
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1, let resultURL {
            let activity = UIActivityViewController(activityItems: [resultURL], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = tableView
            activity.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
            present(activity, animated: true)
        } else if indexPath.row == 0 {
            loadError == nil ? editRule() : loadRule()
        } else if indexPath.row == 1, rule != nil, !isBusy {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
            picker.delegate = self
            picker.allowsMultipleSelection = false
            present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let facade, !isBusy, rule != nil, isVisibleInNavigationStack else { return }
        uploading = true
        updateActions()
        resultURL = nil
        tableView.reloadData()
        Task {
            defer { uploading = false; updateActions(); tableView.reloadData() }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let metadata = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (metadata.fileSize ?? 0) <= 32 * 1024 * 1024 else {
                    showError("上传文件超过 32 MB")
                    return
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 32 * 1024 * 1024 else { showError("上传文件超过 32 MB"); return }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let link: String = try await SharedAsync.value {
                    facade.upload(fileName: url.lastPathComponent, base64Data: data.base64EncodedString(),
                                  contentType: mime, completionHandler: $0)
                }
                resultURL = URL(string: link)
            } catch { showError("直链上传失败，请检查网络、上传规则及服务状态") }
        }
    }

    private func showError(_ message: String) {
        guard isVisibleInNavigationStack, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "直链上传", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}
