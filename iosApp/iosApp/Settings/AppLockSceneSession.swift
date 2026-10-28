import UIKit

@MainActor
final class AppLockSceneSession {
    private(set) weak var contentWindow: UIWindow?
    let controller = AppLockViewController()
    private let shieldWindow: UIWindow
    private let root = AppLockShieldViewController()
    private var contentInteraction: Bool?
    private var contentAccessibility: Bool?
    var active: Bool
    var requiresUnlock = true
    var generation = 0
    var deliveredGeneration = -1
    var pendingUnlock: [() -> Void] = []
    var onUnlocked: (() -> Void)?

    var isContentVisible: Bool { shieldWindow.isHidden && contentWindow?.isKeyWindow == true }

    init(window: UIWindow, scene: UIWindowScene) {
        contentWindow = window
        active = scene.activationState == .foregroundActive
        shieldWindow = UIWindow(windowScene: scene)
        shieldWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        shieldWindow.backgroundColor = .systemBackground
        shieldWindow.rootViewController = root
        root.install(controller)
    }

    func replaceContentWindow(_ window: UIWindow) {
        guard contentWindow !== window else { return }
        restoreContent()
        contentWindow = window
        if !shieldWindow.isHidden { protectContent() }
    }

    func showPrivacy() {
        root.showPrivacy()
        controller.clearSensitiveInput()
        contentWindow?.endEditing(true)
        protectContent()
        shieldWindow.isHidden = false
        // Do not acquire key status from an inactive scene or summon its keyboard.
        if active { shieldWindow.makeKeyAndVisible() }
    }

    func showLock() {
        protectContent()
        root.showAuthentication()
        controller.setMode(.password)
        shieldWindow.makeKeyAndVisible()
    }

    func showBlocked(unavailable: Bool) {
        protectContent()
        root.showAuthentication()
        controller.setMode(unavailable ? .unavailable : .loading)
        shieldWindow.makeKeyAndVisible()
    }

    func uncover() {
        guard active, contentWindow?.windowScene?.activationState == .foregroundActive else { return }
        controller.clearSensitiveInput()
        root.showPrivacy()
        shieldWindow.isHidden = true
        restoreContent()
        contentWindow?.makeKeyAndVisible()
    }

    func disconnect() {
        controller.clearSensitiveInput()
        controller.onSubmit = nil
        controller.onRetry = nil
        onUnlocked = nil
        shieldWindow.isHidden = true
        shieldWindow.rootViewController = nil
        restoreContent()
    }

    private func protectContent() {
        guard let contentWindow else { return }
        if contentInteraction == nil { contentInteraction = contentWindow.isUserInteractionEnabled }
        if contentAccessibility == nil { contentAccessibility = contentWindow.accessibilityElementsHidden }
        contentWindow.isUserInteractionEnabled = false
        contentWindow.accessibilityElementsHidden = true
    }

    private func restoreContent() {
        if let contentInteraction { contentWindow?.isUserInteractionEnabled = contentInteraction }
        if let contentAccessibility { contentWindow?.accessibilityElementsHidden = contentAccessibility }
        contentInteraction = nil
        contentAccessibility = nil
    }
}

@MainActor
private final class AppLockShieldViewController: UIViewController {
    private let privacyView = UIView()
    private var authentication: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "app-lock.shield"
        privacyView.backgroundColor = .systemBackground
        privacyView.accessibilityIdentifier = "app-lock.privacy"
        privacyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(privacyView)
        NSLayoutConstraint.activate([
            privacyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyView.topAnchor.constraint(equalTo: view.topAnchor),
            privacyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = true
        icon.accessibilityLabel = "应用已锁定"
        icon.translatesAutoresizingMaskIntoConstraints = false
        privacyView.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: privacyView.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: privacyView.centerYAnchor),
        ])
    }

    func install(_ controller: UIViewController) {
        loadViewIfNeeded()
        authentication = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(controller.view, belowSubview: privacyView)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        showPrivacy()
    }

    func showPrivacy() {
        loadViewIfNeeded()
        privacyView.isHidden = false
        authentication?.view.accessibilityElementsHidden = true
        authentication?.view.isHidden = true
        view.bringSubviewToFront(privacyView)
    }

    func showAuthentication() {
        loadViewIfNeeded()
        authentication?.view.isHidden = false
        authentication?.view.accessibilityElementsHidden = false
        privacyView.isHidden = true
    }
}
