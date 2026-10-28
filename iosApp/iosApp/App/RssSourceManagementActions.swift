import shared
import UIKit

@MainActor
final class RssSourceManagementActions {
    private let screen: RssSourceManagementScreenAdapter
    private weak var presenter: UIViewController?
    private var snapshotRevision = 0
    private var exportDirectory: URL?
    private(set) var sources: [RssSource] = []
    private(set) var selectedURLs = Set<String>()
    private(set) var isSelecting = false
    private(set) var isBusy = false
    private(set) var hasSnapshot = false
    private(set) var loadError: String?
    var onChange: (() -> Void)?
    var onGroupRenamed: ((String, String) -> Void)?
    var onGroupRemoved: ((String) -> Void)?

    init(screen: RssSourceManagementScreenAdapter, presenter: UIViewController) {
        self.screen = screen
        self.presenter = presenter
    }

    deinit {
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
    }

    var groups: [String] {
        let names = sources.flatMap { source in
            (source.sourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func receive(_ sources: [RssSource]) {
        snapshotRevision += 1
        self.sources = sources
        hasSnapshot = true
        loadError = nil
        // Do not prune selection here: a failed batch may already have deleted some URLs.
        onChange?()
    }

    func reload() {
        guard !isBusy else { return }
        isBusy = true
        loadError = nil
        onChange?()
        let revision = snapshotRevision
        Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; onChange?() }
            do {
                let loaded = try await screen.loadAllSources()
                if snapshotRevision == revision { receive(loaded) }
            } catch {
                loadError = error.userFacingMessage
                if hasSnapshot { presenter?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    func beginSelection(sourceURL: String? = nil) {
        guard !isBusy, hasSnapshot else { return }
        isSelecting = true
        if let sourceURL { selectedURLs.insert(sourceURL) }
        onChange?()
    }

    func cancelSelection() {
        guard !isBusy else { return }
        isSelecting = false
        selectedURLs.removeAll()
        onChange?()
    }

    func toggle(_ sourceURL: String) {
        guard isSelecting, !isBusy else { return }
        if !selectedURLs.insert(sourceURL).inserted { selectedURLs.remove(sourceURL) }
        onChange?()
    }

    func toggleAll(visibleURLs: [String]) {
        guard isSelecting, !isBusy else { return }
        let visible = Set(visibleURLs)
        if visible.isSubset(of: selectedURLs) {
            selectedURLs.subtract(visible)
        } else {
            selectedURLs.formUnion(visible)
        }
        onChange?()
    }

    func invertSelection(visibleURLs: [String]) {
        guard isSelecting, !isBusy else { return }
        selectedURLs.formSymmetricDifference(visibleURLs)
        onChange?()
    }

    func setEnabled(sourceURLs: [String], enabled: Bool) {
        let targets = Array(Set(sourceURLs)).sorted()
        guard !targets.isEmpty else { return }
        perform {
            try await self.screen.setEnabled(sourceUrls: targets, enabled: enabled)
        }
    }

    func confirmDelete(sourceURLs: [String], sourceName: String? = nil) {
        guard canStartAction, !sourceURLs.isEmpty else { return }
        let targets = Array(Set(sourceURLs)).sorted()
        let message = sourceName.map { "是否确认删除？\n\($0)" } ?? "是否确认删除？\n已选 \(targets.count) 个订阅源。"
        let alert = UIAlertController(title: "提醒", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "否", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "是", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.perform(onSuccess: { [weak self] in self?.selectedURLs.subtract(targets) }) {
                    try await self.screen.deleteSources(sourceUrls: targets)
                }
            })
        presentAlert(alert)
    }

    func addSelectedToGroup() {
        let targets = selectedURLs.sorted()
        guard !targets.isEmpty else { return }
        let choices = groups
        guard !choices.isEmpty else {
            promptToAddGroup(targets: targets)
            return
        }
        let alert = UIAlertController(title: "添加分组", message: nil, preferredStyle: .actionSheet)
        alert.addAction(
            UIAlertAction(title: "新建分组", style: .default) { [weak self] _ in
                self?.promptToAddGroup(targets: targets)
            })
        for group in choices {
            alert.addAction(
                UIAlertAction(title: group, style: .default) { [weak self] _ in
                    self?.addToGroup(targets: targets, group: group)
                })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        presentSheet(alert)
    }

    func renameGroup(_ group: String) {
        promptForGroup(title: "重命名分组", initial: group) { [weak self] newName in
            guard let self, newName != group else { return }
            self.perform(onSuccess: { [weak self] in self?.onGroupRenamed?(group, newName) }) {
                _ = try await self.screen.renameGroup(oldName: group, newName: newName)
            }
        }
    }

    func confirmRemoveGroup(_ group: String) {
        guard canStartAction else { return }
        let alert = UIAlertController(title: "移除分组", message: "移除「\(group)」？\n仅移除分组，保留所有订阅源及其其他分组。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.perform(onSuccess: { [weak self] in self?.onGroupRemoved?(group) }) {
                    _ = try await self.screen.deleteGroup(name: group)
                }
            })
        presentAlert(alert)
    }

    func importBundled(payload: String) {
        perform { _ = try await self.screen.importSources(payload: payload) }
    }

    func selectionMenu(anchor: UIView) -> UIMenu {
        let targets = selectedURLs.sorted()
        let attributes: UIMenuElement.Attributes = targets.isEmpty || isBusy ? [.disabled] : []
        return UIMenu(children: [
            UIAction(title: "启用所选", image: UIImage(systemName: "play.circle"), attributes: attributes) { [weak self] _ in
                self?.setEnabled(sourceURLs: targets, enabled: true)
            },
            UIAction(title: "禁用所选", image: UIImage(systemName: "pause.circle"), attributes: attributes) { [weak self] _ in
                self?.setEnabled(sourceURLs: targets, enabled: false)
            },
            UIAction(title: "添加分组", image: UIImage(systemName: "folder.badge.plus"), attributes: attributes) { [weak self] _ in
                self?.addSelectedToGroup()
            },
            UIAction(title: "导出所选", image: UIImage(systemName: "square.and.arrow.up"), attributes: attributes) {
                [weak self, weak anchor] _ in
                guard let anchor else { return }
                self?.export(sourceURLs: targets, anchor: anchor)
            },
        ])
    }

    func groupMenu(onFilter: @escaping (String?) -> Void) -> UIMenu {
        var items: [UIMenuElement] = [
            UIAction(title: "全部分组", image: UIImage(systemName: "folder")) { _ in onFilter(nil) }
        ]
        for group in groups {
            items.append(
                UIMenu(
                    title: group,
                    children: [
                        UIAction(title: "查看分组", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in
                            onFilter(group)
                        },
                        UIAction(title: "重命名分组", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameGroup(group)
                        },
                        UIAction(title: "移除分组", image: UIImage(systemName: "folder.badge.minus"), attributes: [.destructive]) {
                            [weak self] _ in self?.confirmRemoveGroup(group)
                        },
                    ]))
        }
        return UIMenu(title: "分组管理", image: UIImage(systemName: "folder"), children: items)
    }

    func showSourceMenu(_ source: RssSource, anchor: UIView) {
        guard canPresent, !isSelecting else { return }
        let sourceURL = source.sourceUrl
        let name = source.sourceName
        let enabled = source.enabled
        let alert = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(
            UIAlertAction(title: "选择", style: .default) { [weak self] _ in self?.beginSelection(sourceURL: sourceURL) })
        alert.addAction(
            UIAlertAction(
                title: enabled ? L10n.RSS.sourceManagementDisableAction : L10n.RSS.sourceManagementEnableAction, style: .default
            ) { [weak self] _ in
                self?.setEnabled(sourceURLs: [sourceURL], enabled: !enabled)
            })
        alert.addAction(
            UIAlertAction(title: L10n.RSS.sourceManagementDeleteAction, style: .destructive) { [weak self] _ in
                self?.confirmDelete(sourceURLs: [sourceURL], sourceName: name)
            })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        presentAlert(alert)
    }

    func export(sourceURLs: [String], anchor: UIView) {
        guard !isBusy, !sourceURLs.isEmpty else { return }
        let targets = Array(Set(sourceURLs)).sorted()
        isBusy = true
        onChange?()
        Task { [weak self, weak anchor] in
            guard let self else { return }
            do {
                let payload = try await screen.exportSources(sourceUrls: targets)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "rss-export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                exportDirectory = directory
                let file = directory.appendingPathComponent("exportRssSource.json")
                try payload.write(to: file, atomically: true, encoding: .utf8)
                isBusy = false
                onChange?()
                guard canStartAction, let presenter else { clearExport(); return }
                let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    let source = anchor ?? presenter.view!
                    popover.sourceView = source
                    popover.sourceRect = source.bounds
                }
                activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                    Task { @MainActor in self?.clearExport() }
                }
                presentController(activity, unavailable: { [weak self] in self?.clearExport() })
            } catch {
                clearExport()
                isBusy = false
                onChange?()
                showFailure(error) { [weak self, weak anchor] in
                    guard let self, let anchor = anchor ?? self.presenter?.view else { return }
                    self.export(sourceURLs: targets, anchor: anchor)
                }
            }
        }
    }

    private var canStartAction: Bool { !isBusy && presenter?.viewIfLoaded?.window != nil }
    private var canPresent: Bool { canStartAction && presenter?.presentedViewController == nil }

    private func perform(onSuccess: (() -> Void)? = nil, operation: @escaping () async throws -> Void) {
        guard !isBusy, hasSnapshot else { return }
        isBusy = true
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                onSuccess?()
                let revision = snapshotRevision
                do {
                    let loaded = try await screen.loadAllSources()
                    if snapshotRevision == revision { receive(loaded) }
                } catch {
                    loadError = error.userFacingMessage
                    presenter?.showTransientMessage("操作已完成，刷新失败：\(error.userFacingMessage)")
                }
                isBusy = false
                onChange?()
            } catch {
                isBusy = false
                onChange?()
                showFailure(error) { [weak self] in self?.perform(onSuccess: onSuccess, operation: operation) }
            }
        }
    }

    private func promptToAddGroup(targets: [String]) {
        promptForGroup(title: "添加分组", initial: "") { [weak self] group in
            self?.addToGroup(targets: targets, group: group)
        }
    }

    private func addToGroup(targets: [String], group: String) {
        perform { _ = try await self.screen.addSources(sourceUrls: targets, toGroup: group) }
    }

    private func promptForGroup(title: String, initial: String, submit: @escaping (String) -> Void) {
        guard canStartAction else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "分组名称"
            field.text = initial
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "rss.sourceManagement.groupName"
        }
        let save = UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return
            }
            submit(name)
        }
        let field = alert.textFields!.first!
        let validate: (String) -> Bool = { text in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && text.rangeOfCharacter(from: CharacterSet(charactersIn: ",;，；\n\r")) == nil
        }
        save.isEnabled = validate(initial)
        field.addAction(
            UIAction { [weak field, weak save] _ in
                save?.isEnabled = validate(field?.text ?? "")
            }, for: .editingChanged)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(save)
        presentAlert(alert)
    }

    private func presentSheet(_ alert: UIAlertController) {
        guard canStartAction, let presenter else { return }
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - presenter.view.safeAreaInsets.bottom, width: 1,
                height: 1)
        }
        presentAlert(alert)
    }

    private func presentAlert(_ alert: UIAlertController) {
        presentController(alert)
    }

    private func presentController(_ controller: UIViewController, unavailable: (() -> Void)? = nil) {
        guard canStartAction, let presenter else { unavailable?(); return }
        presenter.view.endEditing(true)
        let show = { [weak self] in
            guard let self, self.canPresent else { unavailable?(); return }
            self.presenter?.present(controller, animated: true)
        }
        if let current = presenter.presentedViewController {
            guard current is UIAlertController else { unavailable?(); return }
            if current.isBeingDismissed, let transition = current.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in show() }
            } else {
                current.dismiss(animated: true, completion: show)
            }
        } else {
            show()
        }
    }

    private func showFailure(_ error: Error, retry: @escaping () -> Void) {
        guard canStartAction else { return }
        let alert = UIAlertController(
            title: "操作失败", message: "\(error.userFacingMessage)\n操作可能已部分生效，可重试。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.retry, style: .default) { _ in retry() })
        presentAlert(alert)
    }

    private func clearExport() {
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }
}
