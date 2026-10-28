import UIKit
import shared

struct BookDetailRemovalPreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var confirmsRemoval: Bool {
        get { defaults.object(forKey: "bookInfoDeleteAlert") == nil || defaults.bool(forKey: "bookInfoDeleteAlert") }
        nonmutating set { defaults.set(newValue, forKey: "bookInfoDeleteAlert") }
    }

    var deletesOriginal: Bool {
        get { defaults.bool(forKey: "deleteBookOriginal") }
        nonmutating set { defaults.set(newValue, forKey: "deleteBookOriginal") }
    }
}

@MainActor
final class BookDetailShelfRemovalCoordinator {
    private struct Context: Equatable {
        let url: String
        let origin: String
        let isLocal: Bool
    }

    private weak var presenter: UIViewController?
    private let currentBook: () -> Book?
    private let canPresent: () -> Bool
    private let waitForDetailLoad: () async -> Void
    private let removeBook: (String, Bool) async throws -> Void
    private let onBusyChange: (Bool) -> Void
    private let onRemoved: (String, UINavigationController) -> Void
    private let onDismiss: () -> Void
    private let preferences: BookDetailRemovalPreferences
    private weak var dialog: BookDetailDeleteDialogViewController?
    private var operation: Task<Void, Never>?

    init(
        presenter: UIViewController, currentBook: @escaping () -> Book?,
        canPresent: @escaping () -> Bool, waitForDetailLoad: @escaping () async -> Void,
        removeBook: @escaping (String, Bool) async throws -> Void,
        onBusyChange: @escaping (Bool) -> Void,
        onRemoved: @escaping (String, UINavigationController) -> Void,
        onDismiss: @escaping () -> Void,
        preferences: BookDetailRemovalPreferences = .init()
    ) {
        self.presenter = presenter
        self.currentBook = currentBook
        self.canPresent = canPresent
        self.waitForDetailLoad = waitForDetailLoad
        self.removeBook = removeBook
        self.onBusyChange = onBusyChange
        self.onRemoved = onRemoved
        self.onDismiss = onDismiss
        self.preferences = preferences
    }

    func present() {
        guard operation == nil, dialog == nil, canPresent(), let presenter,
            presenter.presentedViewController == nil,
            let book = currentBook(), !book.isNotShelf
        else { return }
        let context = Context(url: book.bookUrl, origin: book.origin, isLocal: book.isLocal)
        guard isVisible(context) else { return }
        if !preferences.confirmsRemoval {
            perform(context, deleteOriginal: context.isLocal && preferences.deletesOriginal)
            return
        }
        let controller = BookDetailDeleteDialogViewController(
            showsFileOption: context.isLocal, deleteOriginal: preferences.deletesOriginal
        ) { [weak self] deleteOriginal in
            guard let self, self.accepts(context) else { return }
            if context.isLocal { self.preferences.deletesOriginal = deleteOriginal }
            self.perform(context, deleteOriginal: context.isLocal && deleteOriginal)
        }
        controller.onDismiss = { [weak self, weak controller] in
            guard let self else { return }
            if self.dialog === controller { self.dialog = nil }
            self.onDismiss()
        }
        dialog = controller
        presenter.present(controller, animated: true)
    }

    private func perform(_ context: Context, deleteOriginal: Bool) {
        guard operation == nil, accepts(context), let navigation = presenter?.navigationController else { return }
        onBusyChange(true)
        // Once a removal starts, retain it through completion rather than pretend to cancel a write.
        operation = Task { @MainActor [self] in
            defer {
                operation = nil
                onBusyChange(false)
            }
            await waitForDetailLoad()
            guard isVisible(context), presenter?.presentedViewController == nil else { return }
            do {
                try await removeBook(context.url, deleteOriginal)
                onRemoved(context.url, navigation)
            } catch is CancellationError {
            } catch {
                if isVisible(context) { presenter?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func accepts(_ context: Context) -> Bool {
        canPresent() && presenter?.presentedViewController == nil && isVisible(context)
    }

    private func isVisible(_ context: Context) -> Bool {
        guard let book = currentBook(), !book.isNotShelf,
            book.bookUrl == context.url, book.origin == context.origin, book.isLocal == context.isLocal,
            let presenter, !presenter.isMovingFromParent, !presenter.isBeingDismissed,
            presenter.navigationController?.topViewController === presenter,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }
}
