import UIKit
import shared

extension AndroidReplicaBookshelfViewController {
    @objc func showBookshelfMoreMenu() {
        guard canPerformNavigationAction else { return }
        bookshelfOverflowMenu?.dismiss()
        let entries: [(String, String, String, () -> Void)] = [
            ("update", "更新目录", "ReaderMenuAndroidRefresh", { [weak self] in self?.refreshBooks() }),
            ("local", "添加本地", "BookshelfAndroidAdd", { [weak self] in self?.localBookImport.start() }),
            ("remote", "远程书籍", "BookshelfAndroidAdd", { [weak self] in self?.openRemoteBookshelf() }),
            (
                "addURL", "添加网址", "BookshelfAndroidAddOnline",
                { [weak self] in self?.bookshelfTransfer.addURLs() }
            ),
            (
                "manage", "书架管理", "BookshelfAndroidArrange",
                { [weak self] in
                    guard let self else { return }
                    self.navigationController?.pushViewController(
                        BookshelfManageViewController(groupID: self.screen.currentSelectedGroupId),
                        animated: true)
                }
            ),
            (
                "cache", "缓存/导出", "ReaderMenuAndroidDownload",
                { [weak self] in
                    self?.navigationController?.pushViewController(
                        CacheViewController(groupID: self?.screen.currentSelectedGroupId ?? -1)
                            .configuredForDrillDownPresentation(), animated: true)
                }
            ),
            (
                "groupManage", "分组管理", "BookDetailAndroidGroups",
                { [weak self] in self?.present(BookshelfGroupManagementViewController(), animated: true) }
            ),
            (
                "layout", "书架布局", "BookshelfAndroidLayout",
                { [weak self] in self?.showBookshelfLayoutDialog() }
            ),
            (
                "export", "导出书单", "BookshelfAndroidExport",
                { [weak self] in self?.bookshelfTransfer.exportBookshelf() }
            ),
            (
                "import", "导入书单", "BookshelfAndroidImport",
                { [weak self] in self?.bookshelfTransfer.importBookshelf() }
            ),
            (
                "log", "日志", "BookshelfAndroidLog",
                { [weak self] in
                    self?.present(ReaderAppLogDialogViewController(), animated: true)
                }
            ),
        ]
        let menu = ReaderOverflowMenuView(
            items: entries.map { id, title, asset, action in
                .init(
                    identifier: "bookshelf.more.\(id)", title: title, image: UIImage(named: asset),
                    handler: action)
            }, anchorView: bookshelfMoreAnchor, interfaceStyle: traitCollection.userInterfaceStyle)
        menu.onDismiss = { [weak self, weak menu] in
            guard let self else { return }
            if self.bookshelfOverflowMenu === menu { self.bookshelfOverflowMenu = nil }
            self.refreshBookshelfPresentationForMenu()
        }
        bookshelfOverflowMenu = menu
        menu.present(in: view)
        refreshBookshelfPresentationForMenu()
    }

    private func showBookshelfLayoutDialog() {
        guard let preferences else {
            showMessage(L10n.Common.loadingTitle)
            return
        }
        let modes: [BookshelfLayoutMode] = [.list, .grid3, .grid4, .grid5, .grid6]
        let draft = BookshelfLayoutDraft(
            layoutIndex: modes.firstIndex(of: layoutMode) ?? 1,
            sortIndex: Int(screen.currentBookshelfSortValue() ?? 0),
            showUnread: preferences.showUnread, showLastUpdateTime: preferences.showLastUpdateTime,
            groupStyleIndex: Int(preferences.bookGroupStyle),
            showWaitUpCount: preferences.showWaitUpCount,
            showBookshelfFastScroller: preferences.showBookshelfFastScroller)
        let controller = BookshelfLayoutDialogViewController(draft: draft) {
            [weak self, screen] draft in
            try await screen.applyLayoutDraft(draft)
            guard let self else { return }
            self.selectedBookshelfSort = Int32(draft.sortIndex)
            self.reloadGroupPages()
        }
        present(controller, animated: true)
    }

    private func openRemoteBookshelf() {
        navigationController?.pushViewController(
            RemoteBookViewController(screen: screen).configuredForDrillDownPresentation(), animated: true)
    }
}
