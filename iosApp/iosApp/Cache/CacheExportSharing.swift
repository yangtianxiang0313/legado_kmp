import UIKit
import shared

/// One UI request retains immutable book/group inputs, never a later list selection.
@MainActor
final class CacheExportRequestScope {
    let id = UUID()
    let groupID: Int64
    let targets: [Book]
    let groups: [BookGroup]
    let format: CacheExportFormat
    let context: CacheExportOwnerContext
    weak var presentation: UIViewController?
    var onInvalidated: (() -> Void)?
    private let selectionIsCurrent: () -> Bool
    private var consumed = false
    private var invalidated = false
    private var finished = false

    init?(
        owner: UIViewController, groupID: Int64, targets: [Book], groups: [BookGroup], format: CacheExportFormat,
        selectionIsCurrent: @escaping () -> Bool
    ) {
        guard let context = CacheExportOwnerContext(owner: owner) else { return nil }
        self.context = context
        self.groupID = groupID
        self.targets = targets
        self.groups = groups
        self.format = format
        self.selectionIsCurrent = selectionIsCurrent
        context.startMonitoring(
            allowing: { [weak self] in self?.presentation },
            onInvalidated: { [weak self] in self?.invalidate() })
    }

    func isCurrent() -> Bool {
        guard !finished, !invalidated else { return false }
        guard selectionIsCurrent(), context.isCurrent(allowing: presentation) else {
            invalidate()
            return false
        }
        return true
    }

    func consume() -> Bool {
        guard !consumed, isCurrent() else { return false }
        consumed = true
        return true
    }

    func invalidate() {
        guard !finished, !invalidated else { return }
        invalidated = true
        let callback = onInvalidated
        endMonitoring()
        callback?()
    }

    func endMonitoring() {
        onInvalidated = nil
        context.finish()
    }

    func finish() {
        finished = true
        endMonitoring()
    }
}

@MainActor
final class CacheExportOwnerContext: NSObject {
    private final class AttachmentProbe: UIView {
        var onWindowChanged: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?()
        }
    }

    private weak var owner: UIViewController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var allowedModal: UIViewController?
    private weak var modalHost: UIViewController?
    private var ancestors: [Ancestor] = []
    private var invalidated = false
    private var monitoringID: UUID?
    private var monitor: Task<Void, Never>?
    private var attachmentProbe: AttachmentProbe?
    private var allowing: (() -> UIViewController?)?
    private var onInvalidated: (() -> Void)?

    init?(owner: UIViewController) {
        guard let window = owner.viewIfLoaded?.window, let scene = window.windowScene,
            let root = window.rootViewController
        else { return nil }
        self.owner = owner
        self.window = window
        self.scene = scene
        self.root = root
        super.init()
        var current: UIViewController? = owner
        var seen = Set<ObjectIdentifier>()
        while let controller = current, seen.insert(ObjectIdentifier(controller)).inserted {
            ancestors.append(Ancestor(controller))
            if controller === root { break }
            current = controller.parent ?? controller.presentingViewController
        }
        for ancestor in ancestors {
            if let presented = ancestor.controller?.presentedViewController,
                !ancestors.contains(where: { $0.controller === presented })
            {
                return nil
            }
        }
        guard ancestors.last?.controller === root, isCurrent() else { return nil }
    }

    deinit {
        monitor?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func isCurrent(allowing modal: UIViewController? = nil) -> Bool {
        guard !invalidated else { return false }
        guard let owner, let window, let scene, let root,
            window.windowScene === scene, window.rootViewController === root,
            UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
            scene.activationState == .foregroundActive, window.isKeyWindow, !window.isHidden,
            window.alpha > 0, window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            AppLockManager.shared.isUnlocked(in: window),
            ancestors.allSatisfy({ $0.matches(allowing: modal, in: window) })
        else { return invalidate() }

        if allowedModal !== modal {
            allowedModal = modal
            modalHost = nil
        }
        if let modal {
            if let host = modal.presentingViewController {
                guard ancestors.contains(where: { $0.controller === host }),
                    host.presentedViewController === modal, modalHost == nil || modalHost === host
                else { return invalidate() }
                modalHost = host
            }
            guard presentationStaysInWindow(modal, window: window) else { return invalidate() }
        }

        if owner.viewIfLoaded?.window === window {
            guard owner.viewIfLoaded?.isHidden == false, (owner.viewIfLoaded?.alpha ?? 0) > 0 else {
                return invalidate()
            }
            return true
        }
        // Full-screen owned presentations can remove the entire original branch from the window.
        guard owner.viewIfLoaded?.window == nil, let modal, let host = modalHost,
            ancestors.contains(where: { $0.controller === host }),
            presentationHasWindow(modal, window: window) || modal.isBeingPresented || modal.isBeingDismissed
                || modal.transitionCoordinator != nil || host.transitionCoordinator != nil,
            (host.presentedViewController === modal && modal.presentingViewController === host)
                || ((modal.isBeingPresented || modal.isBeingDismissed || modal.transitionCoordinator != nil
                    || host.transitionCoordinator != nil) && host.presentedViewController == nil)
        else { return invalidate() }
        return true
    }

    func startMonitoring(
        allowing: @escaping () -> UIViewController?, onInvalidated: @escaping () -> Void
    ) {
        stopMonitoring()
        guard !invalidated else {
            onInvalidated()
            return
        }
        self.allowing = allowing
        self.onInvalidated = onInvalidated
        let id = UUID()
        monitoringID = id
        for name in [
            UIScene.willDeactivateNotification, UIScene.didDisconnectNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        guard isCurrent(allowing: allowing()) else { return }
        let probe = AttachmentProbe(frame: .zero)
        probe.isHidden = true
        probe.isUserInteractionEnabled = false
        probe.onWindowChanged = { [weak self] in
            guard let self, self.monitoringID == id else { return }
            if self.allowing?() != nil, self.owner?.viewIfLoaded?.window == nil,
                !self.ancestors.contains(where: {
                    $0.controller?.isMovingFromParent == true || $0.controller?.isBeingDismissed == true
                })
            {
                // UIKit can reattach the covered branch just after didMoveToWindow returns.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.monitoringID == id else { return }
                    _ = self.isCurrent(allowing: self.allowing?())
                }
                return
            }
            _ = self.isCurrent(allowing: self.allowing?())
        }
        attachmentProbe = probe
        owner?.viewIfLoaded?.addSubview(probe)
        guard monitoringID == id else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.monitoringID == id,
                    self.isCurrent(allowing: self.allowing?())
                else { return }
            }
        }
    }

    func finish() {
        invalidated = true
        stopMonitoring()
        ancestors = []
        allowedModal = nil
        modalHost = nil
    }

    @discardableResult
    private func invalidate() -> Bool {
        guard !invalidated else { return false }
        invalidated = true
        let callback = onInvalidated
        stopMonitoring()
        callback?()
        return false
    }

    private func stopMonitoring() {
        monitoringID = nil
        monitor?.cancel()
        monitor = nil
        attachmentProbe?.onWindowChanged = nil
        attachmentProbe?.removeFromSuperview()
        attachmentProbe = nil
        NotificationCenter.default.removeObserver(self)
        allowing = nil
        onInvalidated = nil
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard monitoringID != nil else { return }
        if notification.name == .appLockWillCover {
            // Only the actual content window can revoke this request, not another scene's lock.
            guard let covered = notification.object as? UIWindow, covered === window else { return }
            invalidate()
            return
        }
        if [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification].contains(notification.name) {
            guard let changed = notification.object as? UIScene, changed === scene else { return }
        }
        if [UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification].contains(notification.name) {
            guard let changed = notification.object as? UIWindow, changed === window else { return }
        }
        if let changed = notification.object as? UIScene, changed !== scene { return }
        if let changed = notification.object as? UIWindow, changed !== window { return }
        switch notification.name {
        case UIScene.willDeactivateNotification, UIScene.didDisconnectNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification:
            invalidate()
        default:
            _ = isCurrent(allowing: allowing?())
        }
    }

    private func presentationStaysInWindow(_ modal: UIViewController, window: UIWindow) -> Bool {
        var current: UIViewController? = modal
        var seen = Set<ObjectIdentifier>()
        while let controller = current {
            guard seen.insert(ObjectIdentifier(controller)).inserted,
                controller.viewIfLoaded?.window == nil || controller.viewIfLoaded?.window === window
            else { return false }
            guard let child = controller.presentedViewController else { return true }
            var host = child.presentingViewController
            while let parent = host?.parent, host !== controller { host = parent }
            guard host === controller else { return false }
            current = child
        }
        return true
    }

    private func presentationHasWindow(_ modal: UIViewController, window: UIWindow) -> Bool {
        var current: UIViewController? = modal
        while let controller = current {
            if controller.viewIfLoaded?.window === window { return true }
            current = controller.presentedViewController
        }
        return false
    }

    @MainActor
    private final class Ancestor {
        weak var controller: UIViewController?
        private let parent: ObjectIdentifier?
        private let presenter: ObjectIdentifier?
        private let presented: ObjectIdentifier?
        private let navigation: ObjectIdentifier?
        private let tabs: ObjectIdentifier?
        private let top: ObjectIdentifier?
        private let selected: ObjectIdentifier?

        init(_ controller: UIViewController) {
            self.controller = controller
            parent = controller.parent.map(ObjectIdentifier.init)
            presenter = controller.presentingViewController.map(ObjectIdentifier.init)
            presented = controller.presentedViewController.map(ObjectIdentifier.init)
            navigation = controller.navigationController.map(ObjectIdentifier.init)
            tabs = controller.tabBarController.map(ObjectIdentifier.init)
            top = (controller as? UINavigationController)?.topViewController.map(ObjectIdentifier.init)
            selected = (controller as? UITabBarController)?.selectedViewController.map(ObjectIdentifier.init)
        }

        func matches(allowing modal: UIViewController?, in window: UIWindow) -> Bool {
            guard let controller,
                controller.parent.map(ObjectIdentifier.init) == parent,
                controller.presentingViewController.map(ObjectIdentifier.init) == presenter,
                controller.navigationController.map(ObjectIdentifier.init) == navigation,
                controller.tabBarController.map(ObjectIdentifier.init) == tabs,
                controller.viewIfLoaded?.window == nil || controller.viewIfLoaded?.window === window,
                !controller.isBeingDismissed, !controller.isMovingFromParent,
                controller.presentedViewController.map(ObjectIdentifier.init) == presented
                    || (presented == nil && modal != nil && controller.presentedViewController === modal)
            else { return false }
            if let navigation = controller as? UINavigationController,
                navigation.topViewController.map(ObjectIdentifier.init) != top
            {
                return false
            }
            if let tabs = controller as? UITabBarController,
                tabs.selectedViewController.map(ObjectIdentifier.init) != selected
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            return true
        }
    }
}

// Both delivery paths own one of these per actual UIKit presentation; no UIKit delegate is replaced.
@MainActor
final class CacheExportPresentation {
    let controller: UIViewController
    private weak var window: UIWindow?
    private weak var host: UIViewController?
    private var started = false
    private var pending = false
    private var dismissal: Task<Void, Never>?
    private(set) var didPresent = false

    init(_ controller: UIViewController) { self.controller = controller }

    static func canStart(from owner: UIViewController) -> Bool {
        guard let window = owner.viewIfLoaded?.window else { return false }
        var current: UIViewController? = owner
        while let controller = current {
            guard controller.presentedViewController == nil, controller.transitionCoordinator == nil,
                !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.viewIfLoaded?.window === window, controller.viewIfLoaded?.isHidden == false,
                (controller.viewIfLoaded?.alpha ?? 0) > 0
            else { return false }
            current = controller.parent
        }
        return true
    }

    func present(from owner: UIViewController, onPresented: @escaping () -> Void = {}) async -> Bool {
        guard !started, dismissal == nil, Self.canStart(from: owner) else { return false }
        started = true
        pending = true
        window = owner.viewIfLoaded?.window
        owner.present(controller, animated: true) { [self] in
            guard pending else { return }
            pending = false
            guard let window, let presenter = controller.presentingViewController,
                host == nil || host === presenter, presenter.presentedViewController === controller,
                controller.viewIfLoaded?.window === window
            else { return }
            host = presenter
            didPresent = true
            onPresented()
        }
        if host == nil { host = controller.presentingViewController }
        while pending {
            // UIActivityViewController may prepare its remote sheet before attaching or starting
            // a transition. Only UIKit's completion settles an admitted presentation request.
            await Self.pause()
        }
        return didPresent
    }

    func canConsumeAction() -> Bool {
        guard didPresent, dismissal == nil, let window, let host,
            !controller.isBeingPresented, controller.presentedViewController == nil,
            controller.viewIfLoaded?.window == nil || controller.viewIfLoaded?.window === window
        else { return false }
        // UIAlertAction can run after UIKit has already started (or finished) auto-dismissal.
        if controller.presentingViewController == nil {
            return controller.viewIfLoaded?.window == nil && host.presentedViewController == nil
        }
        return controller.presentingViewController === host && host.presentedViewController === controller
            && (controller.viewIfLoaded?.window === window || controller.isBeingDismissed)
    }

    var unexpectedlyDetached: Bool {
        guard didPresent, dismissal == nil, !controller.isBeingPresented, !controller.isBeingDismissed,
            controller.transitionCoordinator == nil
        else { return false }
        guard let host, let window, controller.presentingViewController === host,
            host.presentedViewController === controller
        else { return true }
        var current: UIViewController? = controller
        var seen = Set<ObjectIdentifier>()
        while let candidate = current, seen.insert(ObjectIdentifier(candidate)).inserted {
            if candidate.viewIfLoaded?.window === window { return false }
            current = candidate.presentedViewController
        }
        return true
    }

    func dismiss() async {
        let task: Task<Void, Never>
        if let dismissal {
            task = dismissal
        } else {
            task = Task { @MainActor [self] in
                // Cancellation during present must not race UIKit's real presentation completion.
                while pending { await Self.pause() }
                while controller.isBeingPresented || controller.isBeingDismissed
                    || controller.transitionCoordinator != nil
                { await Self.pause() }
                // Do not dismiss a controller that somebody has rehosted into another request/window.
                if let actual = controller.presentingViewController, actual !== host { return }
                if let actual = controller.viewIfLoaded?.window, actual !== window { return }
                if let actual = host?.viewIfLoaded?.window, actual !== window { return }
                await CacheExportSharing.dismiss(controller)
            }
            dismissal = task
        }
        await task.value
    }

    static func pause() async {
        // Unlike Task.sleep this also yields normally after the upload task has been cancelled.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
        }
    }
}

@MainActor
final class CacheExportSharing {
    struct Item {
        let bookURL: String
        let result: CacheBookExportResult

        func undeliveredMessage(cancelled: Bool) -> String {
            let reason = cancelled ? "已取消导出，未交付" : "未交付，请重新导出"
            return result.isPartial ? "\(reason)；\(result.missingContentMessage)" : reason
        }
    }

    private var items: [Item]
    private let failedCount: Int
    private weak var owner: UIViewController?
    private weak var anchor: UIView?
    private var context: CacheExportOwnerContext?
    private var canPresent: (() -> Bool)?
    private var onFinish: ((Bool, Error?) -> Void)?
    private var presentation: CacheExportPresentation?
    private var confirmationResponse: Bool?
    private var activityResult: (completed: Bool, error: Error?)?
    private var started = false
    private var handedToSystem = false
    private var finishing = false
    private var finished = false

    init(items: [Item], failedCount: Int) {
        self.items = items
        self.failedCount = failedCount
    }

    static func activityItems(for items: [Item]) -> [Any] {
        // The [Any] initializer context can select Optional.flatMap and box an entire URL array.
        let urls: [URL] = items.flatMap { item -> [URL] in item.result.urls }
        return urls.map { $0 as Any }
    }

    static func completionMessage(for items: [Item], failedCount: Int) -> String {
        let partialCount = items.filter { $0.result.isPartial }.count
        if partialCount > 0 || failedCount > 0 {
            return "已分享 \(items.count) 本，内容不完整 \(partialCount) 本，失败 \(failedCount) 本"
        }
        return "导出完成：\(items.count) 本，\(items.reduce(0) { $0 + $1.result.files.count }) 个文件"
    }

    func present(
        from owner: UIViewController, anchor: UIView,
        canPresent: @escaping () -> Bool, onFinish: @escaping (Bool, Error?) -> Void
    ) {
        guard !started, !finishing, !finished else { return }
        started = true
        self.owner = owner
        self.anchor = anchor
        self.canPresent = canPresent
        self.onFinish = onFinish
        guard canPresent(), !items.isEmpty, let context = CacheExportOwnerContext(owner: owner) else {
            finish(completed: false, error: nil)
            return
        }
        self.context = context
        context.startMonitoring(
            allowing: { [weak self] in self?.presentation?.controller },
            onInvalidated: { [weak self] in self?.cancelUndelivered() })
        Task { @MainActor [self] in
            if let warning = Self.warningMessage(for: items, failedCount: failedCount, verb: "分享") {
                guard await confirm(warning) else {
                    finish(completed: false, error: nil)
                    return
                }
            }
            await presentActivity()
        }
    }

    // Only the activity's actual completion owns the delivered files, independently of page lifetime.
    func cancelUndelivered() {
        guard !handedToSystem else { return }
        finish(completed: false, error: nil)
    }

    static func warningMessage(for items: [Item], failedCount: Int, verb: String) -> String? {
        let partialCount = items.filter { $0.result.isPartial }.count
        guard partialCount > 0 || failedCount > 0 else { return nil }
        let missingChapters = items.reduce(0) { $0 + $1.result.missingChapterCount }
        let missingImages = items.reduce(0) { $0 + $1.result.missingImageCount }
        var lines = ["完整 \(items.count - partialCount) 本，内容不完整 \(partialCount) 本，失败 \(failedCount) 本。"]
        if missingChapters > 0 { lines.append("已生成文件中缺失 \(missingChapters) 章正文。") }
        if missingImages > 0 { lines.append("已生成文件中缺失 \(missingImages) 张图片。") }
        lines.append("是否\(verb)已完成的内容？")
        return lines.joined(separator: "\n")
    }

    private var ready: Bool {
        guard !finishing, !finished, context?.isCurrent() == true, canPresent?() == true, let owner else {
            return false
        }
        return CacheExportPresentation.canStart(from: owner)
    }

    private func confirm(_ message: String) async -> Bool {
        guard ready, let owner else { return false }
        let alert = UIAlertController(title: "部分导出", message: message, preferredStyle: .alert)
        let request = CacheExportPresentation(alert)
        presentation = request
        for (title, style, accepted) in [
            (L10n.Common.cancel, UIAlertAction.Style.cancel, false),
            ("分享已完成内容", UIAlertAction.Style.default, true),
        ] {
            alert.addAction(
                UIAlertAction(title: title, style: style) { [weak self, weak request] _ in
                    guard let self, let request, self.presentation === request,
                        self.confirmationResponse == nil, !self.finishing, !self.finished
                    else { return }
                    guard self.context?.isCurrent(allowing: request.controller) == true else {
                        self.cancelUndelivered()
                        return
                    }
                    guard request.canConsumeAction() else { return }
                    self.confirmationResponse = accepted
                })
        }
        guard await request.present(from: owner) else { return false }
        while confirmationResponse == nil, !finishing, !finished {
            guard context?.isCurrent(allowing: alert) == true, !request.unexpectedlyDetached else { return false }
            await CacheExportPresentation.pause()
        }
        let accepted = confirmationResponse == true
        await request.dismiss()
        if presentation === request { presentation = nil }
        return accepted && ready
    }

    private func presentActivity() async {
        guard ready, let owner, let window = owner.viewIfLoaded?.window else {
            finish(completed: false, error: nil)
            return
        }
        let controller = UIActivityViewController(
            activityItems: Self.activityItems(for: items), applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            if let anchor, anchor.window === window {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            } else {
                popover.sourceView = owner.view
                popover.sourceRect = CGRect(x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        let request = CacheExportPresentation(controller)
        presentation = request
        controller.completionWithItemsHandler = { [self, weak request] _, completed, _, error in
            Task { @MainActor [self] in
                guard let request, presentation === request, !finishing, !finished, activityResult == nil else {
                    return
                }
                activityResult = (completed, error)
                if handedToSystem { finish(completed: completed, error: error) }
            }
        }
        _ = await request.present(from: owner) { [weak self, weak request] in
            guard let self, let request, self.presentation === request, !self.finishing, !self.finished,
                self.context?.isCurrent(allowing: request.controller) == true
            else { return }
            self.handedToSystem = true
            self.context?.finish()
            self.context = nil
            self.canPresent = nil
            if let result = self.activityResult { self.finish(completed: result.completed, error: result.error) }
        }
        if !handedToSystem { finish(completed: false, error: nil) }
    }

    private func finish(completed: Bool, error: Error?) {
        guard !finishing, !finished else { return }
        finishing = true
        context?.finish()
        context = nil
        Task { @MainActor [self] in
            if let presentation { await presentation.dismiss() }
            (presentation?.controller as? UIActivityViewController)?.completionWithItemsHandler = nil
            presentation = nil
            for item in items { item.result.cleanup() }
            items = []
            finished = true
            let callback = onFinish
            onFinish = nil
            canPresent = nil
            callback?(completed && error == nil, error)
        }
    }

    static func dismiss(_ controller: UIViewController) async {
        var requested = false
        while controller.presentingViewController != nil || controller.viewIfLoaded?.window != nil
            || controller.isBeingPresented || controller.isBeingDismissed
        {
            if controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator != nil
                || controller.presentingViewController?.transitionCoordinator != nil
            {
                await waitForDismissalTransition(controller)
                continue
            }
            if !requested, let host = controller.presentingViewController, host.presentedViewController === controller {
                requested = true
                controller.dismiss(
                    animated: controller.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive)
            }
            await CacheExportPresentation.pause()
        }
        await CacheExportPresentation.pause()
    }

    private static func waitForDismissalTransition(_ controller: UIViewController) async {
        if let transition = controller.transitionCoordinator
            ?? controller.presentingViewController?.transitionCoordinator
        {
            let registered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let registered = transition.animate(alongsideTransition: nil) { _ in
                    continuation.resume(returning: true)
                }
                if !registered { continuation.resume(returning: false) }
            }
            if registered { return }
        }
        await CacheExportPresentation.pause()
    }
}
