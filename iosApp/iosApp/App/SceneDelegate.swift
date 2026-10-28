import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var loadingViewController: StartupViewController?
    private var isBootstrapping = false
    private let startupReading = StartupReadingCoordinator()
    private let externalDocuments = ExternalDocumentCoordinator()
    private let cloudBackup = CloudBackupStartupCoordinator()

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        let startupViewController = StartupViewController()
        startupViewController.onRetry = { [weak self] in
            self?.bootstrapSharedRuntime(reset: true)
        }
        loadingViewController = startupViewController
        window.rootViewController = startupViewController
        window.makeKeyAndVisible()
        self.window = window
        externalDocuments.attach(window: window)
        externalDocuments.receive(options.urlContexts.map(\.url))

        if !options.urlContexts.isEmpty || !options.userActivities.isEmpty
            || options.shortcutItem != nil || options.notificationResponse != nil
        {
            startupReading.cancel()
        }
        bootstrapSharedRuntime()
    }

    func sceneDidBecomeActive(_: UIScene) {
        AppLockManager.shared.sceneDidBecomeActive(window)
        startupReading.resumeIfPossible()
        externalDocuments.resume()
        cloudBackup.resume()
    }

    func sceneWillResignActive(_: UIScene) {
        ForegroundWebServer.shared.stop()
        AutomaticBackupCoordinator.shared.suspendForLock()
        AppLockManager.shared.sceneWillResignActive(window)
        startupReading.sceneBecameInactive()
        cloudBackup.suspend()
    }

    func sceneDidDisconnect(_: UIScene) {
        ForegroundWebServer.shared.stop()
        AppLockManager.shared.sceneDidDisconnect(window)
        startupReading.cancel()
        externalDocuments.disconnect()
        cloudBackup.disconnect()
        AutomaticBackupCoordinator.shared.disconnect()
    }

    func sceneDidEnterBackground(_: UIScene) {
        AppLockManager.shared.sceneDidEnterBackground(window)
    }

    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if !contexts.isEmpty { startupReading.cancel() }
        externalDocuments.receive(contexts.map(\.url))
    }

    func scene(_: UIScene, willContinueUserActivityWithType _: String) {
        startupReading.cancel()
    }

    func scene(_: UIScene, continue _: NSUserActivity) {
        startupReading.cancel()
    }

    func windowScene(
        _: UIWindowScene, performActionFor _: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        startupReading.cancel()
        completionHandler(false)
    }

    private func bootstrapSharedRuntime(reset: Bool = false) {
        guard !isBootstrapping, let startupViewController = loadingViewController,
            window?.rootViewController === startupViewController
        else { return }
        isBootstrapping = true
        if reset { SharedRuntime.reset() }
        startupViewController.setState(.loading(message: reset ? L10n.Startup.retrying : L10n.Startup.bootstrapping))
        DispatchQueue.main.async { [weak self, weak startupViewController] in
            guard let self else { return }
            defer { self.isBootstrapping = false }
            guard let startupViewController,
                self.loadingViewController === startupViewController,
                self.window?.rootViewController === startupViewController
            else { return }
            switch SharedRuntime.bootstrap() {
            case .success:
                startupViewController.whenVisible { [weak self, weak startupViewController] in
                    guard let self, let startupViewController, let window = self.window,
                        window.rootViewController === startupViewController
                    else { return }
                    let home = MainTabBarController()
                    let rootViewController = SwipeBackNavigationController(rootViewController: home)
                    rootViewController.setNavigationBarHidden(true, animated: false)
                    self.loadingViewController = nil
                    window.rootViewController = rootViewController
                    self.startupReading.runtimeDidBecomeReady(
                        window: window, navigation: rootViewController, home: home)
                    self.cloudBackup.attach(window: window, home: home)
                    AppLockManager.shared.attach(window: window) {
                        [weak self, weak rootViewController] in
                        guard let self, let rootViewController,
                            self.window?.rootViewController === rootViewController
                        else { return }
                        self.startupReading.appDidUnlock()
                        self.externalDocuments.appDidUnlock()
                        self.cloudBackup.appDidUnlock()
                        AutomaticBackupCoordinator.shared.appDidUnlock()
                    }
                    AppLockManager.shared.sceneDidBecomeActive(window)
                }
            case .failure(let error):
                startupViewController.setState(.failed(message: error.message))
            }
        }
    }
}

private final class StartupViewController: UIViewController {
    enum State {
        case loading(message: String)
        case failed(message: String)
    }

    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let stackView = UIStackView()
    private var isVisible = false
    private var pendingTransition: (() -> Void)?
    var onRetry: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        scheduleTransitionIfVisible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isVisible = false
        super.viewWillDisappear(animated)
    }

    func whenVisible(_ transition: @escaping () -> Void) {
        pendingTransition = transition
        scheduleTransitionIfVisible()
    }

    private func scheduleTransitionIfVisible() {
        guard isVisible, pendingTransition != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, let transition = self.pendingTransition else { return }
            self.pendingTransition = nil
            transition()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = UIIdentifiers.Startup.root
        view.accessibilityValue = "loading"

        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = AppUI.Spacing.medium
        stackView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = L10n.Startup.appTitle
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = UIIdentifiers.Startup.message

        var retryConfiguration = UIButton.Configuration.filled()
        retryConfiguration.title = L10n.Common.retry
        retryConfiguration.baseBackgroundColor = AndroidReplicaTheme.accent
        retryConfiguration.baseForegroundColor = .white
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)
        retryButton.isHidden = true
        retryButton.accessibilityIdentifier = UIIdentifiers.Startup.retry
        activityIndicator.accessibilityIdentifier = UIIdentifiers.Startup.loading

        activityIndicator.startAnimating()

        stackView.addArrangedSubview(activityIndicator)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(retryButton)
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: AppUI.Spacing.xxLarge),
            stackView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -AppUI.Spacing.xxLarge),
        ])
    }

    func setState(_ state: State) {
        switch state {
        case .loading(let message):
            messageLabel.text = message
            retryButton.isHidden = true
            retryButton.isEnabled = false
            activityIndicator.startAnimating()
            view.accessibilityValue = "loading"
        case .failed(let message):
            messageLabel.text = message
            retryButton.isHidden = false
            retryButton.isEnabled = true
            activityIndicator.stopAnimating()
            view.accessibilityValue = "failed"
        }
    }

    @objc private func handleRetry() {
        onRetry?()
    }
}
