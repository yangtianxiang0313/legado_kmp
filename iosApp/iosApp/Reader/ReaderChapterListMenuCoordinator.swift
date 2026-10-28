import UIKit
import shared

@MainActor
final class ReaderChapterListMenuCoordinator {
    private enum Setting {
        case useReplace
        case countWords

        var title: String { self == .useReplace ? "使用替换" : "加载字数" }
    }

    var canUpdate: (() -> Bool)?
    var onTitlesReloaded: (([ReaderChapterListItem]) -> Void)?
    var onWordCountChanged: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private(set) var showWordCount: Bool
    var isUpdating: Bool { requestTask != nil }
    var hasPresentedMenu: Bool { overflowMenu != nil }

    private var useReplace: Bool
    private var facade: SettingsFacade?
    private var subscription: FlowSubscription?
    private var hasConfirmedConfig = false
    private var isActive = false
    private var generation = UUID()
    private var titleRevision = UUID()
    private var needsTitleReload = false
    private var isReloadingTitles = false
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    private weak var overflowMenu: ReaderOverflowMenuView?
    private let onReloadTitles: (() async throws -> [ReaderChapterListItem])?
    private let onShowLogs: ((UIViewController) -> Void)?

    init(
        initialRuntimeConfig: AppRuntimeConfig?,
        onReloadTitles: (() async throws -> [ReaderChapterListItem])?,
        onShowLogs: ((UIViewController) -> Void)?
    ) {
        useReplace = initialRuntimeConfig?.tocUiUseReplace ?? false
        showWordCount = initialRuntimeConfig?.tocCountWords ?? true
        self.onReloadTitles = onReloadTitles
        self.onShowLogs = onShowLogs
    }

    deinit {
        requestTask?.cancel()
        subscription?.cancel()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        generation = UUID()
        hasConfirmedConfig = false
        switch SharedRuntime.settingsFacade() {
        case .success(let facade):
            self.facade = facade
            let generation = generation
            subscription = facade.watchRuntimeConfig { [weak self] config in
                DispatchQueue.main.async {
                    self?.receive(config, generation: generation)
                }
            }
        case .failure(let error):
            facade = nil
            if canUpdate?() == true { onMessage?(error.userFacingMessage) }
        }
    }

    func deactivate() {
        isActive = false
        generation = UUID()
        hasConfirmedConfig = false
        subscription?.cancel()
        subscription = nil
        dismissMenu()
        if isReloadingTitles { needsTitleReload = true }
        // Shared writes can commit after cancellation. Keep the flight until completion.
        requestTask?.cancel()
    }

    func dismissMenu() {
        overflowMenu?.dismiss()
    }

    func resumeUpdates() {
        guard isActive, hasConfirmedConfig, canUpdate?() == true else { return }
        onWordCountChanged?()
        reloadTitlesIfNeeded()
    }

    func presentMenu(
        in presenter: UIViewController,
        anchorView: UIView,
        showingChapters: Bool,
        canReverse: Bool,
        onExportBookmarks: ((Bool) -> Void)? = nil,
        onReverse: @escaping () -> Void
    ) {
        guard isActive, canUpdate?() == true else { return }
        if hasPresentedMenu {
            dismissMenu()
            return
        }
        var items: [ReaderOverflowMenuView.Item] = []
        if showingChapters {
            let canChangeSettings = hasConfirmedConfig && facade != nil && !isUpdating
            items = [
                .init(
                    identifier: UIIdentifiers.ReaderChapterList.reverseButton, title: "反转目录",
                    isEnabled: canReverse && !isUpdating, handler: onReverse),
                .init(
                    identifier: "reader.chapterList.useReplace", title: "使用替换", isChecked: useReplace,
                    isEnabled: canChangeSettings && onReloadTitles != nil
                ) { [weak self] in self?.toggle(.useReplace) },
                .init(
                    identifier: "reader.chapterList.loadWordCount", title: "加载字数", isChecked: showWordCount,
                    isEnabled: canChangeSettings
                ) { [weak self] in self?.toggle(.countWords) },
            ]
        } else {
            items = [
                .init(identifier: "reader.chapterList.exportBookmarks", title: "导出", isEnabled: onExportBookmarks != nil) {
                    onExportBookmarks?(false)
                },
                .init(identifier: "reader.chapterList.exportMarkdown", title: "导出(MD)", isEnabled: onExportBookmarks != nil) {
                    onExportBookmarks?(true)
                },
            ]
        }
        items.append(
            .init(identifier: "reader.chapterList.logs", title: "日志", isEnabled: onShowLogs != nil) { [weak self, weak presenter] in
                guard let self, let presenter, self.isActive, self.canUpdate?() == true else { return }
                self.onShowLogs?(presenter)
            })
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: anchorView, interfaceStyle: presenter.traitCollection.userInterfaceStyle)
        menu.onDismiss = { [weak self, weak menu] in
            guard self?.overflowMenu === menu else { return }
            self?.overflowMenu = nil
        }
        overflowMenu = menu
        menu.present(in: presenter.view)
    }

    private func receive(_ config: AppRuntimeConfig, generation: UUID) {
        guard isActive, self.generation == generation else { return }
        let titlesChanged = useReplace != config.tocUiUseReplace
        let countChanged = showWordCount != config.tocCountWords
        let firstConfirmation = !hasConfirmedConfig
        useReplace = config.tocUiUseReplace
        showWordCount = config.tocCountWords
        hasConfirmedConfig = true
        if titlesChanged {
            titleRevision = UUID()
            needsTitleReload = true
        }
        if titlesChanged || countChanged || firstConfirmation { dismissMenu() }
        if countChanged, canUpdate?() == true { onWordCountChanged?() }
        reloadTitlesIfNeeded()
    }

    private func toggle(_ setting: Setting) {
        guard isActive, hasConfirmedConfig, !isUpdating, canUpdate?() == true, let facade else { return }
        if setting == .useReplace, onReloadTitles == nil { return }
        let enabled = setting == .useReplace ? !useReplace : !showWordCount
        let generation = generation
        let id = UUID()
        requestID = id
        dismissMenu()
        requestTask = Task { @MainActor [weak self] in
            defer { self?.finishRequest(id) }
            do {
                try Task.checkCancellation()
                try await SharedAsync.void { completion in
                    switch setting {
                    case .useReplace:
                        facade.setTocUiUseReplace(enabled: enabled, completionHandler: completion)
                    case .countWords:
                        facade.setTocCountWords(enabled: enabled, completionHandler: completion)
                    }
                }
                // The runtime-config flow, not the requested value, confirms the stored state.
                if setting == .useReplace { self?.needsTitleReload = true }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self,
                    self.isCurrentRequest(id, generation: generation)
                else { return }
                self.onMessage?("保存\(setting.title)设置失败: \(error.userFacingMessage)")
            }
        }
    }

    private func reloadTitlesIfNeeded() {
        guard isActive, hasConfirmedConfig, needsTitleReload, !isUpdating,
            canUpdate?() == true, let onReloadTitles
        else { return }
        let generation = generation
        let revision = titleRevision
        let id = UUID()
        requestID = id
        needsTitleReload = false
        isReloadingTitles = true
        requestTask = Task { @MainActor [weak self] in
            defer { self?.finishRequest(id) }
            do {
                try Task.checkCancellation()
                let items = try await onReloadTitles()
                guard !Task.isCancelled, let self, self.isCurrentRequest(id, generation: generation),
                    self.titleRevision == revision
                else { return }
                self.onTitlesReloaded?(items)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self,
                    self.isCurrentRequest(id, generation: generation), self.titleRevision == revision
                else { return }
                self.onMessage?("刷新目录标题失败，已保存的设置保持不变: \(error.userFacingMessage)")
            }
        }
    }

    private func isCurrentRequest(_ id: UUID, generation: UUID) -> Bool {
        isActive && self.generation == generation && requestID == id && canUpdate?() == true
    }

    private func finishRequest(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        requestTask = nil
        isReloadingTitles = false
        reloadTitlesIfNeeded()
    }
}
