import UIKit
import shared

/// Keep the candidate list in place until preparation and the real local commit have settled.
@MainActor
final class WholeBookSourceChangeCoordinator {
    private enum Phase { case idle, confirming, preparing, committing }

    private weak var host: UIViewController?
    private let currentBook: Book?
    private let selection: WholeBookSourceSelection
    private let onBusyChange: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var phase: Phase = .idle
    private var operationID: UUID?
    private weak var sourceWindow: UIWindow?
    private weak var waitDialog: SourceChangeWaitDialogViewController?
    private weak var typeDialog: SourceChangeTypeDialogViewController?
    private var confirmation: CheckedContinuation<Bool, Never>?
    private var backgroundObserver: NSObjectProtocol?

    var isBusy: Bool { operationID != nil }

    init(host: UIViewController, currentBook: Book?, selection: WholeBookSourceSelection, onBusyChange: @escaping (Bool) -> Void) {
        self.host = host
        self.currentBook = currentBook
        self.selection = selection
        self.onBusyChange = onBusyChange
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let scene = notification.object as? UIScene,
                    scene === self.sourceWindow?.windowScene
                else { return }
                self.cancel()
            }
        }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    func select(_ candidate: BookSourceChangeCandidate) {
        guard !isBusy, let host, host.presentedViewController == nil,
            selection.canSelect(), host.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            candidate.bookUrl != currentBook?.bookUrl
        else { return }
        let id = UUID()
        operationID = id
        sourceWindow = host.view.window
        onBusyChange(true)
        task = Task { @MainActor [self] in
            var committed = false
            defer {
                if operationID == id {
                    operationID = nil
                    phase = .idle
                    task = nil
                    onBusyChange(false)
                    selection.onSettled()
                    if committed { selection.onCommitted() }
                }
            }
            do {
                if let currentBook, SourceChangeBookTypePolicy.requiresConfirmation(candidate: candidate, current: currentBook) {
                    guard await confirmType(id), accepts(id) else { return }
                }
                try Task.checkCancellation()
                guard accepts(id), host.presentedViewController == nil else { return }
                phase = .preparing
                let dialog = SourceChangeWaitDialogViewController { [weak self] in self?.cancel() }
                waitDialog = dialog
                dialog.overrideUserInterfaceStyle = host.traitCollection.userInterfaceStyle
                await withCheckedContinuation { continuation in
                    host.present(dialog, animated: true) { continuation.resume() }
                }
                try Task.checkCancellation()
                guard accepts(id), dialog.presentingViewController != nil, !dialog.isBeingDismissed else { throw CancellationError() }
                let prepared = try await selection.prepare(candidate)
                try Task.checkCancellation()
                guard accepts(id), dialog.presentingViewController != nil, !dialog.isBeingDismissed else { throw CancellationError() }
                guard !prepared.chapters.isEmpty else {
                    throw NSError(domain: "io.legado.sourceChange", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.chapterChangeSourceEmptyToc])
                }
                phase = .committing
                dialog.setCancellationEnabled(false)
                // A completed write must publish its new identity, even if the picker has departed.
                try await selection.commit(prepared)
                committed = true
                await finishWait()
                await closeOwnedPicker()
            } catch {
                await finishWait()
                guard !(error is CancellationError), !Task.isCancelled, accepts(id) else { return }
                let message = "换源获取目录出错\n\(error.userFacingMessage)"
                SharedRuntime.log(message)
                host.showTransientMessage(message)
            }
            await finishWait()
        }
    }

    func cancel() {
        guard isBusy, phase != .committing else { return }
        task?.cancel()
        let continuation = confirmation
        confirmation = nil
        continuation?.resume(returning: false)
        if let dialog = typeDialog { dialog.finish(animated: true, completion: {}) }
        typeDialog = nil
        if let dialog = waitDialog { dialog.finish(animated: true, completion: {}) }
    }

    private func accepts(_ id: UUID) -> Bool {
        guard operationID == id, selection.canSelect(), let host,
            host.viewIfLoaded?.window === sourceWindow,
            sourceWindow?.windowScene?.activationState == .foregroundActive,
            host.navigationController?.topViewController === host,
            !host.isMovingFromParent, !host.isBeingDismissed,
            host.navigationController?.isBeingDismissed != true
        else { return false }
        return true
    }

    private func confirmType(_ id: UUID) async -> Bool {
        guard accepts(id), let host, host.presentedViewController == nil else { return false }
        phase = .confirming
        return await withCheckedContinuation { continuation in
            confirmation = continuation
            let answer: (Bool) -> Void = { [weak self] confirmed in
                guard let self, self.operationID == id else { return }
                let pending = self.confirmation
                self.confirmation = nil
                self.typeDialog = nil
                pending?.resume(returning: confirmed)
            }
            let dialog = SourceChangeTypeDialogViewController(onConfirm: { answer(true) }, onCancel: { answer(false) })
            typeDialog = dialog
            dialog.overrideUserInterfaceStyle = host.traitCollection.userInterfaceStyle
            host.present(dialog, animated: true)
        }
    }

    private func finishWait() async {
        guard let dialog = waitDialog else { return }
        await withCheckedContinuation { continuation in
            dialog.finish(animated: true) { continuation.resume() }
        }
        if waitDialog === dialog { waitDialog = nil }
    }

    private func closeOwnedPicker() async {
        guard let host, let navigation = host.navigationController,
            navigation.topViewController === host,
            let presenter = navigation.presentingViewController,
            presenter.presentedViewController === navigation, navigation.presentedViewController == nil,
            !navigation.isBeingDismissed
        else { return }
        await withCheckedContinuation { continuation in
            navigation.dismiss(animated: true) { continuation.resume() }
        }
    }
}
