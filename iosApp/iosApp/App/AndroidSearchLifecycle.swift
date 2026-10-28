import UIKit

/// SearchActivity.kt:314 keeps search work within RESUMED. Owns only UIKit availability;
/// search operations, history cancellation and empty-result policy remain with the caller.
@MainActor
final class AndroidSearchLifecycle: NSObject {
    var onChange: (() -> Void)?
    var onLeave: (() -> Void)?

    private weak var owner: UIViewController?
    private weak var scene: UIWindowScene?
    private var sceneIsActive = false
    private var appIsActive: Bool
    private var pageHasAppeared = false
    private var menuIsPresented = false
    private var isInvalidated = false
    private var generation = UUID()
    private var appearanceID = UUID()
    private var presentation: AndroidSearchModalObservation?

    init(owner: UIViewController) {
        self.owner = owner
        appIsActive = UIApplication.shared.applicationState == .active
        super.init()
        rememberCurrentScene()
        let center = NotificationCenter.default
        for name in [
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
        ] {
            center.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ] {
            center.addObserver(self, selector: #selector(appChanged(_:)), name: name, object: nil)
        }
    }

    var canInteract: Bool {
        !menuIsPresented && ownsPresentation()
    }

    /// A menu is checked separately by its caller. A matching dialog may validate its
    /// confirmation while it still occupies the presenter's presentation slot.
    func ownsPresentation(allowing modal: UIViewController? = nil) -> Bool {
        guard !isInvalidated, pageHasAppeared, appIsActive,
            UIApplication.shared.applicationState == .active,
            let owner, let window = owner.viewIfLoaded?.window, !window.isHidden,
            let currentScene = window.windowScene, currentScene === scene, sceneIsActive,
            currentScene.activationState == .foregroundActive
        else { return false }

        if let presentation {
            // willPresent runs before super.present establishes UIKit's relationship.
            guard !presentation.isPresenting else { return false }
            if presentation.controller?.isBeingPresented == true { return false }
            if modal == nil, presentation.controller?.isBeingDismissed == true { return false }
        }

        var foundModal = modal == nil
        var ancestor: UIViewController? = owner
        while let current = ancestor {
            guard !current.isBeingDismissed, !current.isMovingFromParent else {
                return false
            }
            if let navigation = current.parent as? UINavigationController,
                navigation.topViewController !== current
            {
                return false
            }
            if let tabs = current.parent as? UITabBarController, tabs.selectedViewController !== current {
                return false
            }
            if let presented = current.presentedViewController {
                guard let modal, presented === modal, modal.presentedViewController == nil else { return false }
                foundModal = true
            }
            ancestor = current.parent
        }
        return foundModal
    }

    func didAppear() {
        guard !isInvalidated else { return }
        appearanceID = UUID()
        pageHasAppeared = true
        rememberCurrentScene()
        changed()
    }

    func willDisappear() {
        guard !isInvalidated else { return }
        let id = UUID()
        appearanceID = id
        pageHasAppeared = false
        rememberCurrentScene()
        let coordinator = owner?.transitionCoordinator
        changed(leaving: true)
        // A cancelled interactive pop/dismiss can restore the same page. A newer
        // didAppear/willDisappear must always win over this transition's completion.
        coordinator?.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isInvalidated, self.appearanceID == id,
                    self.owner?.viewIfLoaded?.window != nil
                else { return }
                self.pageHasAppeared = true
                self.rememberCurrentScene()
                self.changed()
            }
        }
    }

    func setMenuPresented(_ value: Bool) {
        guard !isInvalidated, menuIsPresented != value else { return }
        menuIsPresented = value
        changed()
    }

    @discardableResult
    func willPresent(_ modal: UIViewController) -> UUID {
        let id = UUID()
        guard !isInvalidated else { return id }
        removePresentationObservation()
        rememberCurrentScene()
        let observation = AndroidSearchModalObservation(id: id, controller: modal)
        presentation = observation
        observation.view.onWindowChange = { [weak self] in
            self?.presentationWindowChanged(id)
        }
        // No presentationController.delegate assignment: dialogs retain their own delegate.
        modal.view.addSubview(observation.view)
        changed()
        return id
    }

    func didPresent(_ id: UUID) {
        guard !isInvalidated, let presentation, presentation.id == id else { return }
        presentation.isPresenting = false
        presentation.revision = UUID()
        changed()
        reconcileAfterTransition(presentation)
    }

    func performWhenActive(_ action: @escaping () -> Void) {
        guard !isInvalidated else { return }
        let id = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == id, self.canInteract else { return }
            action()
        }
    }

    /// Permanent termination, including already queued UI and transition callbacks.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        generation = UUID()
        appearanceID = UUID()
        pageHasAppeared = false
        NotificationCenter.default.removeObserver(self)
        removePresentationObservation()
        let callback = onChange
        onChange = nil
        onLeave = nil
        callback?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func changed(leaving: Bool = false) {
        generation = UUID()
        if leaving { onLeave?() }
        guard !isInvalidated else { return }
        onChange?()
    }

    private func rememberCurrentScene() {
        guard let current = owner?.viewIfLoaded?.window?.windowScene, current !== scene else { return }
        scene = current
        sceneIsActive = current.activationState == .foregroundActive
        // Do not refresh an existing scene from activationState here: willDeactivate
        // can be delivered while that property still says foregroundActive.
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard !isInvalidated else { return }
        rememberCurrentScene()
        guard let current = notification.object as? UIWindowScene, current === scene else { return }
        let wasActive = sceneIsActive
        sceneIsActive = notification.name == UIScene.didActivateNotification
        changed(leaving: wasActive && !sceneIsActive)
    }

    @objc private func appChanged(_ notification: Notification) {
        guard !isInvalidated else { return }
        let wasActive = appIsActive
        appIsActive = notification.name == UIApplication.didBecomeActiveNotification
        rememberCurrentScene()
        changed(leaving: wasActive && !appIsActive)
    }

    private func presentationWindowChanged(_ id: UUID) {
        guard !isInvalidated, let presentation, presentation.id == id else { return }
        // Invalidate UI immediately, but read UIKit's presentation relationship only
        // after its window/transition callbacks have finished mutating the hierarchy.
        generation = UUID()
        presentation.revision = UUID()
        reconcileAfterTransition(presentation)
    }

    private func reconcileAfterTransition(_ observation: AndroidSearchModalObservation) {
        let id = observation.id
        let revision = observation.revision
        let finish: () -> Void = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isInvalidated, let current = self.presentation,
                    current.id == id, current.revision == revision
                else { return }
                self.reconcilePresentation(current)
            }
        }
        if let coordinator = observation.controller?.transitionCoordinator ?? owner?.transitionCoordinator,
            coordinator.animate(alongsideTransition: nil, completion: { _ in finish() })
        {
            return
        }
        finish()
    }

    private func reconcilePresentation(_ observation: AndroidSearchModalObservation) {
        if let modal = observation.controller {
            // A fullscreen child can remove this modal's view from its window while
            // the original modal remains presented. Interactive cancellation can too.
            if modal.presentingViewController != nil || modal.isBeingPresented || modal.isBeingDismissed {
                changed()
                return
            }
            var ancestor = owner
            while let current = ancestor {
                if current.presentedViewController === modal {
                    changed()
                    return
                }
                ancestor = current.parent
            }
            // Initial installation in an off-window view is not a dismissal.
            guard !observation.isPresenting || observation.view.hasEnteredWindow else { return }
        }
        removePresentationObservation()
        changed()
    }

    private func removePresentationObservation() {
        let previous = presentation
        presentation = nil
        previous?.view.onWindowChange = nil
        previous?.view.removeFromSuperview()
    }
}

@MainActor
private final class AndroidSearchModalObservation {
    let id: UUID
    weak var controller: UIViewController?
    let view = AndroidSearchModalWindowObserver()
    var isPresenting = true
    var revision = UUID()

    init(id: UUID, controller: UIViewController) {
        self.id = id
        self.controller = controller
    }
}

/// A zero-sized passive view observes programmatic and interactive sheet removals
/// without taking over a presentation delegate or requiring the owner to reappear.
@MainActor
private final class AndroidSearchModalWindowObserver: UIView {
    var onWindowChange: (() -> Void)?
    private(set) var hasEnteredWindow = false
    private var wasInWindow = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            hasEnteredWindow = true
            wasInWindow = true
            onWindowChange?()
        } else if wasInWindow {
            wasInWindow = false
            onWindowChange?()
        }
    }
}
