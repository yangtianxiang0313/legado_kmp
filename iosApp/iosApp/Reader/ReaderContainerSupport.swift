import UIKit
import shared

final class ReaderAccessibilitySurfaceView: UIView {
    var accessibilityText: String = "" {
        didSet {
            let normalized = accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines)
            accessibilityLabel = normalized
            accessibilityValue = normalized
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { [.staticText] }
        set {}
    }
}

enum ReaderSearchMenuText {
    static let previousResult = L10n.Reader.searchPreviousResult
    static let nextResult = L10n.Reader.searchNextResult
    static let results = L10n.Reader.searchResultsAction
    static let mainMenu = L10n.Reader.searchMainMenuAction
    static let exit = L10n.Reader.searchExitAction

    static func info(current: Int, total: Int, chapterTitle: String) -> String {
        L10n.Reader.searchNavigationInfo(current: current, total: total, chapterTitle: chapterTitle)
    }
}

enum ReaderImageActionText {
    static let title = L10n.Reader.imageActionTitle
    static let show = L10n.Reader.imageActionShow
    static let refresh = L10n.Reader.imageActionRefresh
    static let save = L10n.Reader.imageActionSave
    static let mainMenu = L10n.Reader.imageActionMainMenu
    static let loading = L10n.Reader.imageActionLoading
    static let refreshed = L10n.Reader.imageActionRefreshed
    static let saved = L10n.Reader.imageActionSaved
    static let saveFailed = L10n.Reader.imageActionSaveFailed
    static let dayTheme = L10n.Reader.menuDayTheme
}

extension ReaderContainerViewController {
    func applyReaderLocalSettingsChange(previous: ReaderLocalSettings, updated: ReaderLocalSettings) {
        if previous.screenTimeout != updated.screenTimeout {
            applyReaderScreenTimeout(updated.screenTimeout)
        }
        if previous.touchSensitivity != updated.touchSensitivity {
            readerTapGesture?.maximumMovement = updated.touchSensitivity.tapAllowableMovement
            scrollTapGesture?.maximumMovement = updated.touchSensitivity.tapAllowableMovement
        }
        if previous.screenOrientation != updated.screenOrientation {
            applyReaderOrientationPreference(updated)
        }
        if previous.brightnessAuto != updated.brightnessAuto {
            applyReaderBrightnessIfNeeded(localSettings: updated)
        }
        if previous.textSelectable != updated.textSelectable, updated.textSelectable == false {
            dismissTextSelectionMenu(clearSelection: true)
        }

        let chromeSettingsChanged =
            previous.showBrightnessBar != updated.showBrightnessBar
            || previous.brightnessAuto != updated.brightnessAuto
            || previous.brightnessOnRight != updated.brightnessOnRight
            || previous.showTitleAddition != updated.showTitleAddition
            || previous.progressBehavior != updated.progressBehavior
        if chromeSettingsChanged {
            readMenu.reloadLocalSettings()
            readMenu.updateMenuProgress(
                page: currentPageIndex, pageCount: pages.count, chapter: chapterIndex,
                chapterCount: ReaderSimulatedReadingPolicy.count(in: self))
            refreshChromeSnapshot(force: true)
        }

        if previous.doubleHorizontalPage != updated.doubleHorizontalPage {
            repaginate(restoreLocation: currentCharacterOffset())
        }
    }

    func applyReaderScreenTimeout(_ timeout: ReaderScreenTimeout) {
        screenTimeoutTimer?.invalidate()
        screenTimeoutTimer = nil
        switch isAutoPageRunning ? ReaderScreenTimeout.always : timeout {
        case .system:
            UIApplication.shared.isIdleTimerDisabled = RestoredAppPreferences.keepScreenOn
        case .always:
            UIApplication.shared.isIdleTimerDisabled = true
        case .oneMinute, .fiveMinutes, .tenMinutes:
            UIApplication.shared.isIdleTimerDisabled = true
            let timer = Timer(timeInterval: TimeInterval(timeout.seconds ?? 0), repeats: false) { [weak self] _ in
                guard let self else { return }
                UIApplication.shared.isIdleTimerDisabled = RestoredAppPreferences.keepScreenOn
                self.screenTimeoutTimer = nil
            }
            RunLoop.main.add(timer, forMode: .common)
            screenTimeoutTimer = timer
        }
    }

    func resetReaderScreenTimeoutTimer() {
        applyReaderScreenTimeout(ReaderLocalSettings.load().screenTimeout)
    }

    func cancelReaderScreenTimeout() {
        screenTimeoutTimer?.invalidate()
        screenTimeoutTimer = nil
        UIApplication.shared.isIdleTimerDisabled = RestoredAppPreferences.keepScreenOn
    }

    func refreshReaderRuntimeConfigPresentationSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.applyTheme()
            self.repaginate(restoreLocation: self.currentCharacterOffset())
        }
    }

    func doubleHorizontalPageMode(in bounds: CGRect) -> ReaderDoubleHorizontalPageMode {
        let mode = ReaderLocalSettings.load().doubleHorizontalPage
        let pageAnimation = effectiveReaderPageAnimation()
        return mode.shouldActivate(
            in: bounds,
            pageAnimation: pageAnimation,
            userInterfaceIdiom: traitCollection.userInterfaceIdiom
        ) ? mode : .singlePage
    }

    func shouldUseDualPageMode(in bounds: CGRect) -> Bool {
        doubleHorizontalPageMode(in: bounds).isEnabledForLegacyDualPageMode
    }

    func paginationBounds(for bounds: CGRect, doubleHorizontalPageMode: ReaderDoubleHorizontalPageMode) -> CGRect {
        guard doubleHorizontalPageMode.isEnabledForLegacyDualPageMode else { return bounds }
        return ReaderSpreadGeometry(bounds: bounds, theme: readerRenderTheme()).paginationBounds
    }

    func paginationBounds(for bounds: CGRect, dualPageMode: Bool) -> CGRect {
        paginationBounds(
            for: bounds,
            doubleHorizontalPageMode: ReaderDoubleHorizontalPageMode.fromLegacyDualPageMode(dualPageMode)
        )
    }

    func nonScrollPageStep() -> Int {
        let bounds = renderView.bounds.width > 0 ? renderView.bounds : view.bounds
        return shouldUseDualPageMode(in: bounds) ? 2 : 1
    }

    func sourceMenuMessage(origin: String, chapterURL: String, isLocalBook: Bool) -> String {
        if isLocalBook {
            return "本地书：可复制文件/书籍路径，书源登录、付费、Cookie、换源等网络源操作不可用。"
        }
        if origin.isEmpty {
            return "当前书籍没有关联书源，无法执行登录、付费、清 Cookie 或换源。"
        }
        if let chapterURL = chapterURL.nilIfEmpty {
            return chapterURL
        }
        return L10n.Reader.chapterSourceInfoUnavailable
    }

    func sourceUnavailableReason(origin: String, isLocalBook: Bool) -> String {
        if isLocalBook {
            return "本地书不关联网络书源"
        }
        if origin.isEmpty {
            return L10n.BookDetail.editSourceUnavailable
        }
        return L10n.Reader.unavailable
    }

    func disabledSourceAction(title: String, systemImage: String, reason: String) -> AndroidSourceMenuSheetViewController.Action {
        .init(
            title: title,
            systemImage: systemImage,
            detail: reason,
            isEnabled: false,
            isDestructive: false
        ) {}
    }

    func validateRemoteSourceOperation(origin: String) -> Bool {
        if book?.isLocal == true {
            showToast("本地书不关联网络书源")
            return false
        }
        if origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showToast(L10n.BookDetail.editSourceUnavailable)
            return false
        }
        return true
    }
}

extension DateFormatter {
    static let readerChromeTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension ReaderContainerViewController {
    func configureSearchMenuCallbacks() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeSearchSelection(_:)), name: UIScene.didActivateNotification, object: nil)
        searchMenu.canInteract = { [weak self] in
            guard let self else { return false }
            return self.canNavigateReaderPages && self.presentedViewController == nil
                && ReaderAppearanceSelectionContext.isVisible(self)
        }
        searchMenu.onResultSelected = { [weak self] result in
            self?.openSearchResult(result)
        }
        searchMenu.onOpenResultList = { [weak self] query, results, focusedIndex in
            self?.showSearchContent(query: query, cachedResults: results, focusedResultIndex: focusedIndex)
        }
        searchMenu.onOpenMainMenu = { [weak self] in
            self?.clearSearchSelection()
            self?.setMenuVisible(true)
        }
        searchMenu.onExit = { [weak self] in
            self?.jumpNavigationCoordinator.endSearch()
            self?.clearSearchSelection()
        }
    }

    func showSearchMenu() {
        showSearchMenu(query: nil)
    }

    func showSearchMenu(query: String?) {
        setMenuVisible(false)
        searchMenu.open(query: query?.nilIfEmpty ?? "", currentChapterIndex: chapterIndex)
    }

    func showSearchContent(
        query: String?,
        cachedResults: [ContentSearchResult] = [],
        focusedResultIndex: Int? = nil
    ) {
        guard presentedViewController == nil else {
            showToast("请先关闭当前面板后再搜索正文")
            return
        }
        jumpNavigationCoordinator.prepareSearch(in: self)
        let controller = SearchContentViewController(
            screen: screen,
            initialQuery: query?.nilIfEmpty,
            currentChapterIndex: chapterIndex,
            cachedResults: cachedResults,
            focusedResultIndex: focusedResultIndex,
            options: searchMenu.options,
            cachedResultOptions: searchMenu.resultOptions
        )
        let expectedBookURL = bookURL
        let expectedOrigin = book?.origin
        let restoresSearchMenu = jumpNavigationCoordinator.isShowingSearchResults
        controller.canOpenResult = { [weak self] in
            guard let self else { return false }
            return self.bookURL == expectedBookURL && self.book?.bookUrl == expectedBookURL
                && self.book?.origin == expectedOrigin && !self.isMovingFromParent && !self.isBeingDismissed
                && self.navigationController?.topViewController === self
        }
        controller.delegate = self
        controller.onOptionsChanged = { [weak self] options in
            guard let self, self.bookURL == expectedBookURL, self.book?.origin == expectedOrigin else { return }
            self.searchMenu.options = options
        }
        controller.onClose = { [weak self] in
            self?.jumpNavigationCoordinator.cancelPreparedSearch()
            guard restoresSearchMenu, !cachedResults.isEmpty, let self, self.bookURL == expectedBookURL,
                self.book?.origin == expectedOrigin,
                self.navigationController?.topViewController === self, self.searchMenu.hasResults
            else { return }
            self.searchMenu.setVisible(true, currentChapterIndex: self.chapterIndex)
        }
        searchMenu.setVisible(false, currentChapterIndex: chapterIndex)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    func openSearchResult(_ result: ContentSearchResult) {
        guard navigationController?.topViewController === self, !isBeingDismissed, !isMovingFromParent,
            chapters.contains(where: { $0.index == result.chapterIndex })
        else { return }
        textSelectionCoordinator.dismiss(clearSelection: true)
        searchSelectionRequestID = UUID()
        shouldPresentSearchSelection = true
        jumpNavigationCoordinator.beginSearchJump(in: self)
        pendingSearchResult = result
        pendingSearchSelectionRange = nil
        searchResultNeedsJump = true
        let targetChapter = Int(result.chapterIndex)
        if targetChapter == chapterIndex, canNavigateReaderPages {
            if let position = updateSearchSelection() {
                currentPageIndex = pageIndex(for: position)
            }
            renderCurrentPage()
            updateMenuState()
        } else {
            loadChapter(index: targetChapter, restorePosition: 0)
        }
    }

    func updateSearchSelection() -> Int? {
        pendingSearchSelectionRange = nil
        guard let result = pendingSearchResult, Int(result.chapterIndex) == chapterIndex else { return nil }
        let shouldJump = searchResultNeedsJump
        searchResultNeedsJump = false
        guard let range = ReaderSearchSelectionMapper.range(for: result, content: chapterContent, pages: pages) else {
            if shouldJump { showToast("正文已变化，请重新搜索") }
            return nil
        }
        pendingSearchSelectionRange = range
        return shouldJump ? range.location : nil
    }

    func clearSearchHighlight() {
        searchSelectionRequestID = UUID()
        shouldPresentSearchSelection = false
        pendingSearchResult = nil
        searchResultNeedsJump = false
        pendingSearchSelectionRange = nil
        renderView.searchResultRange = nil
        scrollPagerView.setSearchResultRange(nil)
    }

    func clearSearchSelection() {
        clearSearchHighlight()
        selectedTextRange = nil
        renderView.selectionRange = nil
        scrollPagerView.clearTextSelection()
        dismissTextSelectionMenu(clearSelection: true)
    }

    func refreshSearchSelectionPresentation() {
        guard shouldPresentSearchSelection, let range = pendingSearchSelectionRange,
            pendingSearchResult?.chapterIndex == Int32(chapterIndex)
        else { return }
        let requestID = searchSelectionRequestID
        let expectedBookURL = bookURL
        let expectedChapterURL = currentChapterURL
        let expectedChapterIndex = chapterIndex
        let expectedOrigin = book?.origin
        // Pagination accepts navigation only after its render stack has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.searchSelectionRequestID == requestID, self.shouldPresentSearchSelection,
                self.bookURL == expectedBookURL, self.currentChapterURL == expectedChapterURL,
                self.book?.origin == expectedOrigin,
                self.chapterIndex == expectedChapterIndex, self.pendingSearchSelectionRange == range,
                self.canNavigateReaderPages, self.presentedViewController == nil, !self.isMenuVisible,
                ReaderAppearanceSelectionContext.isVisible(self)
            else { return }
            if self.textSelectionCoordinator.isSearchResultSelection, self.selectedTextRange == range { return }
            let indices =
                self.isScrollPageMode
                ? self.scrollPagerView.selectionVisiblePageIndices
                : self.renderView.selectionVisiblePageOffsets.map { self.currentPageIndex + $0 }
            guard
                let index = indices.first(where: {
                    self.pages.indices.contains($0) && self.pages[$0].selectionEndpoints(for: range) != nil
                })
            else { return }
            self.textSelectionCoordinator.beginSearchResult(range: range, pageIndex: index)
        }
    }

    @objc private func resumeSearchSelection(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        refreshSearchSelectionPresentation()
    }
}

extension ReaderContainerViewController: SearchContentDelegate {
    func searchContentDidSelectResult(
        _ result: ContentSearchResult, at index: Int, allResults: [ContentSearchResult],
        options: ReaderContentSearchOptions, resultOptions: ReaderContentSearchOptions
    ) {
        searchMenu.restoreResults(
            allResults,
            selectedIndex: index,
            query: result.query,
            currentChapterIndex: Int(result.chapterIndex),
            options: options,
            resultOptions: resultOptions
        )
        openSearchResult(result)
        searchMenu.setVisible(true, currentChapterIndex: Int(result.chapterIndex))
    }
}

extension ReaderContainerViewController {
    func makeChapterListSheet(items: [ReaderChapterListItem]) -> AndroidChapterListSheetViewController {
        AndroidChapterListSheetViewController(
            items: items,
            readerContainer: self,
            onSelect: { [weak self] index in
                guard let self else { return }
                if index == self.chapterIndex, !self.pages.isEmpty, self.loadFailureView.isHidden { return }
                self.loadChapter(index: index, restorePosition: 0)
            },
            onRefresh: { [weak self] in
                guard let self else { return [] }
                return try await self.chapterListRefreshCoordinator.refresh(in: self)
            },
            onReverse: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.chapterListOrderCoordinator.reverse(in: self)
            },
            onReloadTitles: { [weak self] in
                guard let self else { throw CancellationError() }
                let bookURL = self.bookURL
                let items = try await self.screen.loadChapterListState()
                guard self.bookURL == bookURL else { throw CancellationError() }
                return items
            },
            onShowLogs: { presenter in
                guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
                let dialog = ReaderAppLogDialogViewController()
                dialog.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
                presenter.present(dialog, animated: true)
            }
        )
    }

    func refreshedChapterIndex(in refreshedChapters: [BookChapter], fallback: Int) -> Int {
        guard refreshedChapters.isEmpty == false else { return 0 }
        let currentURL = currentChapterURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentURL.isEmpty == false,
            let matched = refreshedChapters.first(where: { $0.url == currentURL || $0.getAbsoluteURL() == currentURL })
        {
            return min(max(Int(matched.index), 0), refreshedChapters.count - 1)
        }
        let currentTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentTitle.isEmpty == false,
            let matched = refreshedChapters.first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == currentTitle })
        {
            return min(max(Int(matched.index), 0), refreshedChapters.count - 1)
        }
        return min(max(fallback, 0), refreshedChapters.count - 1)
    }

    func startChapterDownload(startIndex: Int, endIndex: Int) {
        guard book?.isLocal != true else {
            showToast(L10n.Reader.downloadLocalUnavailable)
            return
        }
        guard chapters.isEmpty == false else {
            showToast("当前没有可下载的章节")
            return
        }
        let safeStartIndex = min(max(startIndex, 0), chapters.count - 1)
        let safeEndIndex = min(max(endIndex, safeStartIndex), chapters.count - 1)
        guard safeStartIndex <= safeEndIndex else {
            showToast(L10n.BookDetail.emptyChapters)
            return
        }
        guard let book else { return }
        if CacheDownloadCoordinator.shared.start(book: book, startIndex: safeStartIndex, endIndex: safeEndIndex) {
            showToast(L10n.Reader.downloadStarted)
        } else {
            showToast("本书正在缓存，可在书架的缓存/导出中查看或停止")
        }
    }

    func refreshChapterCacheFromCurrent() {
        guard chapters.indices.contains(chapterIndex) else {
            showToast("当前没有可刷新的章节")
            return
        }
        loadingIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.screen.refreshChapterFromIndex(fromIndex: self.chapterIndex)
                await MainActor.run {
                    self.loadingIndicator.stopAnimating()
                    self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                    self.showToast(L10n.Reader.refreshAfterSuccess)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimating()
                    self.showToast(error.userFacingMessage)
                }
            }
        }
    }

    func refreshAllChapterCache() {
        guard chapters.isEmpty == false else {
            showToast("当前没有可刷新的章节")
            return
        }
        loadingIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.screen.refreshAllChapterContent(currentIndex: self.chapterIndex)
                await MainActor.run {
                    self.loadingIndicator.stopAnimating()
                    self.applyPayload(payload, restorePosition: self.currentCharacterOffset())
                    self.showToast(L10n.Reader.refreshAllSuccess)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimating()
                    self.showToast(error.userFacingMessage)
                }
            }
        }
    }
}

extension ReaderContainerViewController {
    func saveReadAloudSpeechRate(followSystem: Bool, value: Float) {
        let normalizedSliderValue = min(max(value, 0), 45)
        readAloudRateSaveTask?.cancel()
        readAloudRateSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                guard let self, Task.isCancelled == false else { return }
                if let config = self.runtimeConfig?.reader {
                    let updated = self.updatedReaderConfig(
                        from: config,
                        ttsFollowSystemRate: followSystem,
                        ttsSpeechRate: Int32(min(max(Int(normalizedSliderValue.rounded()), 0), 45))
                    )
                    try await self.screen.setReaderRuntimeConfig(config: updated)
                }
                try await self.screen.updateReadAloudSpeechRate(
                    followSystem: followSystem,
                    value: Self.normalizedReadAloudSpeechRate(followSystem: followSystem, sliderValue: normalizedSliderValue)
                )
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in self?.showToast(error.userFacingMessage) }
            }
        }
    }

    func saveReadAloudTimer(minutes: Int) {
        let normalizedMinutes = min(max(minutes, 0), 180)
        readAloudTimerSaveTask?.cancel()
        readAloudTimerSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                guard let self, Task.isCancelled == false else { return }
                if let config = self.runtimeConfig?.reader {
                    let updated = updatedReaderConfig(from: config, ttsTimerMinutes: Int32(normalizedMinutes))
                    try await self.screen.setReaderRuntimeConfig(config: updated)
                }
                try await self.screen.setReadAloudTimer(minutes: normalizedMinutes)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in self?.showToast(error.userFacingMessage) }
            }
        }
    }

    func updateReadAloudVoice(_ identifier: String?) {
        guard let config = runtimeConfig?.reader else {
            showToast("朗读配置尚未加载，无法保存音色")
            return
        }
        readAloudService.updateVoiceIdentifier(identifier)
        let updated = updatedReaderConfig(from: config, ttsVoiceIdentifier: .some(identifier))
        Task { [weak self] in
            do {
                try await self?.screen.setReaderRuntimeConfig(config: updated)
            } catch {
                await MainActor.run { self?.showToast(error.userFacingMessage) }
            }
        }
    }

    func startReadAloudFromCurrentPage() {
        let blocks = chapterReadAloudBlocks()
        guard blocks.isEmpty == false else {
            showToast(readAloudEmptyContentMessage())
            return
        }
        stopAutoPage(showMessage: false)
        if let config = runtimeConfig?.reader {
            syncReadAloudVoice(from: config)
        }
        readAloudService.updateBlocks(blocks)
        let safePageIndex = min(max(currentPageIndex, 0), max(pages.count - 1, 0))
        let startPosition = readAloudContent.startPosition(onPage: safePageIndex)
        let startBlock = startPosition?.blockIndex ?? Int(blocks.first?.blockIndex ?? 0)
        readAloudService.prepareForPlayback()
        runReadAloudTask { screen in
            try await screen.startReadAloud(
                chapterIndex: self.chapterIndex,
                blocks: blocks,
                startBlockIndex: startBlock,
                startTextOffset: startPosition?.textOffset ?? 0,
                preferBackgroundPlayback: self.readAloudState?.isBackgroundPlaybackEnabled ?? false,
                ttsEngine: self.runtimeConfig?.ttsEngine
            )
        }
    }

    func runReadAloudTask(_ operation: @escaping (ReaderScreenAdapter) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(self.screen)
            } catch {
                await MainActor.run { self.showToast(error.userFacingMessage) }
            }
        }
    }

    func skipReadAloudParagraph(previous: Bool) {
        guard readAloudState?.status == .running || readAloudState?.status == .paused else {
            showToast("朗读尚未开始")
            return
        }
        let blocks = chapterReadAloudBlocks()
        guard blocks.isEmpty == false else {
            showToast(readAloudEmptyContentMessage())
            return
        }
        if let currentBlockIndex = readAloudState?.progress.blockIndex {
            let orderedBlockIndexes = blocks.map { Int($0.blockIndex) }.sorted()
            if previous, orderedBlockIndexes.first == Int(currentBlockIndex) {
                showToast("已经是本章第一段")
                return
            }
            if previous == false, orderedBlockIndexes.last == Int(currentBlockIndex) {
                showToast("已经是本章最后一段")
                return
            }
        }
        if readAloudState?.status == .running { readAloudService.prepareForPlayback() }
        runReadAloudTask { screen in
            if previous {
                try await screen.skipReadAloudToPreviousBlock()
            } else {
                try await screen.skipReadAloudToNextBlock()
            }
        }
    }

    func readAloudEmptyContentMessage() -> String {
        if pages.isEmpty {
            return "当前章节尚未分页完成，稍后再试"
        }
        if chapterContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "当前章节没有正文内容，无法朗读"
        }
        return "当前页没有可朗读的正文段落"
    }

    func setReadAloudBackgroundPlaybackFromSheet(_ enabled: Bool) {
        runReadAloudTask { try await $0.setReadAloudBackgroundPlayback(enabled: enabled) }
        showToast(enabled ? "已允许朗读后台播放" : "已关闭朗读后台播放")
    }

    func saveReadAloudSpeechRateFromSheet(followSystem: Bool, value: Float) {
        let normalizedSliderValue = min(max(value, 0), 45)
        readAloudService.updateSpeechRate(Self.normalizedReadAloudSpeechRate(followSystem: followSystem, sliderValue: normalizedSliderValue))
        saveReadAloudSpeechRate(followSystem: followSystem, value: normalizedSliderValue)
    }

    func saveReadAloudTimerFromSheet(minutes: Int) {
        saveReadAloudTimer(minutes: min(max(minutes, 0), 180))
    }

    func updateReadAloudVoiceFromSheet(_ identifier: String?) {
        readAloudService.updateVoiceIdentifier(identifier)
        updateReadAloudVoice(identifier)
        showToast(identifier?.nilIfEmpty == nil ? "已切换为系统默认音色" : "朗读音色已切换")
    }

    static func normalizedReadAloudSpeechRate(followSystem: Bool, sliderValue: Float) -> Float {
        followSystem ? 1.0 : min(max((sliderValue + 5) / 10, 0.5), 5.0)
    }

    private func updatedReaderConfig(
        from config: ReaderRuntimeConfig,
        ttsFollowSystemRate: Bool? = nil,
        ttsSpeechRate: Int32? = nil,
        ttsTimerMinutes: Int32? = nil,
        ttsVoiceIdentifier: String?? = nil
    ) -> ReaderRuntimeConfig {
        ReaderRuntimeConfig(
            brightnessDay: config.brightnessDay,
            brightnessNight: config.brightnessNight,
            pageAnimation: config.pageAnimation,
            shareLayout: config.shareLayout,
            readStyleIndex: config.readStyleIndex,
            comicStyleIndex: config.comicStyleIndex,
            autoReadSpeed: config.autoReadSpeed,
            ttsFollowSystemRate: ttsFollowSystemRate ?? config.ttsFollowSystemRate,
            ttsSpeechRate: ttsSpeechRate ?? config.ttsSpeechRate,
            ttsTimerMinutes: ttsTimerMinutes ?? config.ttsTimerMinutes,
            ttsVoiceIdentifier: ttsVoiceIdentifier ?? config.ttsVoiceIdentifier,
            textFullJustify: config.textFullJustify,
            textBottomJustify: config.textBottomJustify,
            hideStatusBar: config.hideStatusBar,
            hideNavigationBar: config.hideNavigationBar,
            chineseMode: config.chineseMode,
            tapZoneActions: config.tapZoneActions,
            useZhLayout: config.useZhLayout,
            readBodyToLh: config.readBodyToLh,
            isComic: config.isComic
        )
    }
}

final class ReaderBoundaryPageViewController: UIViewController {
    enum Direction {
        case previous
        case next
    }

    let direction: Direction

    init(direction: Direction) {
        self.direction = direction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }
}

final class ReaderDualPageViewController: UIViewController {
    let leftPage: ReaderPageViewController
    let rightPage: ReaderPageViewController?
    let startIndex: Int

    init(leftPage: ReaderPageViewController, rightPage: ReaderPageViewController?, startIndex: Int) {
        self.leftPage = leftPage
        self.rightPage = rightPage
        self.startIndex = startIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(leftPage)
        view.addSubview(leftPage.view)
        leftPage.didMove(toParent: self)

        if let rightPage {
            addChild(rightPage)
            view.addSubview(rightPage.view)
            rightPage.didMove(toParent: self)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        if let rightPage {
            let halfWidth = bounds.width / 2
            leftPage.view.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
            rightPage.view.frame = CGRect(x: halfWidth, y: 0, width: bounds.width - halfWidth, height: bounds.height)
        } else {
            leftPage.view.frame = bounds
        }
    }
}
