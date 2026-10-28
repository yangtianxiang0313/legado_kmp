import UIKit
import WebKit
import shared

@MainActor
final class SourceLoginWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, NavigationContentChromeProviding {
    private let sourceURL: String
    private let initialURL: URL
    private let screen: SourceLoginScreenAdapter
    private let webSession: SourceLoginWebSession
    private let toolbar = AndroidEditorTitleBar(title: "登录")
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let errorView = UIStackView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let privacyCover = UIView()
    private let webView: WKWebView
    private var progressObservation: NSKeyValueObservation?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var lifetime = UUID()
    private var activeNavigation: WKNavigation?
    private var needsPageLoad = true
    private var seeded = false
    private var loaded = false
    private var completed = false
    private var retrySavesLogin = false
    private var navigationPreparations = 0
    var previousNavigationBarHidden: Bool?
    weak var returnOwner: UIViewController?

    init(sourceURL: String, url: URL, screen: SourceLoginScreenAdapter) {
        self.sourceURL = sourceURL
        initialURL = url
        self.screen = screen
        webSession = SourceLoginWebSession(sourceURL: sourceURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        task?.cancel()
        progressObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = "source.login.web"
        toolbar.backButton.accessibilityIdentifier = "source.login.web.back"
        toolbar.saveButton.accessibilityIdentifier = "source.login.web.confirm"
        toolbar.saveButton.accessibilityLabel = "完成登录"
        toolbar.saveButton.setImage(
            UIImage(named: "ReaderTocAndroidCheck")?.withRenderingMode(.alwaysTemplate), for: .normal)
        for case let tooltip as UIToolTipInteraction in toolbar.saveButton.interactions {
            toolbar.saveButton.removeInteraction(tooltip)
        }
        toolbar.saveButton.addInteraction(UIToolTipInteraction(defaultToolTip: "完成登录"))
        toolbar.backButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        toolbar.saveButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        toolbar.saveButton.isEnabled = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.accessibilityIdentifier = "source.login.web.page"
        errorView.axis = .vertical
        errorView.spacing = 16
        errorView.alignment = .center
        errorView.isHidden = true
        errorLabel.textColor = AndroidReplicaTheme.primaryText
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        retryButton.setImage(
            UIImage(named: "ReaderMenuAndroidRefresh")?.withRenderingMode(.alwaysTemplate), for: .normal)
        retryButton.tintColor = AndroidReplicaTheme.accent
        retryButton.accessibilityLabel = "重新加载"
        retryButton.accessibilityIdentifier = "source.login.web.retry"
        retryButton.addInteraction(UIToolTipInteraction(defaultToolTip: "重新加载"))
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        errorView.addArrangedSubview(errorLabel)
        errorView.addArrangedSubview(retryButton)
        progress.progressTintColor = AndroidReplicaTheme.accent
        progress.trackTintColor = .clear
        privacyCover.backgroundColor = AndroidReplicaTheme.background
        privacyCover.isHidden = true
        for item in [toolbar, webView, progress, errorView, privacyCover] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            progress.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            errorView.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            errorView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            errorView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            retryButton.widthAnchor.constraint(equalToConstant: 48),
            retryButton.heightAnchor.constraint(equalToConstant: 48),
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isAttached else { return }
                self.progress.progress = Float(self.webView.estimatedProgress)
            }
        }
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController?.isNavigationBarHidden
        }
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection))
            ? .darkContent : .lightContent
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let transition = transitionCoordinator {
            let scheduled = transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.resumeAfterAppearance()
            }
            if !scheduled { resumeAfterAppearance() }
        } else {
            resumeAfterAppearance()
        }
    }

    private func resumeAfterAppearance() {
        // UIKit may still own the navigation transition during viewDidAppear/completion.
        DispatchQueue.main.async { [weak self] in self?.resumePageIfNeeded() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        invalidateWork()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            activeNavigation = nil
            webView.stopLoading()
            if !loaded {
                seeded = false
                needsPageLoad = true
            }
            if let previousNavigationBarHidden {
                navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if completed || navigationController?.viewControllers.contains(where: { $0 === self }) != true {
            webView.stopLoading()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshPalette()
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        view.backgroundColor = AndroidReplicaTheme.toolbarBackground
        webView.backgroundColor = AndroidReplicaTheme.background
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        for button in [toolbar.backButton, toolbar.saveButton, toolbar.titleButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
            button.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        }
        errorLabel.textColor = AndroidReplicaTheme.primaryText
        retryButton.tintColor = AndroidReplicaTheme.accent
        progress.progressTintColor = AndroidReplicaTheme.accent
        privacyCover.backgroundColor = AndroidReplicaTheme.background
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func resignActive(_ notification: Notification) {
        guard ownsEnvironmentChange(notification) else { return }
        privacyCover.isHidden = false
        invalidateWork()
    }

    @objc private func becomeActive(_ notification: Notification) {
        guard ownsEnvironmentChange(notification) else { return }
        privacyCover.isHidden =
            UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        updateControls()
        resumePageIfNeeded()
    }

    private func ownsEnvironmentChange(_ notification: Notification) -> Bool {
        if let scene = notification.object as? UIScene { return scene === viewIfLoaded?.window?.windowScene }
        if let window = notification.object as? UIWindow { return window === viewIfLoaded?.window }
        return true
    }

    private func resumePageIfNeeded() {
        updateControls()
        if needsPageLoad { loadPage() }
    }

    @objc private func retry() {
        if retrySavesLogin { confirm() } else { loadPage() }
    }

    private func loadPage() {
        guard isAttached, task == nil, !completed else { return }
        invalidateWork()
        let id = lifetime
        let request = UUID()
        requestID = request
        needsPageLoad = false
        seeded = false
        loaded = false
        retrySavesLogin = false
        activeNavigation = nil
        webView.stopLoading()
        errorView.isHidden = true
        webView.isHidden = false
        progress.isHidden = false
        progress.progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { finishTask(request) }
            do {
                let configuration = try await screen.load(sourceURL: sourceURL)
                try webSession.configureHeaders(configuration.headersJson)
                let sourceSeed = try await screen.loadWebCookieSeed(sourceURL: sourceURL, targetURL: sourceURL)
                let targetSeed =
                    URL(string: sourceURL)?.host?.lowercased() == initialURL.host?.lowercased()
                    ? sourceSeed : try await screen.loadWebCookieSeed(sourceURL: sourceURL, targetURL: initialURL.absoluteString)
                try Task.checkCancellation()
                guard isCurrent(id) else { return }
                title = "登录 \(configuration.name)"
                toolbar.titleButton.setAttributedTitle(
                    NSAttributedString(string: title ?? "登录", attributes: [.kern: CGFloat(0)]), for: .normal)
                toolbar.titleButton.accessibilityLabel = title
                let headers = try Self.headers(configuration.headersJson, source: sourceURL, target: initialURL)
                if URL(string: sourceURL)?.host?.lowercased() != initialURL.host?.lowercased() {
                    await prepareCookies(
                        sourceSeed.cookies, url: sourceURL, headers: sourceSeed.cookieHeader.map { ["Cookie": $0] } ?? [:])
                    try Task.checkCancellation()
                    guard isCurrent(id) else { return }
                }
                var seedHeaders = headers
                if !seedHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Cookie") == .orderedSame }),
                    let cookie = targetSeed.cookieHeader
                {
                    seedHeaders["Cookie"] = cookie
                }
                await prepareCookies(targetSeed.cookies, url: initialURL.absoluteString, headers: seedHeaders)
                try Task.checkCancellation()
                guard isCurrent(id) else { return }
                try webSession.recordSeeded(sourceURL)
                try webSession.recordSeeded(initialURL.absoluteString)
                let ua = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
                webView.customUserAgent = ua?.lowercased() == "null" ? nil : ua
                var request = URLRequest(url: initialURL)
                for (name, value) in headers
                where name.caseInsensitiveCompare("Cookie") != .orderedSame
                    && !(name.caseInsensitiveCompare("User-Agent") == .orderedSame && value.lowercased() == "null")
                {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                seeded = true
                activeNavigation = webView.load(request)
            } catch is CancellationError {
            } catch {
                guard isCurrent(id) else { return }
                showFailure("网页加载失败，请重试")
            }
        }
        updateControls()
    }

    private func prepareCookies(_ cookies: [StoredHttpCookie], url: String, headers: [String: String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            IosSourceCookieBridge.shared.prepareWebView(
                webView: webView, ownerUrl: url, headers: headers, cookies: cookies
            ) {
                continuation.resume()
            }
        }
    }

    @objc private func confirm() {
        guard isAttached, task == nil, navigationPreparations == 0, seeded, loaded, !completed else { return }
        let id = lifetime
        let request = UUID()
        requestID = request
        retrySavesLogin = true
        errorView.isHidden = true
        view.endEditing(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer { finishTask(request) }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            do {
                try Task.checkCancellation()
                guard isCurrent(id) else { return }
                try await screen.saveWebCookies(sourceURL: sourceURL, snapshots: webSession.snapshots(cookies))
                try Task.checkCancellation()
                guard isCurrent(id) else { return }
                completed = true
                close(message: "已保存登录状态")
            } catch is CancellationError {
            } catch {
                guard isCurrent(id) else { return }
                showFailure("登录状态保存失败，请重试", hidesPage: false)
            }
        }
        updateControls()
    }

    @objc private func cancel() {
        guard isAttached else { return }
        completed = true
        invalidateWork()
        activeNavigation = nil
        webView.stopLoading()
        view.endEditing(true)
        close()
    }

    private func close(message: String? = nil) {
        SourceLoginEntry.close(self, returningTo: returnOwner, message: message)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isAttached else { return false }
        cancel()
        return true
    }

    private func invalidateWork() {
        lifetime = UUID()
        webSession.cancelPreparation()
        if !seeded, task != nil { needsPageLoad = true }
        task?.cancel()
        updateControls()
    }

    private func finishTask(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        task = nil
        updateControls()
        resumePageIfNeeded()
    }

    private func isCurrent(_ id: UUID) -> Bool { id == lifetime && isAttached && !Task.isCancelled && !completed }
    private var isAttached: Bool {
        !completed && privacyCover.isHidden && canPerformNavigationAction
    }

    private func updateControls() {
        toolbar.setBusy(task != nil)
        toolbar.backButton.isEnabled = !completed && privacyCover.isHidden
        toolbar.saveButton.isEnabled = task == nil && navigationPreparations == 0 && seeded && loaded && isAttached
        retryButton.isEnabled = task == nil && isAttached
        webView.isUserInteractionEnabled = task == nil && isAttached
    }

    private func showFailure(_ message: String, hidesPage: Bool = true) {
        errorLabel.text = message
        errorView.isHidden = false
        webView.isHidden = hidesPage
        progress.isHidden = true
        if hidesPage { loaded = false }
        retryButton.accessibilityLabel = hidesPage ? "重新加载" : "重试保存登录状态"
        for case let tooltip as UIToolTipInteraction in retryButton.interactions {
            retryButton.removeInteraction(tooltip)
        }
        retryButton.addInteraction(UIToolTipInteraction(defaultToolTip: retryButton.accessibilityLabel ?? ""))
        UIAccessibility.post(notification: .announcement, argument: message)
        updateControls()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isAttached else { return }
        activeNavigation = navigation
        retrySavesLogin = false
        loaded = false
        progress.isHidden = false
        errorView.isHidden = true
        updateControls()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !completed, let navigation, navigation === activeNavigation,
            !isBeingDismissed, !isMovingFromParent,
            navigationController?.topViewController === self
        else { return }
        loaded = true
        progress.isHidden = true
        updateControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation else { return }
        navigationFailed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation else { return }
        navigationFailed(error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !completed, navigationController?.topViewController === self else { return }
        retrySavesLogin = false
        showFailure("网页加载已中断，请重试")
    }

    private func navigationFailed(_ error: Error) {
        guard !completed, navigationController?.topViewController === self,
            !isBeingDismissed, !isMovingFromParent,
            (error as NSError).domain != NSURLErrorDomain || (error as NSError).code != NSURLErrorCancelled
        else { return }
        retrySavesLogin = false
        showFailure("网页加载失败，请重试")
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased()
        if scheme == "about" { decisionHandler(.allow); return }
        guard scheme == "http" || scheme == "https", !completed else { decisionHandler(.cancel); return }
        let id = lifetime
        navigationPreparations += 1
        updateControls()
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { decisionHandler(.cancel); return }
            defer { navigationPreparations -= 1; updateControls() }
            do {
                try await webSession.prepare(url, screen: screen, webView: webView)
                guard isCurrent(id) else { decisionHandler(.cancel); return }
                let request = webSession.sanitized(navigationAction.request)
                if request.allHTTPHeaderFields != navigationAction.request.allHTTPHeaderFields {
                    decisionHandler(.cancel)
                    activeNavigation = webView.load(request)
                } else {
                    decisionHandler(.allow)
                }
            } catch {
                decisionHandler(.cancel)
                if isCurrent(id) { showFailure("登录站点状态准备失败，请重试", hidesPage: false) }
            }
        }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, isAttached else { return nil }
        activeNavigation = webView.load(webSession.sanitized(navigationAction.request))
        return nil
    }

    private static func headers(_ json: String, source: String, target: URL) throws -> [String: String] {
        guard let headers = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else {
            throw SourceLoginScreenAdapter.invalidConfiguration()
        }
        let origin = URL(string: source)
        let sameOrigin =
            origin?.host?.lowercased() == target.host?.lowercased()
            && origin?.scheme?.lowercased() == target.scheme?.lowercased()
            && (origin?.port ?? (origin?.scheme == "https" ? 443 : 80))
                == (target.port ?? (target.scheme == "https" ? 443 : 80))
        return sameOrigin ? headers : headers.filter { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }
    }
}
