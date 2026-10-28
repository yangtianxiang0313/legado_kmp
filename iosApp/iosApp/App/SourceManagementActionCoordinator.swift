import UIKit
import shared

enum SourceManagementOrderPlan {
    static func make(sources: [BookSource], sourceURLs: [String], toStart: Bool) throws -> [(sourceURL: String, order: Int32)] {
        let requested = Set(sourceURLs)
        let targets = sources.enumerated().filter { requested.contains($0.element.bookSourceUrl) }
            .sorted {
                $0.element.customOrder == $1.element.customOrder
                    ? $0.offset < $1.offset : $0.element.customOrder < $1.element.customOrder
            }.map(\.element)
        guard targets.count == requested.count, !targets.isEmpty else {
            throw NSError(
                domain: "io.legado.sourceManagement", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "书源列表已更新，请重新选择"])
        }
        let edge = (toStart ? sources.map(\.customOrder).min() : sources.map(\.customOrder).max()) ?? 0
        // Preflight every value before the first write. Never wrap the persisted Int32 order.
        return try targets.indices.map { index in
            let value = Int64(edge) + (toStart ? -1 : 1) * Int64(index + 1)
            guard let order = Int32(exactly: value) else {
                throw NSError(
                    domain: "io.legado.sourceManagement", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "书源排序已到边界"])
            }
            return (targets[index].bookSourceUrl, order)
        }
    }
}

/// BookSourceAdapter / BookSourceViewModel at Legado 5f5d314. Jobs retain a click-time URL snapshot.
@MainActor
final class SourceManagementActionCoordinator: NSObject, UIDocumentPickerDelegate {
    private weak var presenter: UIViewController?
    private let screen: SourceManagementScreenAdapter
    private let canStart: () -> Bool
    private let onBusyChange: (Bool) -> Void
    private let onChanged: () async -> Void
    private var task: Task<Void, Never>?
    private var lifetime = UUID()
    private var exportDirectory: URL?
    private weak var documentPicker: UIDocumentPickerViewController?
    private weak var activity: UIActivityViewController?

    init(
        presenter: UIViewController, screen: SourceManagementScreenAdapter,
        canStart: @escaping () -> Bool, onBusyChange: @escaping (Bool) -> Void,
        onChanged: @escaping () async -> Void
    ) {
        self.presenter = presenter
        self.screen = screen
        self.canStart = canStart
        self.onBusyChange = onBusyChange
        self.onChanged = onChanged
    }

    func move(sourceURLs: [String], toStart: Bool) {
        perform(changesSources: true) { [self] in
            let sources = try await screen.loadSources()
            let plan = try SourceManagementOrderPlan.make(sources: sources, sourceURLs: sourceURLs, toStart: toStart)
            var completed = 0
            do {
                for item in plan {
                    // Update only the order, not the stale full object (flags and rules can change independently).
                    try await screen.updateSourceOrder(sourceUrl: item.sourceURL, order: item.order)
                    completed += 1
                }
            } catch {
                throw NSError(
                    domain: "io.legado.sourceManagement", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "已更新 \(completed)/\(plan.count) 条排序。\n\(error.userFacingMessage)"])
            }
        }
    }

    func editGroup(sourceURLs: [String], removing: Bool) {
        guard canBegin, let presenter else { return }
        let id = lifetime
        let editor = SourceImportPreviewGroupViewController(
            groupName: nil, appendGroup: false, titleText: removing ? "移除分组" : "添加分组", showsAppendGroup: false)
        editor.onSave = { [weak self] name, _ in
            guard let self, self.lifetime == id, let name, !name.isEmpty else { return }
            self.perform(changesSources: true) { [self] in
                let sources = try await self.screen.loadSources()
                guard Set(sourceURLs).isSubset(of: Set(sources.map(\.bookSourceUrl))) else {
                    throw Self.missingSource()
                }
                if removing {
                    _ = try await self.screen.removeSourcesFromGroup(sourceUrls: sourceURLs, group: name)
                } else {
                    _ = try await self.screen.addSourcesToGroup(sourceUrls: sourceURLs, group: name)
                }
            }
        }
        presenter.present(editor, animated: true)
    }

    func login(sourceURL: String) {
        let id = lifetime
        perform(changesSources: false) { [self] in
            guard let source = try await screen.getSource(sourceUrl: sourceURL),
                source.hasManagementLoginURL
            else { throw Self.missingSource() }
            guard lifetime == id, isHostAttached, let presenter else { return }
            SourceLoginEntry.open(sourceURL: sourceURL, from: presenter)
        }
    }

    func export(sourceURLs: [String], sharing: Bool, anchor: UIView) {
        perform(changesSources: false) { [self, weak anchor] in
            let id = lifetime
            let sources = try await screen.loadSources()
            guard !sourceURLs.isEmpty, Set(sourceURLs).isSubset(of: Set(sources.map(\.bookSourceUrl))) else {
                throw Self.missingSource()
            }
            let payload = try await screen.exportSources(sourceUrls: sourceURLs)
            guard lifetime == id, isHostAttached, let presenter, let anchor,
                anchor.window === presenter.view.window, presenter.presentedViewController == nil
            else { return }
            cleanupExport()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Legado-SourceExport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            exportDirectory = directory
            let file = directory.appendingPathComponent("bookSource.json")
            do {
                try Data(payload.utf8).write(to: file, options: .atomic)
                if sharing {
                    let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    controller.popoverPresentationController?.sourceView = anchor
                    controller.popoverPresentationController?.sourceRect = anchor.bounds
                    controller.completionWithItemsHandler = { [weak self] _, _, _, error in
                        Task { @MainActor in
                            guard let self, self.lifetime == id else { return }
                            self.activity = nil
                            self.cleanupExport()
                            if let error, self.isHostAttached { self.presenter?.showTransientMessage(error.userFacingMessage) }
                        }
                    }
                    activity = controller
                    presenter.present(controller, animated: true)
                } else {
                    let controller = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
                    controller.delegate = self
                    documentPicker = controller
                    presenter.present(controller, animated: true)
                }
            } catch {
                cleanupExport()
                throw error
            }
        }
    }

    func cancelPresentation() {
        lifetime = UUID()
        documentPicker?.dismiss(animated: false)
        activity?.dismiss(animated: false)
        documentPicker = nil
        activity = nil
        cleanupExport()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishExport(controller) }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishExport(controller)
    }

    private func finishExport(_ controller: UIDocumentPickerViewController) {
        guard documentPicker === controller else { return }
        documentPicker = nil
        cleanupExport()
    }

    private func cleanupExport() {
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }

    private var canBegin: Bool { task == nil && canStart() && isHostAttached && presenter?.presentedViewController == nil }

    private var isHostAttached: Bool {
        guard let presenter, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            presenter.navigationController?.topViewController === presenter,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    private func perform(changesSources: Bool, operation: @escaping () async throws -> Void) {
        guard canBegin else { return }
        let id = lifetime
        onBusyChange(true)
        task = Task { @MainActor [self] in
            var failure: Error?
            do { try await operation() } catch { failure = error }
            if changesSources { await onChanged() }
            task = nil
            onBusyChange(false)
            if let failure, lifetime == id, isHostAttached, presenter?.presentedViewController == nil {
                presenter?.showTransientMessage(failure.userFacingMessage)
            }
        }
    }

    private static func missingSource() -> NSError {
        NSError(
            domain: "io.legado.sourceManagement", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "书源列表已更新，请重新选择"])
    }
}
