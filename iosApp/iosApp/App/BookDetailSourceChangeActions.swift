import UIKit
import shared

@MainActor
final class BookDetailSourceChangeActions: NSObject {
    private final class PickerContext {
        let id = UUID()
        let bookURL: String
        let sourceURL: String
        let hadOwnerNavigation: Bool
        weak var ownerNavigation: UINavigationController?
        weak var navigation: UINavigationController?
        weak var controller: ChangeSourceViewController?
        var operationID: UUID?
        var prepared: PreparedBookSourceChange?

        init(book: Book, navigation: UINavigationController?) {
            bookURL = book.bookUrl
            sourceURL = book.origin
            hadOwnerNavigation = navigation != nil
            ownerNavigation = navigation
        }
    }

    private weak var presenter: UIViewController?
    private let adapter: AndroidReplicaBookDetailAdapter
    private let currentBook: () -> Book?
    private let canPresent: () -> Bool
    private let onBusyChange: (Bool) -> Void
    private let onCommitted: (BookDetailRefreshResult, String, [UIViewController]) -> Void
    private let validatePrepared: ((PreparedBookSourceChange) throws -> Void)?
    private var preparationTask: Task<PreparedBookSourceChange, Error>?
    private var commitTask: Task<Void, Error>?
    private var operationID: UUID?
    private var pickerContext: PickerContext?

    var isBusy: Bool { operationID != nil }
    private(set) var isCommitting = false

    // The owner weakly captures itself in callbacks; canPresent must not include this coordinator's busy state.
    init(
        presenter: UIViewController,
        adapter: AndroidReplicaBookDetailAdapter,
        currentBook: @escaping () -> Book?,
        canPresent: @escaping () -> Bool,
        onBusyChange: @escaping (Bool) -> Void,
        onCommitted: @escaping (BookDetailRefreshResult, String, [UIViewController]) -> Void,
        validatePrepared: ((PreparedBookSourceChange) throws -> Void)? = nil
    ) {
        self.presenter = presenter
        self.adapter = adapter
        self.currentBook = currentBook
        self.canPresent = canPresent
        self.onBusyChange = onBusyChange
        self.onCommitted = onCommitted
        self.validatePrepared = validatePrepared
        super.init()
    }

    deinit {
        preparationTask?.cancel()
    }

    func presentPicker() {
        guard !isBusy, !isCommitting, canPresent(), let presenter,
            presenter.presentedViewController == nil, let book = eligibleBook()
        else { return }
        let context = PickerContext(book: book, navigation: presenter.navigationController)
        pickerContext = context
        let controller = ChangeSourceViewController(
            currentSourceUrl: book.origin,
            currentBook: book,
            sessionFactory: { [weak self] onCandidate, onProgress, onFinished in
                guard let self, !Task.isCancelled, self.matchesIdentity(context),
                    self.ownerIsCurrent(in: context)
                else { throw CancellationError() }
                let session = try await self.adapter.createSourceChangeSearchSession(
                    onCandidate: onCandidate, onProgress: onProgress, onFinished: onFinished
                )
                guard !Task.isCancelled, self.matchesIdentity(context), self.ownerIsCurrent(in: context)
                else {
                    session.dispose()
                    throw CancellationError()
                }
                return session
            }
        )
        let navigation = ChangeSourceNavigationController(rootViewController: controller)
        context.controller = controller
        context.navigation = navigation
        controller.wholeBookSelection = WholeBookSourceSelection(
            canSelect: { [weak self] in
                guard let self else { return false }
                return !self.isCommitting && self.acceptsPicker(context)
            },
            prepare: { [weak self] candidate in
                guard let self else { throw CancellationError() }
                return try await self.prepare(candidate, in: context)
            },
            commit: { [weak self] prepared in
                guard let self else { throw CancellationError() }
                try await self.commit(prepared, in: context)
            },
            onSettled: { [weak self] in self?.settle(context) },
            onCommitted: {})
        presenter.present(navigation, animated: true)
    }

    func cancelPreparation() {
        guard !isCommitting, let context = pickerContext, !ownerIsCurrent(in: context) else { return }
        context.controller?.cancelPendingBookSelection()
        settle(context)
        pickerContext = nil
        Self.dismissOwned(context.navigation, picker: context.controller)
    }

    private func prepare(_ candidate: BookSourceChangeCandidate, in context: PickerContext) async throws
        -> PreparedBookSourceChange
    {
        try Task.checkCancellation()
        guard !isBusy, !isCommitting, acceptsPicker(context), candidate.bookUrl != context.bookURL,
            !candidate.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !candidate.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CancellationError() }
        let id = UUID()
        operationID = id
        context.operationID = id
        context.prepared = nil
        onBusyChange(true)
        guard operationID == id, acceptsPicker(context) else { throw CancellationError() }
        let task = Task { @MainActor [self] in
            try Task.checkCancellation()
            guard operationID == id, context.operationID == id, acceptsPicker(context)
            else { throw CancellationError() }
            return try await adapter.prepareSourceChange(
                candidateBookUrl: candidate.bookUrl, sourceUrl: candidate.sourceUrl)
        }
        preparationTask = task
        defer {
            if operationID == id { preparationTask = nil }
        }
        let prepared = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard operationID == id, context.operationID == id, acceptsPicker(context),
            prepared.originalBookUrl == context.bookURL, prepared.book.origin == candidate.sourceUrl
        else { throw CancellationError() }
        guard !prepared.chapters.isEmpty else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.chapterChangeSourceEmptyToc])
        }
        try validatePrepared?(prepared)
        context.prepared = prepared
        return prepared
    }

    private func commit(_ prepared: PreparedBookSourceChange, in context: PickerContext) async throws {
        try Task.checkCancellation()
        guard !isCommitting, let id = context.operationID, operationID == id, acceptsPicker(context),
            context.prepared === prepared, prepared.originalBookUrl == context.bookURL, let presenter
        else { throw CancellationError() }
        try validatePrepared?(prepared)
        let targets = context.ownerNavigation?.viewControllers ?? [presenter]
        isCommitting = true
        // This task outlives picker cancellation and publishes every completed persistent write.
        let task = Task { @MainActor [self] in
            defer {
                isCommitting = false
                commitTask = nil
            }
            guard operationID == id, acceptsPicker(context) else { throw CancellationError() }
            let result = try await adapter.commitSourceChange(prepared)
            onCommitted(result, context.bookURL, targets)
        }
        commitTask = task
        try await task.value
    }

    private func eligibleBook() -> Book? {
        guard let book = currentBook(), !book.isLocal,
            !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !book.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return book
    }

    private func matchesIdentity(_ context: PickerContext) -> Bool {
        guard pickerContext?.id == context.id, let book = eligibleBook() else { return false }
        return book.bookUrl == context.bookURL && book.origin == context.sourceURL
    }

    private func ownerIsCurrent(in context: PickerContext) -> Bool {
        guard let presenter else { return false }
        if context.hadOwnerNavigation {
            guard let navigation = context.ownerNavigation, presenter.navigationController === navigation,
                navigation.viewControllers.contains(where: { $0 === presenter }),
                navigation.topViewController === presenter
            else { return false }
        } else if presenter.navigationController != nil {
            return false
        }
        var ancestor: UIViewController? = presenter
        while let controller = ancestor {
            if controller.isBeingDismissed || controller.isMovingFromParent { return false }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            ancestor = controller.parent
        }
        return true
    }

    private func acceptsPicker(_ context: PickerContext) -> Bool {
        guard matchesIdentity(context), ownerIsCurrent(in: context), let presenter,
            let navigation = context.navigation, let controller = context.controller,
            controller.navigationController === navigation, navigation.topViewController === controller,
            !navigation.isBeingDismissed, !controller.isBeingDismissed, !controller.isMovingFromParent,
            let presentationOwner = navigation.presentingViewController,
            presentationOwner.presentedViewController === navigation,
            let window = navigation.viewIfLoaded?.window, !window.isHidden,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        for owner in [controller as UIViewController, navigation as UIViewController] {
            guard let presented = owner.presentedViewController else { continue }
            guard
                presented is SourceChangeWaitDialogViewController
                    || presented is SourceChangeTypeDialogViewController,
                !presented.isBeingDismissed, presented.presentedViewController == nil,
                presented.presentingViewController === controller || presented.presentingViewController === navigation
            else { return false }
        }
        // A full-screen picker may remove the owner's view from its window.
        var ancestor: UIViewController? = presenter
        while let owner = ancestor {
            if let presented = owner.presentedViewController, presented !== navigation { return false }
            if owner === presentationOwner { return true }
            ancestor = owner.parent
        }
        return false
    }

    private func settle(_ context: PickerContext) {
        guard pickerContext?.id == context.id, let id = context.operationID, operationID == id, !isCommitting
        else { return }
        operationID = nil
        context.operationID = nil
        context.prepared = nil
        preparationTask?.cancel()
        preparationTask = nil
        onBusyChange(false)
    }

    private static func dismissOwned(_ controller: UINavigationController?, picker: ChangeSourceViewController?) {
        guard let controller, let picker, picker.navigationController === controller,
            controller.topViewController === picker
        else { return }
        if controller.isBeingPresented || controller.isBeingDismissed,
            let transition = controller.transitionCoordinator
        {
            let scheduled = transition.animate(alongsideTransition: nil) { [weak controller, weak picker] _ in
                dismissOwned(controller, picker: picker)
            }
            if scheduled { return }
        }
        // Never dismiss through the presenter, which may already be showing an unrelated page.
        guard let owner = controller.presentingViewController, owner.presentedViewController === controller
        else { return }
        if let presented = picker.presentedViewController ?? controller.presentedViewController {
            guard presented.presentedViewController == nil,
                presented.presentingViewController === picker || presented.presentingViewController === controller
            else { return }
            let completion = { [weak controller, weak picker] in dismissOwned(controller, picker: picker) }
            if let dialog = presented as? SourceChangeWaitDialogViewController {
                dialog.finish(animated: true, completion: completion)
            } else if let dialog = presented as? SourceChangeTypeDialogViewController {
                dialog.finish(animated: true, completion: completion)
            }
            return
        }
        controller.dismiss(animated: true)
    }
}
