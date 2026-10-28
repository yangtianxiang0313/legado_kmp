import SafariServices
import UIKit
import shared

@MainActor
final class SourceLoginFormViewController: UIViewController, NavigationContentChromeProviding {
    private let sourceURL: String
    private let screen: SourceLoginScreenAdapter
    private var configuration: SourceLoginConfiguration?
    private var fields: [(name: String, input: SourceLoginInputView)] = []
    private var buttonFlows: [SourceLoginButtonFlowView] = []
    private let scrollView = SourceLoginFormScrollView()
    private let contentArea = UIView()
    private let toolbar = AndroidEditorTitleBar(title: "登录", showsMore: true)
    private let content = UIStackView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let privacyCover = UIView()
    private var overflowMenu: ReaderOverflowMenuView?
    private var previousNavigationBarHidden: Bool?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var lifetime = UUID()
    private var needsConfigurationLoad = true
    private var completed = false
    weak var returnOwner: UIViewController?

    init(sourceURL: String, screen: SourceLoginScreenAdapter) {
        self.sourceURL = sourceURL
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isOpaque = false
        title = L10n.SourceEdit.loginAction
        navigationItem.largeTitleDisplayMode = .never
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        toolbar.saveButton.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        toolbar.moreButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        toolbar.backButton.accessibilityIdentifier = "sourceLogin.back"
        toolbar.saveButton.accessibilityIdentifier = "sourceLogin.submit"
        toolbar.moreButton.accessibilityIdentifier = "sourceLogin.more"
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.layer.cornerRadius = 3
        contentArea.clipsToBounds = true
        view.addSubview(contentArea)
        contentArea.addSubview(toolbar)
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(scrollView)
        scrollView.addSubview(content)
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.accessibilityIdentifier = "sourceLogin.status"
        statusLabel.accessibilityTraits.insert(.updatesFrequently)
        content.addArrangedSubview(spinner)
        content.addArrangedSubview(statusLabel)
        let availableArea = UILayoutGuide()
        view.addLayoutGuide(availableArea)
        NSLayoutConstraint.activate([
            availableArea.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            availableArea.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            availableArea.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            availableArea.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: contentArea.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            contentArea.topAnchor.constraint(greaterThanOrEqualTo: availableArea.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            contentArea.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            contentArea.bottomAnchor.constraint(lessThanOrEqualTo: availableArea.bottomAnchor),
            contentArea.centerYAnchor.constraint(equalTo: availableArea.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 11),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 3),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -3),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -3),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -6),
        ])
        privacyCover.translatesAutoresizingMaskIntoConstraints = false
        privacyCover.isHidden = true
        view.addSubview(privacyCover)
        NSLayoutConstraint.activate([
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(resignActive(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification,
            UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(becomeActive(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        refreshPalette()
        updateToolbar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController?.isNavigationBarHidden
        }
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let transition = transitionCoordinator {
            let scheduled = transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.resumeConfigurationIfNeeded()
            }
            if !scheduled { resumeConfigurationIfNeeded() }
        } else {
            resumeConfigurationIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        revokePendingResult()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true,
            let previousNavigationBarHidden
        {
            navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection))
            ? .darkContent : .lightContent
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshPalette()
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        contentArea.backgroundColor = AndroidReplicaTheme.background
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        for button in [toolbar.backButton, toolbar.saveButton, toolbar.moreButton, toolbar.titleButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
            button.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        }
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        spinner.color = AndroidReplicaTheme.accent
        privacyCover.backgroundColor = AndroidReplicaTheme.background
        for field in fields { field.input.applyPalette() }
        for flow in buttonFlows { flow.applyPalette() }
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func cancel() {
        guard isCurrent else { return }
        completed = true
        revokePendingResult()
        view.endEditing(true)
        close()
    }

    @objc private func primaryAction() {
        if configuration?.hasForm == true { submit() } else { loadConfiguration() }
    }

    @objc private func resignActive(_ notification: Notification) {
        guard ownsEnvironmentChange(notification) else { return }
        privacyCover.isHidden = false
        revokePendingResult()
    }

    @objc private func becomeActive(_ notification: Notification) {
        guard ownsEnvironmentChange(notification) else { return }
        privacyCover.isHidden =
            UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        resumeConfigurationIfNeeded()
    }

    private func ownsEnvironmentChange(_ notification: Notification) -> Bool {
        if let scene = notification.object as? UIScene { return scene === viewIfLoaded?.window?.windowScene }
        if let window = notification.object as? UIWindow { return window === viewIfLoaded?.window }
        return true
    }

    private var isCurrent: Bool { !completed && privacyCover.isHidden && canPerformNavigationAction }

    private func resumeConfigurationIfNeeded() {
        if needsConfigurationLoad, configuration == nil { loadConfiguration() }
    }

    private func loadConfiguration() {
        guard task == nil, isCurrent else { return }
        needsConfigurationLoad = false
        perform { [screen, sourceURL] in
            let configuration = try await screen.load(sourceURL: sourceURL)
            return .loaded(configuration)
        }
    }

    private func render(_ configuration: SourceLoginConfiguration) throws {
        title = "登录 \(configuration.name)"
        toolbar.titleButton.setAttributedTitle(
            NSAttributedString(string: title ?? "登录", attributes: [.kern: CGFloat(0)]), for: .normal)
        toolbar.titleButton.accessibilityLabel = title
        guard configuration.hasForm else {
            guard let raw = configuration.webUrl, let url = Self.webURL(raw),
                let navigation = navigationController, navigation.topViewController === self
            else { throw SourceLoginScreenAdapter.invalidConfiguration() }
            let web = SourceLoginWebViewController(sourceURL: sourceURL, url: url, screen: screen)
                .configuredForDrillDownPresentation()
            web.previousNavigationBarHidden = previousNavigationBarHidden
            web.returnOwner = returnOwner
            self.configuration = configuration
            var controllers = navigation.viewControllers
            controllers[controllers.count - 1] = web
            navigation.setViewControllers(controllers, animated: false)
            return
        }
        let data = Data(configuration.valuesJson.utf8)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw SourceLoginScreenAdapter.invalidConfiguration()
        }
        self.configuration = configuration
        for field in fields { field.input.removeFromSuperview() }
        for flow in buttonFlows { flow.removeFromSuperview() }
        fields.removeAll()
        buttonFlows.removeAll()
        var flow: SourceLoginButtonFlowView?
        for (index, row) in configuration.rows.enumerated() {
            switch row.type {
            case "text", "password":
                flow = nil
                let input = SourceLoginInputView(
                    name: row.name, value: values[row.name] ?? "", password: row.type == "password")
                input.onReturn = { [weak self, weak input] in
                    guard let self, self.isCurrent, self.task == nil,
                        let index = self.fields.firstIndex(where: { $0.input === input })
                    else { return }
                    if self.fields.indices.contains(index + 1) {
                        self.fields[index + 1].input.focus()
                    } else {
                        self.view.endEditing(true)
                    }
                }
                fields.append((row.name, input))
                content.insertArrangedSubview(input, at: content.arrangedSubviews.count - 2)
            case "button":
                if flow == nil {
                    let buttons = SourceLoginButtonFlowView()
                    content.insertArrangedSubview(buttons, at: content.arrangedSubviews.count - 2)
                    buttonFlows.append(buttons)
                    flow = buttons
                }
                flow?.add(row: row) { [weak self] in self?.runAction(index: index) }
            default: break
            }
        }
        fields.last?.input.returnKeyType = .done
        updateToolbar()
        setStatus(nil)
    }

    private func valuesJSON() throws -> String {
        for field in fields { field.input.commitEditing() }
        view.endEditing(true)
        var values: [String: String] = [:]
        for field in fields { values[field.name] = field.input.value }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw SourceLoginScreenAdapter.invalidConfiguration()
        }
        return result
    }

    @objc private func submit() {
        guard configuration?.hasForm == true, task == nil, isCurrent else { return }
        do {
            let values = try valuesJSON()
            perform { [screen, sourceURL] in
                .submitted(try await screen.submit(sourceURL: sourceURL, valuesJSON: values))
            }
        } catch { showFailure() }
    }

    private func runAction(index: Int) {
        guard configuration?.hasForm == true, task == nil, isCurrent else { return }
        do {
            let values = try valuesJSON()
            perform { [screen, sourceURL] in
                .action(try await screen.runAction(sourceURL: sourceURL, rowIndex: index, valuesJSON: values))
            }
        } catch { showFailure() }
    }

    private enum Completion {
        case loaded(SourceLoginConfiguration)
        case submitted(SourceLoginResult)
        case action(SourceLoginResult)
        case header(String?)
        case clearedHeader
    }

    private func perform(_ operation: @escaping () async throws -> Completion) {
        guard task == nil, isCurrent else { return }
        let id = lifetime
        let request = UUID()
        requestID = request
        setBusy(true)
        task = Task { @MainActor [weak self] in
            defer {
                if let self, self.requestID == request {
                    self.requestID = nil
                    self.task = nil
                    self.setBusy(false)
                    self.resumeConfigurationIfNeeded()
                }
            }
            do {
                let completion = try await operation()
                try Task.checkCancellation()
                guard let self, self.lifetime == id, self.isCurrent else { return }
                self.setBusy(false)
                switch completion {
                case .loaded(let configuration): try self.render(configuration)
                case .submitted(let result):
                    if let raw = result.webUrl, let url = Self.webURL(raw) {
                        self.present(SFSafariViewController(url: url), animated: true)
                    } else {
                        self.finishSubmittedLogin()
                    }
                case .action(let result):
                    if let raw = result.webUrl, let url = Self.webURL(raw) {
                        self.present(SFSafariViewController(url: url), animated: true)
                    } else if result.executedJs {
                        self.setStatus("操作已执行")
                    }
                case .header(let header):
                    self.present(SourceLoginHeaderViewController(text: header ?? ""), animated: true)
                case .clearedHeader:
                    self.setStatus("已清除登录头")
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.lifetime == id, self.isCurrent else { return }
                self.setBusy(false)
                if self.configuration?.hasForm != true {
                    self.configuration = nil
                    self.updateToolbar()
                }
                self.showFailure()
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        toolbar.setBusy(busy)
        toolbar.backButton.isEnabled = true
        for field in fields { field.input.isUserInteractionEnabled = !busy }
        for flow in buttonFlows { flow.setEnabled(!busy) }
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        if busy { setStatus(nil) }
    }

    private func setStatus(_ message: String?) {
        statusLabel.text = message
        statusLabel.isHidden = message == nil
        if let message { UIAccessibility.post(notification: .announcement, argument: message) }
    }

    private func showFailure() {
        setStatus("书源登录操作失败，请检查登录配置后重试")
    }

    private func revokePendingResult() {
        overflowMenu?.dismiss()
        overflowMenu = nil
        if configuration == nil, task != nil { needsConfigurationLoad = true }
        lifetime = UUID()
        task?.cancel()
        // SharedCancellableAsync cancels the Kotlin request; retain the slot until Swift unwinds its callback.
        setBusy(task != nil)
    }

    private func updateToolbar() {
        let hasForm = configuration?.hasForm == true
        toolbar.saveButton.setImage(
            hasForm ? ReaderTocAndroidIcon.check.image() : ReaderMenuAndroidIcon.refresh.image(), for: .normal)
        toolbar.saveButton.accessibilityLabel = hasForm ? "提交登录" : "重新加载"
        for case let tooltip as UIToolTipInteraction in toolbar.saveButton.interactions {
            toolbar.saveButton.removeInteraction(tooltip)
        }
        toolbar.saveButton.addInteraction(
            UIToolTipInteraction(defaultToolTip: toolbar.saveButton.accessibilityLabel ?? ""))
    }

    @objc private func showMenu() {
        guard task == nil, isCurrent, overflowMenu == nil else { return }
        view.endEditing(true)
        let id = lifetime
        let menu = ReaderOverflowMenuView(
            items: [
                .init(identifier: "menu_show_login_header", title: "查看登录头") { [weak self] in
                    guard let self, self.lifetime == id, self.isCurrent else { return }
                    self.perform { [screen = self.screen, sourceURL = self.sourceURL] in
                        .header(try await screen.loadLoginHeader(sourceURL: sourceURL))
                    }
                },
                .init(identifier: "menu_del_login_header", title: "清除登录头") { [weak self] in
                    guard let self, self.lifetime == id, self.isCurrent else { return }
                    self.perform { [screen = self.screen, sourceURL = self.sourceURL] in
                        try await screen.clearLoginHeader(sourceURL: sourceURL)
                        return .clearedHeader
                    }
                },
                .init(identifier: "menu_log", title: "日志") { [weak self] in
                    guard let self, self.lifetime == id, self.isCurrent else { return }
                    let controller = ReaderAppLogDialogViewController()
                    controller.overrideUserInterfaceStyle = self.traitCollection.userInterfaceStyle
                    self.present(controller, animated: true)
                },
            ], anchorView: toolbar.moreButton, interfaceStyle: traitCollection.userInterfaceStyle)
        menu.canActivateItem = { [weak self] in self?.lifetime == id && self?.isCurrent == true && self?.task == nil }
        menu.onDismiss = { [weak self, weak menu] in
            if self?.overflowMenu === menu { self?.overflowMenu = nil }
        }
        overflowMenu = menu
        menu.present(in: view)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isCurrent else { return false }
        cancel()
        return true
    }

    private func finishSubmittedLogin() {
        let message = fields.isEmpty ? nil : "成功"
        for field in fields { field.input.value = "" }
        completed = true
        close(message: message)
    }

    private func close(message: String? = nil) {
        SourceLoginEntry.close(self, returningTo: returnOwner, message: message)
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { return nil }
        return url
    }
}
