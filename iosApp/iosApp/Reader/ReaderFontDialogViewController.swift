import UIKit
import UniformTypeIdentifiers

/// FontSelectDialog.kt / FontAdapter.kt at Legado 5f5d314.
@MainActor
final class ReaderFontDialogViewController: UIViewController,
    UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
{
    /// Optional side-effect-free gate for the caller's book/style identity.
    var canSubmit: (() -> Bool)? {
        didSet { if isViewLoaded { refreshPresentation() } }
    }

    private enum Activity { case idle, loading, choosing, picking, saving }
    private enum Selection {
        case entry(ReaderFontEntry)
        case system(String?)
    }
    private enum RetryAction {
        case load
        case systemFonts
        case pickDirectory
        case directory(URL)
        case selection(Selection)
    }

    private let bodyView = ReaderFontDialogBodyView(frame: .zero)
    private var selectedFontName: String?
    private var selectedFilename: String?
    private let onSelect: (String?) async throws -> Void
    private lazy var fontList = ReaderFontListPresentationCoordinator(tableView: bodyView.tableView)
    private var activity = Activity.idle
    private var operationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var contextGeneration = UUID()
    private var presentationContext: ReaderFontDialogPresentationContext?
    private var interactionTimer: Timer?
    private var isVisible = false
    private var isEnvironmentSuspended = false
    private var isClosing = false
    private var isRefreshing = false
    private var lastSourcePermission = false
    private var hasRequestedEntries = false
    private var needsReload = false
    private var automaticPickerAttempted = false
    private var pendingAutomaticPicker = false
    private var warning: String?
    private var failureMessage: String?
    private var retryAction: RetryAction?

    private var childController: UIViewController?
    private var childWasPresented = false
    private var childFinished = false
    private var childPresentationDeadline: TimeInterval = 0
    private var pendingChildAction: (() -> Void)?
    private var isFinishingPicker = false

    init(selectedFontName: String?, onSelect: @escaping (String?) async throws -> Void) {
        self.selectedFontName = selectedFontName
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        interactionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard presentedViewController == nil, !isClosing else { return nil }
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() { view = bodyView }

    override func viewDidLoad() {
        super.viewDidLoad()
        fontList.canDeliver = { [weak self] in self?.canDeliverPreviews == true }
        fontList.canSelect = { [weak self] in self?.canDeliverPreviews == true }
        fontList.textColor = { [weak self] in self?.bodyView.textColor ?? .label }
        fontList.isSelected = { [weak self] entry in self?.isSelected(entry) == true }
        fontList.onSelect = { [weak self] entry in self?.saveSelection(.entry(entry)) }
        fontList.resetPreviews(traits: traitCollection)
        bodyView.onCancel = { [weak self] in self?.cancel() }
        bodyView.onDefaults = { [weak self] in self?.showSystemFonts() }
        bodyView.onDirectory = { [weak self] in self?.openDirectory() }
        bodyView.onRetry = { [weak self] in self?.retry() }
        bodyView.onWindowChange = { [weak self] in self?.scheduleRefresh() }
        bodyView.onMenuVisibilityChange = { [weak self] _ in self?.fontList.resumeDelivery() }
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didActivateNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if presentationContext == nil {
            presentationContext = ReaderFontDialogPresentationContext(dialog: self)
            presentingViewController?.view.endEditing(true)
        }
        presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isVisible = true
        if presentationContext == nil { presentationContext = ReaderFontDialogPresentationContext(dialog: self) }
        startInteractionRefresh()
        refreshPresentation()
        scheduleRefresh()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: bodyView.titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if isPresentationLeaving {
            invalidatePendingResults()
            bodyView.hideMenu(restoreFocus: false)
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if childController == nil, presentingViewController == nil {
            isClosing = true
            fontList.close()
            interactionTimer?.invalidate()
        }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Dismissing an owned child must not invalidate its parent font dialog.
        if presentedViewController == nil {
            isClosing = true
            invalidatePendingResults()
            interactionTimer?.invalidate()
            updateInteraction()
        }
        super.dismiss(animated: flag, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canCancel else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        fontList.resetPreviews(traits: traitCollection)
        bodyView.applyAppearance()
    }

    private var isPresentationLeaving: Bool {
        if isBeingDismissed || isMovingFromParent { return true }
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private var sourcePermitted: Bool {
        guard !isClosing, presentationContext?.isCurrent(dialog: self) == true else { return false }
        return canSubmit?() ?? true
    }

    private var isAvailable: Bool {
        guard let window = viewIfLoaded?.window, presentationContext?.owns(window: window) == true else { return false }
        return isVisible && !isEnvironmentSuspended && !isClosing && !isBeingPresented && !isBeingDismissed
            && childController == nil && presentedViewController == nil
            && presentationContext?.isForeground == true && sourcePermitted
    }

    private var canInteract: Bool { activity == .idle && isAvailable }
    private var canDeliverPreviews: Bool { canInteract && !bodyView.isMenuVisible }

    private var canCancel: Bool {
        !isClosing && isVisible && !isEnvironmentSuspended && !isBeingPresented && !isBeingDismissed
            && childController == nil && presentedViewController == nil
            && viewIfLoaded?.window != nil && presentationContext?.isForeground == true
            && (activity == .idle || activity == .loading)
    }

    private func acceptsResult(_ id: UUID, generation: UUID) -> Bool {
        operationID == id && contextGeneration == generation && !Task.isCancelled && isAvailable
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let busy = activity == .loading || activity == .saving
        let message = failureMessage ?? warning
        bodyView.setState(
            enabled: canInteract, busy: busy, canCancel: canCancel,
            message: message, retryVisible: retryAction != nil || warning != nil)
        isModalInPresentation = activity == .saving
    }

    private func invalidatePendingResults(resetPreviews: Bool = true) {
        contextGeneration = UUID()
        pendingChildAction = nil
        if isClosing {
            fontList.close()
        } else if resetPreviews {
            fontList.resetPreviews(traits: traitCollection, discardCatalog: true)
        }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
    }

    private func refreshPresentation() {
        guard isViewLoaded, !isClosing, !isRefreshing else { return }
        if presentationContext != nil, presentingViewController == nil, viewIfLoaded?.window == nil {
            isClosing = true
            invalidatePendingResults()
            interactionTimer?.invalidate()
            updateInteraction()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let permitted = sourcePermitted
        if lastSourcePermission && !permitted { invalidatePendingResults() }
        lastSourcePermission = permitted
        if let child = childController {
            let attached =
                child.presentingViewController != nil || child.viewIfLoaded?.window != nil
                || presentedViewController === child
            if attached {
                childWasPresented = true
            } else if childFinished, !child.isBeingPresented {
                childController = nil
                isFinishingPicker = false
                if activity == .choosing || activity == .picking { activity = .idle }
                if viewIfLoaded?.window != nil, !isPresentationLeaving { isVisible = true }
                let action = pendingChildAction
                pendingChildAction = nil
                updateInteraction()
                if isAvailable {
                    becomeFirstResponder()
                    UIAccessibility.post(notification: .screenChanged, argument: bodyView.moreButton)
                    action?()
                }
            } else if !childWasPresented, !child.isBeingPresented,
                presentationContext?.isForeground == true,
                ProcessInfo.processInfo.systemUptime >= childPresentationDeadline
            {
                // UIKit can attach a presentation on a later run loop. Never reject it synchronously.
                childController = nil
                isFinishingPicker = false
                retryAction = activity == .choosing ? .systemFonts : .pickDirectory
                activity = .idle
                failureMessage = "无法打开选择窗口，请重试。"
                bodyView.revealStatusOnNextLayout()
            }
        }
        updateInteraction()
        fontList.resumeDelivery()
        guard canInteract else { return }
        if !hasRequestedEntries || needsReload {
            hasRequestedEntries = true
            needsReload = false
            loadEntries()
        } else if pendingAutomaticPicker && !bodyView.isMenuVisible {
            pendingAutomaticPicker = false
            automaticPickerAttempted = true
            openDirectory()
        }
    }

    private func startInteractionRefresh() {
        interactionTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.1, target: InteractionTarget(owner: self),
            selector: #selector(InteractionTarget.tick(_:)), userInfo: nil, repeats: true)
        interactionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene,
            scene !== (viewIfLoaded?.window ?? presentingViewController?.viewIfLoaded?.window)?.windowScene
        {
            return
        }
        if let window = notification.object as? UIWindow,
            presentationContext?.owns(window: window) != true
        {
            return
        }
        if notification.name == UIApplication.willResignActiveNotification
            || notification.name == UIScene.willDeactivateNotification
            || notification.name == UIWindow.didResignKeyNotification
        {
            isEnvironmentSuspended = true
            invalidatePendingResults(resetPreviews: false)
            bodyView.hideMenu(restoreFocus: false)
        } else {
            isEnvironmentSuspended = presentationContext?.isForeground != true
        }
        refreshPresentation()
        scheduleRefresh()
    }

    private func loadEntries(directory: URL? = nil) {
        guard canInteract else { return }
        activity = .loading
        fontList.beginCatalogChange(traits: traitCollection)
        failureMessage = nil
        retryAction = nil
        let id = UUID()
        let generation = contextGeneration
        operationID = id
        updateInteraction()
        operationTask = Task { [self] in
            defer { finishOperation(id) }
            do {
                let snapshot: ReaderFontLibrarySnapshot
                if let directory {
                    snapshot = try await ReaderFontLibraryWork.chooseDirectory(directory)
                } else {
                    snapshot = try await ReaderFontLibraryWork.load()
                }
                guard acceptsResult(id, generation: generation) else {
                    needsReload = true
                    return
                }
                let filename = await ReaderFontLibraryWork.selectedFilename(for: selectedFontName)
                guard acceptsResult(id, generation: generation) else {
                    needsReload = true
                    return
                }
                fontList.stageEntries(snapshot.entries) { [weak self] in
                    guard let self else { return }
                    self.selectedFilename = filename
                    self.warning = snapshot.warning
                    self.pendingAutomaticPicker = snapshot.requiresDirectorySelection && !self.automaticPickerAttempted
                    if self.warning != nil { self.bodyView.revealStatusOnNextLayout() }
                    self.updateInteraction()
                }
            } catch {
                guard acceptsResult(id, generation: generation) else {
                    needsReload = true
                    return
                }
                failureMessage = "\(L10n.ReaderAppearance.fontLoadFailed)\n\(error.localizedDescription)"
                retryAction = directory.map { .directory($0) } ?? .load
                bodyView.revealStatusOnNextLayout()
            }
        }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationTask = nil
        operationID = nil
        if activity == .loading { fontList.finishCatalogChange() }
        activity = .idle
        guard !isClosing else { return }
        updateInteraction()
        scheduleRefresh()
    }

    private func isSelected(_ entry: ReaderFontEntry) -> Bool {
        guard let selectedFontName, !selectedFontName.isEmpty else { return false }
        let entries = fontList.entries
        // Directory filenames take priority, but disambiguated owned rows keep token identity.
        let directoryMatch = selectedFilename.flatMap { filename in
            entries.first { $0.identifier.hasPrefix("reader-font-directory:") && $0.title.utf8.elementsEqual(filename.utf8) }
        }
        let match =
            directoryMatch
            ?? entries.first { $0.identifier == (ReaderFontSelectionToken(identifier: selectedFontName)?.catalogIdentifier ?? selectedFontName) }
            ?? entries.first { !$0.postScriptName.isEmpty && $0.postScriptName == selectedFontName }
            ?? selectedFilename.flatMap { filename in entries.first { $0.title.utf8.elementsEqual(filename.utf8) } }
        return match?.identifier == entry.identifier
    }

    private func showSystemFonts() {
        guard canInteract, !bodyView.isMenuVisible else { return }
        let generation = contextGeneration
        let names: [String?] = [nil, "Georgia", "Menlo-Regular"]
        let chooser = ReaderBookChoiceDialogViewController(
            title: L10n.ReaderAppearance.fontSystemPicker,
            choices: [
                .init(title: L10n.ReaderAppearance.fontSystemDefault, accessibilityValue: "default"),
                .init(title: L10n.ReaderAppearance.fontSystemSerif, accessibilityValue: "serif"),
                .init(title: L10n.ReaderAppearance.fontSystemMonospaced, accessibilityValue: "monospaced"),
            ], identifierPrefix: "reader.font.system"
        ) { [weak self] index in
            guard let self, names.indices.contains(index), self.contextGeneration == generation,
                self.sourcePermitted, self.presentationContext?.isForeground == true
            else { return }
            self.pendingChildAction = { [weak self] in
                guard let self, self.contextGeneration == generation else { return }
                self.saveSelection(.system(names[index]))
            }
        }
        chooser.onClose = { [weak self, weak chooser] in
            guard let self, let chooser, self.childController === chooser else { return }
            self.childFinished = true
            self.scheduleRefresh()
        }
        beginChild(chooser, activity: .choosing)
    }

    private func saveSelection(_ selection: Selection) {
        guard canInteract, !bodyView.isMenuVisible else { return }
        activity = .saving
        failureMessage = nil
        retryAction = nil
        let id = UUID()
        let generation = contextGeneration
        operationID = id
        updateInteraction()
        UIAccessibility.post(notification: .announcement, argument: L10n.Common.loadingTitle)
        operationTask = Task { [self] in
            defer { finishOperation(id) }
            do {
                let identifier: String?
                switch selection {
                case .entry(let entry):
                    identifier = try await ReaderFontLibraryWork.selectionIdentifier(for: entry)
                case .system(let name): identifier = name
                }
                // The worker may copy/register a font; recheck the source before applying it.
                guard acceptsResult(id, generation: generation) else { return }
                try await onSelect(identifier)
                guard acceptsResult(id, generation: generation) else { return }
                selectedFontName = identifier
                isClosing = true
                interactionTimer?.invalidate()
                updateInteraction()
                resignFirstResponder()
                dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
            } catch {
                guard acceptsResult(id, generation: generation) else { return }
                failureMessage = "\(L10n.Common.unavailableTitle)\n\(error.localizedDescription)"
                retryAction = .selection(selection)
                bodyView.revealStatusOnNextLayout()
                UIAccessibility.post(notification: .announcement, argument: failureMessage)
            }
        }
    }

    private func openDirectory() {
        guard canInteract else { return }
        automaticPickerAttempted = true
        pendingAutomaticPicker = false
        bodyView.hideMenu(restoreFocus: false)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        beginChild(picker, activity: .picking)
    }

    private func beginChild(_ child: UIViewController, activity: Activity) {
        guard canInteract else { return }
        view.endEditing(true)
        child.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        childController = child
        childWasPresented = false
        childFinished = false
        pendingChildAction = nil
        childPresentationDeadline = ProcessInfo.processInfo.systemUptime + 3
        self.activity = activity
        updateInteraction()
        present(child, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak child] in
            guard let self, let child, self.childController === child else { return }
            self.childWasPresented = true
            child.presentationController?.delegate = self
            self.scheduleRefresh()
        }
        child.presentationController?.delegate = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicker(controller, directory: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicker(controller, directory: nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard childController === presentationController.presentedViewController else { return }
        childFinished = true
        scheduleRefresh()
    }

    private func finishPicker(_ picker: UIDocumentPickerViewController, directory: URL?) {
        guard childController === picker, activity == .picking, !isFinishingPicker else { return }
        isFinishingPicker = true
        let generation = contextGeneration
        if let directory {
            pendingChildAction = { [weak self] in
                guard let self, self.contextGeneration == generation else { return }
                self.loadEntries(directory: directory)
            }
        }
        let completion: () -> Void = { [weak self, weak picker] in
            guard let self, let picker, self.childController === picker else { return }
            self.childFinished = true
            self.scheduleRefresh()
        }
        if picker.isBeingDismissed, let transition = picker.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled {
                    self?.isFinishingPicker = false
                    self?.pendingChildAction = nil
                } else {
                    completion()
                }
            }
        } else if picker.presentingViewController != nil {
            picker.dismiss(animated: !UIAccessibility.isReduceMotionEnabled, completion: completion)
        } else {
            completion()
        }
    }

    private func retry() {
        guard canInteract, !bodyView.isMenuVisible else { return }
        switch retryAction ?? .load {
        case .load: loadEntries()
        case .systemFonts: showSystemFonts()
        case .pickDirectory: openDirectory()
        case .directory(let url): loadEntries(directory: url)
        case .selection(let selection): saveSelection(selection)
        }
    }

    @objc private func cancel() {
        if bodyView.isMenuVisible {
            bodyView.hideMenu(restoreFocus: true)
            return
        }
        guard canCancel else { return }
        isClosing = true
        invalidatePendingResults()
        interactionTimer?.invalidate()
        updateInteraction()
        resignFirstResponder()
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @MainActor
    private final class InteractionTarget: NSObject {
        weak var owner: ReaderFontDialogViewController?
        init(owner: ReaderFontDialogViewController) { self.owner = owner }
        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.refreshPresentation()
        }
    }
}
