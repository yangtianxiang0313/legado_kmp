import UIKit
import shared

@MainActor
final class ReaderTxtTocSelectionCoordinator: NSObject {
    private struct Identity {
        let url: String
        let origin: String

        init(_ book: Book) {
            url = book.bookUrl
            origin = book.origin
        }

        func matches(_ reader: ReaderContainerViewController) -> Bool {
            reader.bookURL == url && reader.book?.origin == origin && reader.book?.isLocal == true
                && reader.book?.isTxtLocalBook == true
        }
    }

    private weak var reader: ReaderContainerViewController?
    private var dialog: ReaderTxtTocRuleDialogViewController?
    private var identity: Identity?
    private var generation = UUID()
    private var loading: Task<Void, Never>?
    private var applying: Task<Void, Never>?
    private var cancellationRequested = false

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        super.init()
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: name, object: nil)
        }
    }

    deinit {
        loading?.cancel()
        applying?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func present() {
        guard dialog == nil, loading == nil, applying == nil, let reader,
            reader.canPerformNavigationAction, reader.presentedViewController == nil, isActive(reader), let book = reader.book,
            book.isLocal, book.isTxtLocalBook
        else { return }
        let key = Identity(book)
        let id = UUID()
        generation = id
        identity = key
        cancellationRequested = false
        reader.setMenuVisible(false)
        let controller = ReaderTxtTocRuleDialogViewController(currentRegex: book.tocUrl, rules: []) { [weak self] ruleID in
            self?.apply(ruleID: ruleID)
        }
        controller.onCancel = { [weak self] in self?.cancel() }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.dialog === controller else { return }
            self?.cancel()
        }
        controller.onManage = { [weak self] in self?.manageRules() }
        controller.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
        dialog = controller
        controller.setBusy(true, message: "正在加载目录规则")
        reader.present(controller, animated: true)
        loading = Task { [self, weak controller] in
            do {
                let facade = try TxtTocSelectionFacade.companion.create()
                let state = try await facade.loadState(bookUrl: key.url)
                try Task.checkCancellation()
                guard generation == id, let controller, dialog === controller,
                    let owner = self.reader, key.matches(owner), isActive(owner)
                else { throw CancellationError() }
                controller.update(currentRegex: state.book.tocUrl, rules: state.rules)
                controller.setBusy(false)
            } catch is CancellationError {
            } catch {
                if generation == id, !cancellationRequested { controller?.showError(error.userFacingMessage) }
            }
            loading = nil
            if cancellationRequested { await dismiss() }
        }
    }

    func cancel() {
        cancellationRequested = true
        loading?.cancel()
        applying?.cancel()
        if applying != nil {
            dialog?.setBusy(true, message: "正在取消，请稍候")
        } else if loading == nil {
            Task { [self] in await dismiss() }
        }
    }

    func readerWillDisappear() {
        guard let reader, reader.presentedViewController !== dialog else { return }
        cancel()
    }

    @objc private func interrupted(_ notification: Notification) {
        if let scene = notification.object as? UIWindowScene,
            scene !== reader?.viewIfLoaded?.window?.windowScene
        {
            return
        }
        cancel()
    }

    private func apply(ruleID: Int64) {
        guard applying == nil, loading == nil, let reader, let key = identity, key.matches(reader),
            let dialog, reader.presentedViewController === dialog, isActive(reader)
        else { return }
        let id = generation
        cancellationRequested = false
        dialog.setBusy(true, message: "正在重建目录")
        reader.chapterLoadCoordinator.cancel(in: reader)
        reader.chapterPrefetchCoordinator.suspend()
        reader.stageProgress(immediate: true)
        let client = reader.screen.catalogRefresh
        let session: ReaderCatalogRefreshClient.Session
        do {
            session = try client.begin(before: ReaderCatalogSnapshot(book: reader.book!, chapters: reader.chapters))
        } catch {
            dialog.showError(error.userFacingMessage)
            return
        }
        applying = Task { [self] in
            var failure: Error?
            do {
                _ = try await client.applyTxtRule(session, ruleID: ruleID)
            } catch { failure = error }
            // Always reconcile in an uncancelled task: even a cancelled request may have committed.
            let presented = await Task { @MainActor [self] in
                await settle(session, client: client, key: key, generation: id, failure: failure)
            }.value
            applying = nil
            if cancellationRequested || presented { await dismiss() }
        }
    }

    private func settle(
        _ session: ReaderCatalogRefreshClient.Session, client: ReaderCatalogRefreshClient,
        key: Identity, generation id: UUID, failure: Error?
    ) async -> Bool {
        guard client.isCurrent(session) else {
            client.finish(session, persisted: nil, acceptsPresentation: false)
            return false
        }
        let snapshot = try? await client.read(session)
        guard let snapshot else {
            client.finish(session, persisted: nil, acceptsPresentation: false)
            if !cancellationRequested { dialog?.showError(failure?.userFacingMessage ?? L10n.Reader.unavailable) }
            return false
        }
        guard let reader, key.matches(reader), generation == id else {
            client.finish(session, persisted: snapshot, acceptsPresentation: false)
            return false
        }
        let changed = session.before.map { !$0.hasSameCatalog(as: snapshot) || $0.progress != snapshot.progress } ?? true
        var presented: ReaderProgressQueue.Snapshot?
        if isActive(reader), !snapshot.chapters.isEmpty {
            if changed || failure == nil {
                if let payload = try? await client.load(session, index: Int(snapshot.book.durChapterIndex)),
                    snapshot.hasSameCatalog(as: ReaderCatalogSnapshot(book: payload.book, chapters: payload.chapters)),
                    key.matches(reader), generation == id, isActive(reader)
                {
                    reader.cancelPageTurnForContentChange()
                    reader.clearSearchSelection()
                    reader.jumpNavigationCoordinator.invalidateCatalogHistory()
                    reader.applyPayload(payload, restorePosition: Int(snapshot.book.durChapterPos))
                    presented = snapshot.progress
                }
            } else {
                presented = .init(
                    chapterIndex: reader.chapterIndex, chapterTitle: reader.chapterTitle,
                    chapterPosition: reader.currentCharacterOffset())
            }
        }
        client.finish(
            session, persisted: snapshot, acceptsPresentation: presented != nil,
            presented: presented)
        reader.updateMenuState()
        if let failure, !cancellationRequested, generation == id, isActive(reader) {
            dialog?.showError(failure.userFacingMessage)
        } else if failure == nil, presented == nil, !cancellationRequested {
            dialog?.showError("目录已更新，但正文尚未加载，请稍后重试")
        } else {
            dialog?.setBusy(false)
        }
        return failure == nil && presented != nil
    }

    private func manageRules() {
        guard applying == nil, loading == nil, let reader, let key = identity,
            key.matches(reader), isActive(reader)
        else { return }
        Task { [self, weak reader] in
            await dismiss()
            guard let reader, key.matches(reader), isActive(reader), reader.presentedViewController == nil else { return }
            let controller = AndroidReplicaTxtTocRuleViewController()
            reader.navigationController?.pushViewController(controller.configuredForDrillDownPresentation(), animated: true)
        }
    }

    private func dismiss() async {
        guard let controller = dialog else { return }
        generation = UUID()
        identity = nil
        controller.onCancel = nil
        controller.onManage = nil
        controller.onDismiss = nil
        if controller.isBeingPresented || controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            await withCheckedContinuation { continuation in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
        }
        if controller.presentingViewController != nil {
            await withCheckedContinuation { continuation in controller.dismiss(animated: true) { continuation.resume() } }
        }
        if dialog === controller {
            dialog = nil
            identity = nil
            generation = UUID()
        }
    }

    private func isActive(_ reader: ReaderContainerViewController) -> Bool {
        reader.viewIfLoaded?.window != nil && reader.navigationController?.topViewController === reader
            && !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }
}
