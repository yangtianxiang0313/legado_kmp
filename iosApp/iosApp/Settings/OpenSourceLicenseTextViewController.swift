import UIKit

@MainActor
final class OpenSourceLicenseTextViewController: UIViewController, NavigationCustomToolbarProviding {
    private let component: OpenSourceLicenseComponent
    private let sourceURL: URL?
    private let findButton = OpenSourceLicensesUI.icon(
        "magnifyingglass", label: OpenSourceLicensesText.find, identifier: "licenses.find")
    private let shareButton = OpenSourceLicensesUI.icon(
        "square.and.arrow.up", label: OpenSourceLicensesText.share, identifier: "licenses.share")
    private let sourceButton = OpenSourceLicensesUI.icon(
        "arrow.up.right.square", label: OpenSourceLicensesText.source, identifier: "licenses.source")
    private lazy var toolbar = OpenSourceLicensesToolbar(
        title: component.title, actions: [findButton, shareButton] + (sourceURL == nil ? [] : [sourceButton]))
    private let textView = UITextView()
    private let status = OpenSourceLicensesStatusView()
    private var loadedText: String?
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()
    private var needsLoad = true
    private var isVisible = false

    init(component: OpenSourceLicenseComponent) {
        self.component = component
        // Only consume the Catalog-provided URL; never derive a destination from document text.
        if let url = component.homepage, url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
            url.user == nil, url.password == nil
        {
            sourceURL = url
        } else {
            sourceURL = nil
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = component.title
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        refreshPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        refreshPalette()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if needsLoad { loadDocuments() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        textView.findInteraction?.dismissFindNavigator()
        view.endEditing(true)
        if loadTask != nil { needsLoad = true }
        cancelLoad()
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureViews() {
        toolbar.backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        findButton.addTarget(self, action: #selector(findText), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareText), for: .touchUpInside)
        sourceButton.addTarget(self, action: #selector(openSource), for: .touchUpInside)
        findButton.isEnabled = false
        shareButton.isEnabled = false
        textView.accessibilityIdentifier = "licenses.text"
        textView.accessibilityLabel = component.title
        textView.isEditable = false
        textView.isSelectable = true
        textView.isFindInteractionEnabled = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textAlignment = .natural
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 28, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.contentInsetAdjustmentBehavior = .never
        textView.isHidden = true
        status.retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        for item in [toolbar, textView, status] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        let preferredWidth = textView.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            textView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
            textView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            preferredWidth,
            status.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        status.showLoading()
    }

    private func loadDocuments() {
        cancelLoad()
        let id = requestID
        needsLoad = true
        loadedText = nil
        textView.text = nil
        textView.isHidden = true
        findButton.isEnabled = false
        shareButton.isEnabled = false
        status.showLoading()
        let component = component
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard !component.documents.isEmpty else { throw OpenSourceLicensesContentError.emptyDocument }
            // Catalog owns complete local document/NOTICE loading and fails atomically.
            let text = try OpenSourceLicenseCatalog.readText(for: component)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenSourceLicensesContentError.emptyDocument
            }
            try Task.checkCancellation()
            return text
        }
        loadTask = Task { [weak self] in
            do {
                let text = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.requestID == id, self.isVisible else { return }
                self.loadTask = nil
                self.needsLoad = false
                self.loadedText = text
                self.textView.text = text
                self.textView.selectedRange = NSRange(location: 0, length: 0)
                self.textView.setContentOffset(.zero, animated: false)
                self.textView.isHidden = false
                self.findButton.isEnabled = true
                self.shareButton.isEnabled = true
                self.status.hide()
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id, self.isVisible else { return }
                self.loadTask = nil
                self.needsLoad = false
                self.status.show(message: OpenSourceLicensesText.documentFailure + "\n\n" + error.localizedDescription, retry: true)
            }
        }
    }

    private func cancelLoad() {
        requestID = UUID()
        loadTask?.cancel()
        loadTask = nil
    }

    @objc private func retryLoad() {
        guard canPerformNavigationAction else { return }
        loadDocuments()
    }

    @objc private func findText() {
        guard canPerformNavigationAction, loadedText != nil else { return }
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    @objc private func shareText() {
        guard canPerformNavigationAction, let loadedText else { return }
        textView.findInteraction?.dismissFindNavigator()
        view.endEditing(true)
        let controller = UIActivityViewController(activityItems: [loadedText], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
            popover.permittedArrowDirections = .any
        }
        present(controller, animated: true)
    }

    @objc private func openSource() {
        guard canPerformNavigationAction, let sourceURL else { return }
        textView.findInteraction?.dismissFindNavigator()
        view.endEditing(true)
        UIApplication.shared.open(sourceURL, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor [weak self] in
                guard let self, self.canPerformNavigationAction else { return }
                self.showTransientMessage(OpenSourceLicensesText.linkFailure)
            }
        }
    }

    @objc private func goBack() {
        guard canPerformNavigationAction else { return }
        OpenSourceLicensesUI.close(self)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canPerformNavigationAction else { return false }
        if textView.findInteraction?.isFindNavigatorVisible == true {
            textView.findInteraction?.dismissFindNavigator()
        } else {
            goBack()
        }
        return true
    }

    @objc private func refreshPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        toolbar.refreshPalette()
        status.refreshPalette()
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
    }
}
