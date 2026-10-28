import UIKit
import UniformTypeIdentifiers

@MainActor
final class SourceLoginHeaderViewController: UIViewController, NavigationContentChromeProviding {
    private let text: String
    private let toolbar = AndroidEditorTitleBar(title: "登录头")
    private let textView = UITextView()
    private let privacyCover = UIView()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { return nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        toolbar.saveButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        toolbar.saveButton.accessibilityLabel = "复制登录头"
        toolbar.saveButton.isEnabled = !text.isEmpty
        for case let tooltip as UIToolTipInteraction in toolbar.saveButton.interactions {
            toolbar.saveButton.removeInteraction(tooltip)
        }
        toolbar.saveButton.addInteraction(UIToolTipInteraction(defaultToolTip: "复制登录头"))
        toolbar.saveButton.addTarget(self, action: #selector(copyHeader), for: .touchUpInside)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.text = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.accessibilityLabel = "登录头"
        privacyCover.translatesAutoresizingMaskIntoConstraints = false
        privacyCover.isHidden = true
        view.addSubview(toolbar)
        view.addSubview(textView)
        view.addSubview(privacyCover)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        view.backgroundColor = AndroidReplicaTheme.toolbarBackground
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        privacyCover.backgroundColor = AndroidReplicaTheme.background
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        for button in [toolbar.backButton, toolbar.saveButton, toolbar.titleButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
            button.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func resignActive(_ notification: Notification) {
        if ownsEnvironmentChange(notification) { privacyCover.isHidden = false }
    }

    @objc private func becomeActive(_ notification: Notification) {
        guard ownsEnvironmentChange(notification) else { return }
        privacyCover.isHidden =
            UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func ownsEnvironmentChange(_ notification: Notification) -> Bool {
        if let scene = notification.object as? UIScene { return scene === viewIfLoaded?.window?.windowScene }
        if let window = notification.object as? UIWindow { return window === viewIfLoaded?.window }
        return true
    }

    private var canInteract: Bool {
        !isBeingDismissed && presentedViewController == nil && !isBeingPresented
            && presentingViewController?.presentedViewController === self
            && viewIfLoaded?.window?.isKeyWindow == true
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    @objc private func copyHeader() {
        guard canInteract, !text.isEmpty else { return }
        // Clipboard use is explicit, device-local and short-lived; no sensitive value enters a toast or log.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        showTransientMessage("已复制登录头")
    }

    @objc private func close() {
        guard canInteract else { return }
        textView.text = nil
        dismiss(animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close()
        return true
    }
}
