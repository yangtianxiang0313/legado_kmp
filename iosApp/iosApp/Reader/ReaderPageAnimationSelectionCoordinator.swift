import UIKit
import shared

@MainActor
final class ReaderPageAnimationSelectionCoordinator {
    private struct Selection {
        let id = UUID()
        let bookURL: String
        let origin: String
    }

    private weak var reader: ReaderContainerViewController?
    private weak var dialog: ReaderBookPageAnimationDialogViewController?
    private var selection: Selection?
    private var saveTask: Task<Void, Never>?

    var isSaving: Bool { saveTask != nil }

    init(reader: ReaderContainerViewController) { self.reader = reader }

    func present(from presenter: UIViewController? = nil) {
        guard saveTask == nil, selection == nil, let reader, canUse(reader),
            !reader.bookSettingsCoordinator.isSaving, !reader.chapterLoadCoordinator.isLoading,
            let book = reader.book, !book.bookUrl.isEmpty, reader.runtimeConfig?.reader != nil
        else { return }
        let host = presenter ?? reader
        guard host.presentedViewController == nil,
            host === reader ? reader.presentedViewController == nil : reader.autoPageCoordinator.ownsPanel(host)
        else { return }
        let context = Selection(bookURL: book.bookUrl, origin: book.origin)
        selection = context
        reader.autoPageCoordinator.setConfiguringAnimation(true)
        let controller = ReaderPageAnimationOperationMenu.make { [weak self] value in
            self?.save(value, context: context)
        }
        dialog = controller
        controller.overrideUserInterfaceStyle = reader.traitCollection.userInterfaceStyle
        controller.onClose = { [weak self, weak controller, weak host] in
            guard let self, self.selection?.id == context.id else { return }
            if self.dialog === controller { self.dialog = nil }
            (host as? ReaderAutoReadSheetViewController)?.pageAnimationDidClose()
            if self.saveTask == nil { self.finish(context) }
        }
        host.present(controller, animated: true)
    }

    private func save(_ value: Int, context: Selection) {
        guard (-1...4).contains(value), saveTask == nil, accepts(context), let reader else { return }
        guard (reader.currentReaderPageAnimationOverrideValue() ?? -1) != value else { return }
        saveTask = Task { @MainActor [self, weak reader] in
            defer {
                saveTask = nil
                finish(context)
            }
            guard let reader, accepts(context) else { return }
            await reader.screen.flushReadingProgressNow()
            guard accepts(context) else { return }
            do {
                let facade = try SharedRuntime.bookDetailFacade().get()
                let updated = try await facade.setPageAnimationAsync(bookUrl: context.bookURL, pageAnimation: Int32(value))
                guard accepts(context), updated.bookUrl == context.bookURL, updated.origin == context.origin else { return }
                reader.book = updated
                reader.refreshReaderRuntimeConfigPresentationSoon()
            } catch {
                if accepts(context), !(error is CancellationError) { reader.showToast(error.userFacingMessage) }
            }
        }
    }

    private func finish(_ context: Selection) {
        guard selection?.id == context.id else { return }
        selection = nil
        guard let reader else { return }
        reader.autoPageCoordinator.setConfiguringAnimation(false)
    }

    private func accepts(_ context: Selection) -> Bool {
        guard selection?.id == context.id, let reader, canUse(reader) else { return false }
        return reader.bookURL == context.bookURL && reader.book?.origin == context.origin
    }

    private func canUse(_ reader: ReaderContainerViewController) -> Bool {
        !reader.isBeingDismissed && !reader.isMovingFromParent
            && reader.navigationController?.isBeingDismissed != true
            && reader.navigationController?.topViewController === reader
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }
}
