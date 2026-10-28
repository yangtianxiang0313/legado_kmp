import SafariServices
import UIKit
import shared

extension ReaderContainerViewController {
    func continueReadAloudAfterChapterEndIfNeeded(previous: ReadAloudState?, current: ReadAloudState) {
        guard previous?.status == .running,
            current.status == .stopped,
            current.message == "Read aloud chapter completed",
            Int(current.progress.chapterIndex) == chapterIndex,
            pendingReadAloudChapterRestart == false
        else { return }
        guard chapterIndex + 1 < chapters.count else {
            showToast("朗读已到最后一章")
            return
        }
        pendingReadAloudChapterRestart = true
        pendingReadAloudShouldPauseAfterRestart = false
        pendingReadAloudBackgroundPlayback = current.isBackgroundPlaybackEnabled
        openNextChapter()
    }

    func switchReadAloudChapter(previous: Bool) {
        let status = readAloudState?.status
        if previous, chapterIndex <= 0 {
            showToast("已经是第一章")
            return
        }
        if previous == false, chapterIndex >= chapters.count - 1 {
            showToast("已经是最后一章")
            return
        }
        guard status == .running || status == .paused else {
            previous ? openPreviousChapter(toLast: false) : openNextChapter()
            return
        }
        pendingReadAloudChapterRestart = true
        pendingReadAloudShouldPauseAfterRestart = status == .paused
        pendingReadAloudBackgroundPlayback = readAloudState?.isBackgroundPlaybackEnabled ?? false
        #if DEBUG
            SharedRuntime.log("Read aloud chapter switch paused=\(status == .paused) index=\(chapterIndex)")
        #endif
        readAloudService.apply(state: nil)
        chapterLoadCoordinator.load(
            in: self, index: chapterIndex + (previous ? -1 : 1), restorePosition: 0,
            stopsReadAloud: true
        )
    }

    func restartReadAloudAfterChapterSwitchIfNeeded() {
        guard pendingReadAloudChapterRestart else { return }
        let shouldPause = pendingReadAloudShouldPauseAfterRestart
        let backgroundPlayback = pendingReadAloudBackgroundPlayback
        #if DEBUG
            SharedRuntime.log("Read aloud chapter restart paused=\(shouldPause) index=\(chapterIndex)")
        #endif
        clearPendingReadAloudChapterRestart()
        let blocks = chapterReadAloudBlocks()
        guard blocks.isEmpty == false else {
            if chapterContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showToast("切换后的章节没有正文内容，朗读已停止")
            } else {
                showToast("切换后的章节没有可朗读段落，朗读已停止")
            }
            return
        }
        if let config = runtimeConfig?.reader {
            syncReadAloudVoice(from: config)
        }
        readAloudService.updateBlocks(blocks)
        let safePageIndex = min(max(currentPageIndex, 0), max(pages.count - 1, 0))
        let startBlock = pages[safe: safePageIndex]?.leadingBlockIndex ?? Int(blocks.first?.blockIndex ?? 0)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard !MediaPlaybackOwnership.shared.hasOwner || MediaPlaybackOwnership.shared.owns(readAloudService) else {
                    return
                }
                readAloudService.prepareForPlayback()
                try await self.screen.startReadAloud(
                    chapterIndex: self.chapterIndex,
                    blocks: blocks,
                    startBlockIndex: startBlock,
                    startTextOffset: 0,
                    preferBackgroundPlayback: backgroundPlayback,
                    ttsEngine: self.runtimeConfig?.ttsEngine,
                    startPaused: shouldPause
                )
            } catch {
                await MainActor.run { [weak self] in self?.showToast(error.userFacingMessage) }
            }
        }
    }

    func clearPendingReadAloudChapterRestart() {
        pendingReadAloudChapterRestart = false
        pendingReadAloudShouldPauseAfterRestart = false
        pendingReadAloudBackgroundPlayback = false
    }

    func showReaderOperationMenu() {
        readerOverflowRequestID = UUID()
        let requestID = readerOverflowRequestID
        guard ReaderMenuActionContext.canPresent(in: self) else { return }
        let context = ReaderMenuActionContext(self)
        if let readerOverflowMenu {
            readerOverflowMenu.dismiss()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let isWebDavConfigured = await self.screen.isWebDavConfigured()
            guard context.matches(self),
                self.readerOverflowRequestID == requestID,
                self.viewIfLoaded?.window != nil,
                self.presentedViewController == nil,
                self.readerOverflowMenu == nil
            else { return }
            self.presentReaderOperationMenu(isWebDavConfigured: isWebDavConfigured)
        }
    }

    private func presentReaderOperationMenu(isWebDavConfigured: Bool) {
        guard let book else { return }
        let hasChapter = chapters.indices.contains(chapterIndex)
        let replaceEnabled =
            book.config.useReplaceRule?.boolValue
            ?? (!(book.isImage || book.isEpub) && (runtimeConfig?.replaceRuleEnabledByDefault ?? true))
        var items: [ReaderOverflowMenuView.Item] = [
            readerOverflowItem(
                "menu_add_bookmark", title: L10n.ReaderAppearance.tapActionAddBookmark,
                isEnabled: pages.indices.contains(currentPageIndex)
            ) {
                $0.addBookmarkAtCurrentPage()
            },
            readerOverflowItem("menu_edit_content", title: L10n.Reader.editContent, isEnabled: hasChapter) {
                $0.presentReaderContentEditorFromOperation()
            },
            readerOverflowItem(
                "menu_page_anim", title: NSLocalizedString("reader.book_page_anim", value: "翻页动画（本书）", comment: ""),
                isEnabled: runtimeConfig != nil
            ) {
                $0.showReaderPageAnimationOperationMenu()
            },
        ]
        if isWebDavConfigured {
            items.append(contentsOf: [
                readerOverflowItem("menu_get_progress", title: L10n.WebDav.getCloudProgress) {
                    $0.getReaderCloudProgressFromOperation()
                },
                readerOverflowItem(
                    "menu_cover_progress", title: L10n.WebDav.overrideCloudProgress, isEnabled: hasChapter
                ) {
                    $0.uploadReaderCloudProgressFromOperation()
                },
            ])
        }
        if book.isLocal == false {
            items.append(
                readerOverflowItem(
                    "menu_reverse_content", title: L10n.Reader.reverseContentTitle, isEnabled: hasChapter
                ) {
                    $0.confirmReverseCurrentChapterContent()
                })
        }
        items.append(contentsOf: [
            readerOverflowItem("menu_simulated_reading", title: "模拟追读") {
                $0.bookSettingsCoordinator.presentSimulation()
            },
            readerOverflowItem(
                "menu_enable_replace",
                title: NSLocalizedString("reader.replace_rule_title", value: "替换净化", comment: ""),
                isChecked: replaceEnabled,
                isEnabled: hasChapter
            ) {
                $0.toggleReplaceRule()
            },
            readerOverflowItem(
                "menu_same_title_removed", title: L10n.Reader.removeDuplicateTitleTitle,
                isChecked: currentChapterSameTitleRemoved, isEnabled: hasChapter
            ) {
                $0.toggleReaderRemoveSameTitle()
            },
            readerOverflowItem(
                "menu_re_segment", title: L10n.Reader.reSegment, isChecked: book.config.reSegment, isEnabled: hasChapter
            ) {
                $0.toggleReaderReSegment()
            },
        ])
        if book.isEpub {
            items.append(contentsOf: [
                readerOverflowItem(
                    "menu_del_ruby_tag", title: L10n.Reader.deleteRubyTagTitle, isChecked: isReaderDelTagEnabled(4),
                    isEnabled: hasChapter
                ) {
                    $0.toggleReaderDelTag(tag: 4, title: L10n.Reader.deleteRubyTagTitle)
                },
                readerOverflowItem(
                    "menu_del_h_tag", title: L10n.Reader.deleteHTagTitle, isChecked: isReaderDelTagEnabled(2),
                    isEnabled: hasChapter
                ) {
                    $0.toggleReaderDelTag(tag: 2, title: L10n.Reader.deleteHTagTitle)
                },
            ])
        }
        items.append(contentsOf: [
            readerOverflowItem("menu_image_style", title: L10n.Reader.imageStyleTitle, isEnabled: hasChapter) {
                $0.showImageStyleOperationMenu()
            },
            readerOverflowItem(
                "menu_update_toc", title: NSLocalizedString("reader.update_toc", value: "更新目录", comment: "")
            ) {
                $0.refreshReaderChapterList()
            },
            readerOverflowItem(
                "menu_effective_replaces",
                title: NSLocalizedString("reader.effective_replaces", value: "起效的替换", comment: "")
            ) {
                $0.showEffectiveReplaceRules()
            },
            readerOverflowItem("menu_log", title: L10n.Bookshelf.logTitle) {
                $0.showReaderLogsFromOperation()
            },
            readerOverflowItem("menu_help", title: L10n.Reader.menuHelp) {
                $0.showReaderHelpFromOperation()
            },
        ])
        let menu = ReaderOverflowMenuView(
            items: items,
            anchorView: readMenu.overflowAnchorView,
            interfaceStyle: readMenu.overflowInterfaceStyle
        )
        let context = ReaderMenuActionContext(self)
        menu.canActivateItem = { [weak self] in self.map(context.matches) == true }
        menu.onDismiss = { [weak self, weak menu] in
            guard self?.readerOverflowMenu === menu else { return }
            self?.readerOverflowMenu = nil
            self?.readerOverflowRequestID = UUID()
        }
        readerOverflowMenu = menu
        menu.present(in: view)
    }

    func readerOverflowItem(
        _ identifier: String,
        title: String,
        isChecked: Bool? = nil,
        isEnabled: Bool = true,
        action: @escaping (ReaderContainerViewController) -> Void
    ) -> ReaderOverflowMenuView.Item {
        let context = ReaderMenuActionContext(self)
        return ReaderOverflowMenuView.Item(
            identifier: identifier, title: title, isChecked: isChecked, isEnabled: isEnabled
        ) { [weak self] in
            guard let self, context.matches(self) else { return }
            self.readerOverflowMenu?.dismiss()
            self.setMenuVisible(false)
            action(self)
        }
    }

    private func getReaderCloudProgressFromOperation() {
        progressSyncCoordinator.getCloudProgressManually()
    }

    private func uploadReaderCloudProgressFromOperation() {
        progressSyncCoordinator.uploadCloudProgressManually()
    }

    private func showReaderLogsFromOperation() {
        runReaderOperation {
            let facade: LogFacade
            switch SharedRuntime.logFacade() {
            case .success(let value): facade = value
            case .failure(let error): throw error
            }
            let entries = try await facade.loadEntriesAsync()
            await MainActor.run {
                guard self.viewIfLoaded?.window != nil, self.presentedViewController == nil else { return }
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .medium
                let message = entries.reversed().map { entry in
                    let date = Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000)
                    return "\(formatter.string(from: date)) [\(entry.level)/\(entry.tag)]\n\(entry.message)"
                }.joined(separator: "\n\n")
                let alert = UIAlertController(
                    title: L10n.Bookshelf.logTitle, message: message.nilIfEmpty ?? L10n.Bookshelf.logEmpty,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.Common.close, style: .cancel))
                self.present(alert, animated: true)
            }
        }
    }

    private func showReaderHelpFromOperation() {
        guard
            let url = URL(
                string:
                    "https://github.com/gedoor/legado/blob/5f5d31404af9957684703747ecee2b91e7161f1d/app/src/main/assets/web/help/md/readMenuHelp.md"
            )
        else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    func readerOperationStateSummary() -> String {
        let reSegment = operationStateText(book?.config.reSegment ?? false)
        let tags = [
            L10n.Reader.removeDuplicateTitleTitle: currentChapterSameTitleRemoved,
            L10n.Reader.deleteRubyTagTitle: isReaderDelTagEnabled(4),
            L10n.Reader.deleteHTagTitle: isReaderDelTagEnabled(2),
        ]
        let enabledTags =
            tags
            .filter(\.value)
            .map(\.key)
            .joined(separator: " / ")
            .nilIfEmpty ?? L10n.Settings.disabled
        return [
            "\(L10n.Reader.reSegment): \(reSegment)",
            "\(L10n.Reader.setCharsetTitle): \(currentReaderCharsetText())",
            "\(L10n.Reader.imageStyleTitle): \(currentReaderImageStyleText())",
            "\(L10n.ReaderAppearance.pageAnimationTitle): \(currentReaderPageAnimationText())",
            "Tag: \(enabledTags)",
        ].joined(separator: " · ")
    }

    private func showReaderPageAnimationOperationMenu() {
        pageAnimationSelectionCoordinator.present()
    }

    func presentReaderContentEditorFromOperation(presenter: UIViewController? = nil) {
        contentEditingCoordinator.present(from: presenter)
    }

    private func confirmReverseCurrentChapterContent() {
        guard chapters.indices.contains(chapterIndex) else {
            showToast("当前没有可反转的章节")
            return
        }
        let alert = UIAlertController(
            title: L10n.Reader.reverseContentTitle,
            message: L10n.Reader.reverseContentConfirmMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Reader.reverseContentTitle, style: .destructive) { [weak self] _ in
                self?.reverseCurrentChapterContent()
            })
        present(alert, animated: true)
    }

    private func reverseCurrentChapterContent() {
        guard chapters.indices.contains(chapterIndex) else {
            showToast("当前没有可反转的章节")
            return
        }
        runReaderOperation {
            let payload = try await self.screen.reverseContent(chapterIndex: self.chapterIndex)
            await MainActor.run {
                self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                self.showToast(L10n.Reader.reverseContentMessage)
            }
        }
    }

    private func toggleReaderReSegment() {
        guard book != nil else {
            showToast("当前书籍信息尚未加载，稍后再试")
            return
        }
        runReaderOperation {
            let updated = try await self.screen.toggleReSegment()
            let payload = try await self.screen.refreshChapter(index: self.chapterIndex)
            await MainActor.run {
                self.book = updated
                self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                self.showToast(updated.config.reSegment ? L10n.Reader.reSegmentEnabled : L10n.Reader.reSegmentDisabled)
            }
        }
    }

    private func toggleReaderRemoveSameTitle() {
        guard chapters.indices.contains(chapterIndex) else {
            showToast("当前没有可刷新的章节")
            return
        }
        runReaderOperation {
            let next = !self.currentChapterSameTitleRemoved
            try await self.screen.setRemoveSameTitle(chapterIndex: self.chapterIndex, removeSameTitle: next)
            let payload = try await self.screen.loadChapter(index: self.chapterIndex)
            await MainActor.run {
                self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                self.showToast(
                    next
                        ? L10n.Reader.readerOperationEnabled(L10n.Reader.removeDuplicateTitleTitle)
                        : L10n.Reader.readerOperationDisabled(L10n.Reader.removeDuplicateTitleTitle)
                )
            }
        }
    }

    private func toggleReaderDelTag(tag: Int64, title: String) {
        guard book != nil else {
            showToast("当前书籍信息尚未加载，稍后再试")
            return
        }
        runReaderOperation {
            let updated = try await self.screen.toggleDelTag(tag: tag)
            let payload = try await self.screen.refreshAllChapterContent(currentIndex: self.chapterIndex)
            await MainActor.run {
                self.book = updated
                self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                let isEnabled = (updated.config.delTag & tag) == tag
                self.showToast(
                    isEnabled ? L10n.Reader.readerOperationEnabled(title) : L10n.Reader.readerOperationDisabled(title))
            }
        }
    }

    func showCharsetOperationMenu() {
        bookSettingsCoordinator.presentCharset()
    }

    func showImageStyleOperationMenu() {
        bookSettingsCoordinator.presentImageStyle()
    }

    private func refreshReaderChapterList() {
        guard book != nil else {
            showToast("当前书籍信息尚未加载，无法刷新目录")
            return
        }
        runReaderOperation {
            let items = try await self.chapterListRefreshCoordinator.refresh(in: self)
            try Task.checkCancellation()
            await MainActor.run {
                self.showToast(
                    items.isEmpty ? L10n.BookDetail.emptyChapters : L10n.Reader.refreshTocResult(items.count))
            }
        }
    }

    private func confirmClearReaderBookCache() {
        guard let bookURL = book?.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines), bookURL.isEmpty == false
        else {
            showToast("当前书籍路径为空，无法清理缓存")
            return
        }
        let alert = UIAlertController(
            title: L10n.BookDetail.clearCacheConfirmTitle,
            message: "\(L10n.BookDetail.clearCacheConfirmMessage)\n\n\(L10n.Reader.clearCacheConfirmReaderMessage)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.BookDetail.clearCache, style: .destructive) { [weak self] _ in
                self?.clearReaderBookCache(bookURL: bookURL)
            })
        present(alert, animated: true)
    }

    private func clearReaderBookCache(bookURL: String) {
        runReaderOperation {
            let facade = try self.readerBookDetailFacade()
            try await facade.clearCacheAsync(bookUrl: bookURL)
            await MainActor.run {
                self.showToast(L10n.BookDetail.clearCacheDone)
            }
        }
    }

    private func readerBookDetailFacade() throws -> BookDetailFacade {
        switch SharedRuntime.bookDetailFacade() {
        case .success(let facade):
            return facade
        case .failure(let error):
            throw error
        }
    }

    private func addCurrentBookToBookshelf() {
        guard isInBookshelf == false else {
            showToast(L10n.Reader.addToBookshelfTitle)
            return
        }
        runReaderOperation {
            let added = try await self.screen.addToBookshelf()
            await MainActor.run {
                self.book = added
                self.isInBookshelf = true
                self.showToast(L10n.Reader.addToBookshelfSuccess)
            }
        }
    }

    private func runReaderOperation(_ operation: @escaping () async throws -> Void) {
        loadingIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                await MainActor.run { self.loadingIndicator.stopAnimating() }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                await MainActor.run {
                    self.loadingIndicator.stopAnimating()
                    self.showToast(error.userFacingMessage)
                }
            }
        }
    }

    private func isReaderDelTagEnabled(_ tag: Int64) -> Bool {
        guard let delTag = book?.config.delTag else { return false }
        return (delTag & tag) == tag
    }

    private func currentReaderCharsetText() -> String {
        normalizedReaderCharset(book?.charset)
    }

    private func normalizedReaderCharset(_ charset: String?) -> String {
        charset?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.uppercased() ?? "AUTO"
    }

    private func currentReaderImageStyleText() -> String {
        (book?.config.imageStyle?.nilIfEmpty ?? "DEFAULT").uppercased()
    }

    private func operationStateText(_ enabled: Bool) -> String {
        enabled ? L10n.Settings.enabled : L10n.Settings.disabled
    }

    private func operationToggleTitle(_ title: String, enabled: Bool) -> String {
        "\(title) · \(operationStateText(enabled))"
    }
}
