import SafariServices
import UIKit
import shared

extension ReaderContainerViewController {
    func showMoreSettingsSheet() {
        guard presentedViewController == nil, book != nil, runtimeConfig != nil,
            ReaderAppearanceSelectionContext.isVisible(self)
        else { return }
        setMenuVisible(false)
        let controller = ReaderMoreSettingsViewController()
        controller.bind(to: self)
        controller.setLocalSettings(ReaderLocalSettings.load())
        controller.onTapZoneConfig = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.showReaderTapZoneConfig() }
        }
        controller.onLocalSettingsChange = { [weak self] previous, settings in
            self?.applyReaderLocalSettingsChange(previous: previous, updated: settings)
        }
        controller.onReaderRuntimeConfigChange = { [weak self] _ in
            self?.refreshReaderRuntimeConfigPresentationSoon()
        }
        controller.onDisableReturnKeyChange = { [weak self] in
            self?.setMenuVisible(false)
        }
        controller.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
        let panel = ReaderBottomSheetNavigationController(contentViewController: controller, chromeStyle: .androidPanel)
        panel.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
        panel.preferredSheetHeight = ReaderMoreSettingsViewController.preferredSheetHeight
        present(panel, animated: true)
    }

    func showReaderAppearance() {
        guard presentedViewController == nil, book != nil, runtimeConfig != nil else { return }
        setMenuVisible(false)
        let controller = AndroidReaderStyleSheetViewController()
        controller.bind(to: self)
        controller.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
        controller.loadViewIfNeeded()
        let panel = ReaderBottomSheetNavigationController(contentViewController: controller, chromeStyle: .androidPanel)
        panel.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
        panel.preferredContentSize = controller.preferredContentSize
        present(panel, animated: true)
    }

    func showReaderTapZoneConfig() {
        setMenuVisible(false)
        let controller = ReaderTapZoneConfigViewController()
        controller.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        present(controller, animated: true)
    }

    func showRefreshMenu() {
        guard chapters.isEmpty == false else {
            showToast(L10n.BookDetail.emptyChapters)
            return
        }
        presentReaderContextMenu(
            anchor: readMenu.refreshMenuAnchor,
            items: [
                readerOverflowItem("menu_refresh_dur", title: L10n.Reader.refreshCurrent) { $0.reloadCurrentChapter() },
                readerOverflowItem("menu_refresh_after", title: L10n.Reader.refreshAfter) {
                    $0.refreshChapterCacheFromCurrent()
                },
                readerOverflowItem("menu_refresh_all", title: L10n.Reader.refreshAll) { $0.refreshAllChapterCache() },
            ])
    }

    func showReadAloudSheet() {
        guard let readerConfig = runtimeConfig?.reader else {
            showToast("朗读配置尚未加载，稍后再试")
            return
        }
        setMenuVisible(false)
        syncReadAloudVoice(from: readerConfig)
        let blocks = chapterReadAloudBlocks()
        readAloudService.updateBlocks(blocks)
        if blocks.isEmpty {
            showToast(readAloudEmptyContentMessage())
        }
        let controller = ReaderReadAloudSheetViewController(
            state: readAloudState,
            readerConfig: readerConfig,
            voiceOptions: readAloudService.availableVoiceOptions,
            onTogglePlayPause: { [weak self] in
                self?.stopAutoPage(showMessage: false)
                self?.toggleReadAloudPlayback()
            },
            onPreviousParagraph: { [weak self] in self?.skipReadAloudParagraph(previous: true) },
            onNextParagraph: { [weak self] in self?.skipReadAloudParagraph(previous: false) },
            onPreviousChapter: { [weak self] in self?.switchReadAloudChapter(previous: true) },
            onNextChapter: { [weak self] in self?.switchReadAloudChapter(previous: false) },
            onStop: { [weak self] in
                self?.readAloudService.pauseForUser()
                self?.runReadAloudTask { try await $0.stopReadAloud() }
            },
            onOpenChapterList: { [weak self] in self?.showChapterPicker() },
            onOpenMainMenu: { [weak self] in self?.setMenuVisible(true) },
            onOpenSettings: { [weak self] in self?.showReadAloudSettingsSheet() },
            onUpdateVoice: { [weak self] identifier in self?.updateReadAloudVoiceFromSheet(identifier) },
            onSetBackgroundPlayback: { [weak self] enabled in self?.setReadAloudBackgroundPlaybackFromSheet(enabled) },
            onUpdateSpeechRate: { [weak self] followSystem, value in
                self?.saveReadAloudSpeechRateFromSheet(followSystem: followSystem, value: value)
            },
            onUpdatePitch: { [weak self] pitch in self?.readAloudService.pitchMultiplier = pitch },
            onUpdateTimer: { [weak self] minutes in self?.saveReadAloudTimerFromSheet(minutes: minutes) },
            currentPitch: readAloudService.pitchMultiplier,
            availability: ReaderReadAloudSheetAvailability(
                chapterIndex: chapterIndex, chapterCount: chapters.count, blocks: blocks)
        )
        readAloudSheetController = controller
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 620), animated: true)
    }

    func showReadAloudSettingsSheet() {
        setMenuVisible(false)
        let controller = ReaderReadAloudSettingsViewController()
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: ReaderReadAloudSettingsViewController.preferredSheetHeight), animated: true)
    }

    func refreshReadAloudSheetAvailability() {
        guard let controller = readAloudSheetController else { return }
        controller.update(
            availability: ReaderReadAloudSheetAvailability(
                chapterIndex: chapterIndex,
                chapterCount: chapters.count,
                blocks: chapterReadAloudBlocks()
            ))
    }

    func showDownloadMenu() {
        guard presentedViewController == nil else { return }
        guard book?.isLocal != true else {
            showToast(L10n.Reader.downloadLocalUnavailable)
            return
        }
        guard chapters.isEmpty == false else {
            showToast(L10n.BookDetail.emptyChapters)
            return
        }
        let originalBookURL = bookURL
        let chapterURLs = chapters.map(\.url)
        let controller = ReaderDownloadChoiceDialogViewController(
            currentChapterIndex: chapterIndex, chapterCount: chapters.count
        ) { [weak self] start, end in
            guard let self, self.bookURL == originalBookURL,
                self.chapters.map(\.url) == chapterURLs,
                self.presentedViewController == nil, self.viewIfLoaded?.window != nil,
                self.navigationController?.topViewController === self
            else { return }
            self.startChapterDownload(startIndex: start, endIndex: end)
        }
        controller.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
        setMenuVisible(false)
        present(controller, animated: true)
    }

    func showChangeSourceMenu() {
        guard book?.isLocal != true else { return }
        presentReaderContextMenu(
            anchor: readMenu.changeSourceMenuAnchor,
            items: [
                readerOverflowItem("menu_chapter_change_source", title: L10n.Reader.chapterChangeSource) {
                    $0.presentReaderSourceChangePicker(mode: .chapter)
                },
                readerOverflowItem("menu_book_change_source", title: L10n.Reader.bookChangeSource) {
                    $0.presentReaderSourceChangePicker(mode: .book)
                },
            ])
    }

    func showSourceMenu() {
        guard canPresentReaderContextMenu, let book, !book.isLocal, !book.origin.isEmpty else { return }
        let origin = book.origin
        let originalBookURL = bookURL
        let index = readerActionChapterIndex
        let chapterURL = readerActionChapterURL
        let requestID = UUID()
        readerOverflowRequestID = requestID
        Task { @MainActor [weak self] in
            do {
                let facade = try SharedRuntime.sourceManagementFacade().get()
                let source = try await facade.getSourceAsync(sourceUrl: origin)
                guard let self, self.readerOverflowRequestID == requestID,
                    self.canPresentReaderContextMenu, self.bookURL == originalBookURL,
                    self.book?.origin == origin, self.readerActionChapterIndex == index,
                    self.readerActionChapterURL == chapterURL
                else { return }
                guard let source else {
                    self.showToast(L10n.BookDetail.editSourceUnavailable)
                    return
                }
                let chapter = self.chapters[safe: index]
                let actions = ReaderSourceMenuAction.visibleActions(
                    loginURL: source.loginUrl, isVIP: chapter?.isVip == true, isPaid: chapter?.isPay == true,
                    loginUI: source.loginUi)
                self.presentReaderContextMenu(
                    anchor: self.readMenu.sourceMenuAnchor,
                    items: actions.map { action in
                        self.readerOverflowItem(action.rawValue, title: action.title) { reader in
                            guard reader.bookURL == originalBookURL, reader.book?.origin == origin,
                                reader.readerActionChapterIndex == index, reader.readerActionChapterURL == chapterURL
                            else { return }
                            switch action {
                            case .login: reader.executeSourceLogin(origin: origin)
                            case .pay: reader.requestPayAction()
                            case .edit: reader.openSourceEditor(origin: origin)
                            case .disable: reader.disableSource(origin: origin)
                            }
                        }
                    })
            } catch {
                guard let self, self.readerOverflowRequestID == requestID, self.canPresentReaderContextMenu else {
                    return
                }
                self.showToast(error.userFacingMessage)
            }
        }
    }

    private var canPresentReaderContextMenu: Bool {
        ReaderMenuActionContext.canPresent(in: self)
    }

    private func presentReaderContextMenu(anchor: UIView?, items: [ReaderOverflowMenuView.Item]) {
        guard canPresentReaderContextMenu, let anchor, !anchor.isHidden, anchor.window != nil else { return }
        readerOverflowMenu?.dismiss()
        readerOverflowRequestID = UUID()
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: anchor, interfaceStyle: readMenu.overflowInterfaceStyle)
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

    func showBookChangeSourceFromMenu() {
        setMenuVisible(false)
        presentReaderSourceChangePicker(mode: .book)
    }

    func showBookmarkList() {
        setMenuVisible(false)
        let controller = BookmarkListViewController(screen: screen)
        controller.delegate = self
        navigationController?.pushViewController(controller.configuredForDrillDownPresentation(), animated: true)
    }

    func chapterReadAloudBlocks() -> [ReaderContentBlock] {
        return readAloudContent.blocks
    }

    func updateReadAloudHighlight(_ state: ReadAloudState) {
        if state.bookUrl == bookURL,
            Int(state.progress.chapterIndex) == chapterIndex,
            state.status == .running,
            let targetPage = readAloudContent.pageIndex(
                blockIndex: Int(state.progress.blockIndex),
                textOffset: Int(state.progress.utteranceRangeStart)
            ),
            targetPage != currentPageIndex
        {
            currentPageIndex = targetPage
        }
        renderView.highlightedBlockIndex = readAloudHighlightedBlockIndex()
        if pages.indices.contains(currentPageIndex) {
            renderCurrentPage()
        }
    }

    func readAloudHighlightedBlockIndex() -> Int? {
        guard let state = readAloudState,
            state.bookUrl == bookURL,
            Int(state.progress.chapterIndex) == chapterIndex
        else { return nil }
        switch state.status {
        case .running, .paused:
            return Int(state.progress.blockIndex)
        default:
            return nil
        }
    }

    private func executeSourceLogin(origin: String) {
        guard validateRemoteSourceOperation(origin: origin) else { return }
        SourceLoginEntry.open(sourceURL: origin, from: self)
    }

    private func requestPayAction() {
        guard let origin = book?.origin.trimmingCharacters(in: .whitespacesAndNewlines),
            validateRemoteSourceOperation(origin: origin)
        else { return }
        let index = readerActionChapterIndex
        guard chapters.indices.contains(index) else {
            showToast(L10n.BookDetail.emptyChapters)
            return
        }
        let originalBookURL = bookURL
        let screen = screen
        Task { @MainActor [weak self] in
            do {
                let action = try await screen.requestPayAction(index: index)
                guard let self, self.readerActionChapterIndex == index,
                    self.canCompleteSourceMenuAction(bookURL: originalBookURL, origin: origin)
                else { return }
                if let url = URL(string: action), action.hasPrefix("http") {
                    self.present(SFSafariViewController(url: url), animated: true)
                } else {
                    self.showToast(action.nilIfEmpty ?? "当前章节没有可执行的付费入口")
                }
            } catch {
                guard let self, self.readerActionChapterIndex == index,
                    self.canCompleteSourceMenuAction(bookURL: originalBookURL, origin: origin)
                else { return }
                self.showToast(error.userFacingMessage)
            }
        }
    }

    private func canCompleteSourceMenuAction(bookURL: String, origin: String) -> Bool {
        self.bookURL == bookURL && book?.origin == origin && !isBeingDismissed && !isMovingFromParent
            && viewIfLoaded?.window != nil && navigationController?.topViewController === self
            && presentedViewController == nil
    }

    private func openSourceEditor(origin: String) {
        guard validateRemoteSourceOperation(origin: origin) else { return }
        let editor = AndroidReplicaBookSourceEditViewController(mode: .edit(origin), screen: screen)
            .configuredForDrillDownPresentation()
        navigationController?.pushViewController(editor, animated: true)
    }

    private func disableSource(origin: String) {
        guard validateRemoteSourceOperation(origin: origin) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.setSourceEnabled(sourceUrl: origin, enabled: false)
                await MainActor.run { self.showToast(L10n.Reader.sourceDisableSuccess) }
            } catch {
                await MainActor.run { self.showToast(error.userFacingMessage) }
            }
        }
    }

    private func presentReaderSourceChangePicker(mode: ReaderSourceChangeMode = .book) {
        sourceChangeActions.presentReaderSourceChangePicker(mode: mode)
    }

    func showReplaceRuleMenu() {
        replaceRuleCoordinator.openManagement()
    }

    func toggleReplaceRule() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.screen.toggleReplaceRule()
                let payload = try await self.screen.loadChapter(index: self.chapterIndex)
                await MainActor.run {
                    self.book = updated
                    self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                    let isEnabled = self.isReplaceRuleEnabled(updated)
                    self.showToast(
                        isEnabled ? L10n.Reader.replaceRuleEnabledTitle : L10n.Reader.replaceRuleDisabledTitle)
                }
            } catch {
                await MainActor.run { self.showToast(error.userFacingMessage) }
            }
        }
    }

    func showEffectiveReplaceRules() {
        replaceRuleCoordinator.showEffectiveRules()
    }

    private func isReplaceRuleEnabled(_ book: Book?) -> Bool {
        book?.config.useReplaceRule?.boolValue ?? true
    }

    func toggleReadAloudPlayback() {
        switch readAloudState?.status {
        case .running:
            readAloudService.pauseForUser()
            runReadAloudTask { try await $0.pauseReadAloud() }
        case .paused:
            readAloudService.prepareForPlayback()
            runReadAloudTask { try await $0.resumeReadAloud() }
        default:
            startReadAloudFromCurrentPage()
        }
    }

    func toggleReadAloudFromMenu() {
        setMenuVisible(false)
        stopAutoPage(showMessage: false)
        toggleReadAloudPlayback()
    }

    func cancelPendingReaderSettingTasks() {
        readAloudRateSaveTask?.cancel()
        readAloudRateSaveTask = nil
        readAloudTimerSaveTask?.cancel()
        readAloudTimerSaveTask = nil
        readerBrightnessSaveTask?.cancel()
        readerBrightnessSaveTask = nil
    }

    func syncReadAloudVoice(from readerConfig: ReaderRuntimeConfig) {
        readAloudService.updateVoiceIdentifier(readerConfig.ttsVoiceIdentifier)
    }
}

extension ReaderContainerViewController: BookmarkListDelegate {
    func bookmarkList(_: BookmarkListViewController, didSelectChapterIndex index: Int, position: Int) {
        loadChapter(index: index, restorePosition: position)
    }
}
