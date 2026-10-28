import Foundation
import UIKit
import shared

/// Resolves an external book link for the existing detail page, never for automatic shelf insertion.
@MainActor
final class ExternalBookLinkCoordinator {
    private weak var owner: UIViewController?
    private weak var expectedWindow: UIWindow?
    private weak var expectedScene: UIWindowScene?
    private weak var expectedRoot: UIViewController?
    private weak var expectedNavigation: UINavigationController?
    private var preparation: Task<Void, Never>?
    private var ownershipMonitor: Task<Void, Never>?
    private var loading: UIAlertController?
    private var generation = UUID()
    private var isClosingLoading = false

    var isPreparing: Bool { preparation != nil }

    init(owner: UIViewController) {
        self.owner = owner
        expectedWindow = owner.viewIfLoaded?.window
        expectedScene = expectedWindow?.windowScene
        expectedRoot = expectedWindow?.rootViewController
        expectedNavigation = owner.navigationController
    }

    deinit {
        preparation?.cancel()
        ownershipMonitor?.cancel()
    }

    nonisolated static func accepts(_ address: String) -> Bool {
        BookLinkAddressValidator.shared.accepts(address: address)
    }

    func start(address: String) {
        guard !isPreparing, Self.accepts(address), let owner, hasCurrentOwner,
            owner.canPerformNavigationAction, owner.presentedViewController == nil,
            expectedNavigation?.presentedViewController == nil, expectedRoot?.presentedViewController == nil,
            isForegroundContent
        else { return }
        let token = UUID()
        generation = token
        isClosingLoading = false
        let dialog = UIAlertController(title: "正在解析书籍", message: "正在匹配书源并读取详情", preferredStyle: .alert)
        dialog.view.accessibilityIdentifier = "externalBookLink.loading"
        dialog.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.cancel() })
        loading = dialog
        owner.present(dialog, animated: true)
        preparation = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let facade = try SharedRuntime.bookshelfFacade().get()
                let book: Book = try await SharedCancellableAsync.value { completion in
                    facade.prepareBookLinkRequest(bookUrl: address) { result in
                        if result.isCancelled {
                            completion(nil, CancellationError())
                        } else if let book = result.book {
                            completion(book, nil)
                        } else {
                            completion(
                                nil,
                                NSError(
                                    domain: "io.legado.externalBookLink", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "无法解析书籍详情"]
                                ))
                        }
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                try await self.closeLoadingAndWaitForOwner(token: token)
                try Task.checkCancellation()
                guard self.generation == token, self.hasCurrentOwner, self.isForegroundContent,
                    let owner = self.owner, owner.canPerformNavigationAction,
                    let navigation = self.expectedNavigation
                else { throw CancellationError() }
                navigation.pushViewController(
                    AndroidReplicaBookDetailViewController(searchBook: SearchBook.companion.fromBook(book: book)), animated: true)
                self.finish(token: token)
            } catch {
                guard let self, self.generation == token else { return }
                guard !(error is CancellationError), !Task.isCancelled else { self.cancel(); return }
                do {
                    try await self.closeLoadingAndWaitForOwner(token: token)
                    guard self.generation == token, self.hasCurrentOwner, self.isForegroundContent,
                        self.owner?.canPerformNavigationAction == true
                    else { throw CancellationError() }
                    self.owner?.showTransientMessage(error.userFacingMessage)
                    self.finish(token: token)
                } catch {
                    if self.generation == token { self.cancel() }
                }
            }
        }
        ownershipMonitor = Task { [weak self] in
            while !Task.isCancelled, self?.generation == token, self?.isPreparing == true {
                if self?.hasCurrentOwner != true || self?.hasOwnedPresentation != true {
                    self?.cancel()
                    return
                }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }

    func cancel() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        ownershipMonitor?.cancel()
        ownershipMonitor = nil
        let dialog = loading
        loading = nil
        isClosingLoading = false
        // Dismiss only this request's modal, never another page's presentation.
        if let dialog, dialog.presentedViewController == nil,
            owner?.presentedViewController === dialog || expectedNavigation?.presentedViewController === dialog
        {
            dialog.dismiss(animated: false)
        }
    }

    private func closeLoadingAndWaitForOwner(token: UUID) async throws {
        while true {
            try checkOwnership(token: token)
            guard hasOwnedPresentation, let dialog = loading, !isClosingLoading else { throw CancellationError() }
            if isForegroundContent, !dialog.isBeingPresented, !dialog.isBeingDismissed,
                dialog.transitionCoordinator == nil, owner?.transitionCoordinator == nil,
                expectedNavigation?.transitionCoordinator == nil, expectedRoot?.transitionCoordinator == nil
            {
                isClosingLoading = true
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    dialog.dismiss(animated: true) { continuation.resume() }
                }
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        while true {
            try checkOwnership(token: token)
            guard hasOwnedPresentation else { throw CancellationError() }
            if isForegroundContent, owner?.canPerformNavigationAction == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func checkOwnership(token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, hasCurrentOwner else { throw CancellationError() }
    }

    private var hasCurrentOwner: Bool {
        guard let owner, let window = expectedWindow, let scene = expectedScene,
            let root = expectedRoot, let navigation = expectedNavigation,
            window.rootViewController === root, window.windowScene === scene,
            root.viewIfLoaded?.window === window,
            scene.activationState != .unattached, owner.navigationController === navigation,
            owner.isVisibleInNavigationStack, !root.isBeingDismissed
        else { return false }
        var ancestor: UIViewController? = owner
        while let controller = ancestor {
            guard controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false, (controller.viewIfLoaded?.alpha ?? 0) > 0,
                !controller.isBeingDismissed, !controller.isMovingFromParent
            else { return false }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller { return false }
            if controller === navigation { return true }
            ancestor = controller.parent
        }
        return false
    }

    private var hasOwnedPresentation: Bool {
        if let modal = expectedRoot?.presentedViewController {
            guard modal === loading, modal.presentedViewController == nil else { return false }
        }
        var ancestor = owner
        while let controller = ancestor {
            if let modal = controller.presentedViewController {
                guard modal === loading, modal.presentedViewController == nil else { return false }
            }
            if controller === expectedNavigation { break }
            ancestor = controller.parent
        }
        if isClosingLoading { return true }
        guard let loading else { return false }
        return owner?.presentedViewController === loading || expectedNavigation?.presentedViewController === loading
    }

    private var isForegroundContent: Bool {
        guard let window = expectedWindow, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            window.windowScene === expectedScene, expectedScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        return true
    }

    private func finish(token: UUID) {
        guard generation == token else { return }
        ownershipMonitor?.cancel()
        ownershipMonitor = nil
        preparation = nil
        loading = nil
        isClosingLoading = false
    }
}
