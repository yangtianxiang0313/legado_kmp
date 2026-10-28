import UIKit
import shared

@MainActor
final class BookshelfManageActions {
    private weak var presenter: BookshelfManageViewController?

    init(presenter: BookshelfManageViewController) { self.presenter = presenter }

    func manageGroups() {
        guard let presenter, presenter.canInteract else { return }
        let controller = BookshelfGroupManagementViewController()
        controller.onGroupsChanged = { [weak presenter] in presenter?.data.reload() }
        controller.onDismiss = { [weak presenter] in presenter?.presentationFinished() }
        presenter.present(controller, animated: true)
    }

    func selectGroups(bookURLs: [String], initial: Int64, additive: Bool) {
        guard let presenter, presenter.canInteract, !bookURLs.isEmpty else { return }
        do {
            let facade = try SharedRuntime.bookshelfFacade().get()
            weak var picker: AndroidReplicaBookDetailGroupPickerViewController?
            let controller = AndroidReplicaBookDetailGroupPickerViewController(
                groupID: initial,
                loadGroups: { try await facade.loadGroupsAsync() },
                saveGroup: { id, draft in
                    try await facade.saveGroupDetailsAsync(
                        groupId: id, name: draft.name, cover: draft.cover,
                        enableRefresh: draft.enableRefresh, bookSort: draft.bookSort)
                },
                deleteGroup: { try await facade.deleteGroupAsync(groupId: $0) },
                reorderGroups: { try await facade.reorderGroupsAsync(groupIds: $0.map { KotlinLong(longLong: $0) }) },
                observeGroups: { facade.watchSelectableGroups(onUpdate: $0) },
                commit: { [weak presenter] mask in
                    guard let presenter, let picker, presenter.presentedViewController === picker,
                        presenter.isVisibleInNavigationStack, !presenter.isBusy
                    else { throw CancellationError() }
                    let result =
                        try await
                        (additive
                        ? facade.addBooksToGroupAsync(bookUrls: bookURLs, groupId: mask)
                        : facade.updateBookGroupAsync(bookUrls: bookURLs, groupId: mask))
                    presenter.data.reload()
                    if result.failedCount > 0 { throw Self.failure(result) }
                })
            picker = controller
            controller.onGroupsChanged = { [weak presenter] in presenter?.data.reload() }
            controller.onDismiss = { [weak presenter] in presenter?.presentationFinished() }
            presenter.present(controller, animated: true)
        } catch { presenter.showTransientMessage(error.userFacingMessage) }
    }

    func setCanUpdate(bookURLs: [String], enabled: Bool) {
        presenter?.performOperation(enabled ? "允许更新" : "禁止更新") {
            let result = try await SharedRuntime.bookshelfFacade().get().updateBooksCanUpdateAsync(
                bookUrls: bookURLs, canUpdate: enabled)
            if result.failedCount > 0 { throw Self.failure(result) }
            return nil
        }
    }

    func confirmDelete(bookURLs: [String]) {
        guard let presenter, presenter.canInteract, !bookURLs.isEmpty else { return }
        let books = presenter.data.books.filter { bookURLs.contains($0.bookUrl) }
        guard !books.isEmpty else { return }
        let showsFileOption = books.count > 1 || books.contains(where: \.isLocal)
        let controller = BookshelfManageDeleteDialogViewController(showsFileOption: showsFileOption) { [weak presenter] deleteFiles in
            presenter?.performOperation("删除书籍") {
                let facade = try SharedRuntime.bookshelfFacade().get()
                let result =
                    try await
                    (deleteFiles
                    ? facade.removeBooksAndLocalFilesAsync(bookUrls: bookURLs)
                    : facade.removeBooksAsync(bookUrls: bookURLs))
                if result.failedCount > 0 { throw Self.failure(result) }
                return nil
            }
        }
        presenter.present(controller, animated: true)
    }

    func confirmClearCache(bookURLs: [String]) {
        guard let presenter, presenter.canInteract, !bookURLs.isEmpty else { return }
        let alert = UIAlertController(title: "清除缓存", message: "是否确认清除所选书籍的正文缓存？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak presenter] _ in
                presenter?.performOperation("清除缓存") {
                    let result = try await SharedRuntime.bookshelfFacade().get().clearCacheAsync(bookUrls: bookURLs)
                    if result.failedCount > 0 { throw Self.failure(result) }
                    return "缓存已清除"
                }
            })
        presenter.present(alert, animated: true)
    }

    func toggleOpenTitle() {
        guard let presenter else { return }
        let enabled = !presenter.data.openTitle
        presenter.performOperation("保存设置") {
            try await SharedRuntime.settingsFacade().get().setOpenBookInfoByClickTitleAsync(enabled: enabled)
            return nil
        }
    }

    func exportSources() {
        guard let presenter else { return }
        var file: URL?
        presenter.performOperation(
            "导出书源",
            operation: {
                let json = try await SharedRuntime.bookshelfFacade().get().exportUsedSourcesAsync(groupId: -1)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("bookSource.json")
                try Data(json.utf8).write(to: url, options: .atomic)
                file = url
                return nil
            },
            completion: { [weak presenter] in
                guard let presenter, let file, presenter.presentedViewController == nil else { return }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = presenter.toolbar.moreButton
                share.popoverPresentationController?.sourceRect = presenter.toolbar.moreButton.bounds
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                presenter.present(share, animated: true)
            })
    }

    func changeSource(bookURLs: [String]) {
        guard let presenter, presenter.canInteract else { return }
        let controller = BookshelfManageSourcePickerViewController(delay: presenter.data.delaySeconds) { [weak presenter] source, delay in
            guard let presenter else { return }
            presenter.performOperation("批量换源", cancellable: true) { [weak presenter] in
                let result = try await SharedRuntime.bookshelfFacade().get().changeSourceCancellableAsync(
                    bookUrls: bookURLs, sourceUrl: source.bookSourceUrl, delayMillis: Int64(delay) * 1000,
                    onProgress: { current, total in
                        DispatchQueue.main.async { presenter?.updateOperationProgress(current.int32Value, total: total.int32Value) }
                    })
                return L10n.Bookshelf.changeSourceResult(
                    updatedCount: Int(result.updatedCount), skippedCount: Int(result.skippedCount), failedCount: Int(result.failedCount))
            }
        }
        presenter.present(controller, animated: true)
    }

    private static func failure(_ result: BookshelfBatchUpdateResult) -> Error {
        NSError(
            domain: "io.legado.kmp.bookshelf", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    L10n.Bookshelf.batchResult(successCount: Int(result.updatedCount), failedCount: Int(result.failedCount))
            ])
    }
}
