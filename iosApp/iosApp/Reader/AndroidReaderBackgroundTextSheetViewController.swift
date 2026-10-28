import UIKit
import UniformTypeIdentifiers
import shared

/// BgTextConfigDialog: live page changes, not a preview card or a second settings stack.
@MainActor
final class AndroidReaderBackgroundTextSheetViewController: UIViewController, UIDocumentPickerDelegate {
    let facade: SettingsFacade
    let body = ReaderBackgroundTextBodyView()
    let visualBinding: ReaderBackgroundVisualBinding
    var writes: ReaderBackgroundTextWriteQueue { visualBinding.queue }
    var presetName: String { visualBinding.presetName }
    var presetIndex: Int32 { visualBinding.presetIndex }
    var isPerformingCommand = false
    var commandTask: Task<Void, Never>?
    private var preferencesSubscription: FlowSubscription?
    private var imageQueue: ReaderBackgroundTextWriteQueue?
    private weak var imagePicker: UIDocumentPickerViewController?
    private var isVisible = false
    private var isSceneActive = false
    var isBookCurrent: (() -> Bool)?
    var isUnderlineAvailable = true
    lazy var configTransfer = ReaderPresetTransferCoordinator(owner: self)
    lazy var colorSelection = ReaderBackgroundColorSelectionCoordinator(owner: self)

    var canPresentBackgroundAction: Bool {
        isVisible && isSceneActive && isBookCurrent?() != false && ReaderAppearanceSelectionContext.isVisible(self)
    }

    private var canUseControls: Bool {
        guard canPresentBackgroundAction, !isPerformingCommand, !visualBinding.isSwitching else { return false }
        var current: UIViewController? = self
        while let controller = current {
            guard controller.presentedViewController == nil, !controller.isBeingPresented else { return false }
            current = controller.parent
        }
        return true
    }

    init(style: ReaderStylePreferences, presetName: String, facade: SettingsFacade, visualVariant: ReaderVisualVariant = .day, presetIndex: Int32 = 0) {
        self.facade = facade
        visualBinding = ReaderBackgroundVisualBinding(style: style, presetName: presetName, variant: visualVariant, facade: facade, presetIndex: presetIndex)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: 380)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        preferencesSubscription?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() { view = body }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "readerAppearance.backgroundText"
        body.onContentHeightChange = { [weak self] height in self?.preferredContentSize.height = height }
        visualBinding.onChange = { [weak self] in self?.refresh() }
        visualBinding.onFailure = { [weak self] in self?.showWriteFailure($0) }
        configureActions()
        body.canInteract = { [weak self] in self?.canUseControls == true }
        body.isUnderlineAvailable = isUnderlineAvailable
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        refresh()
        preferencesSubscription = facade.watchPreferences { [weak self] preferences in
            DispatchQueue.main.async {
                guard let self else { return }
                let interfaceStyle: UIUserInterfaceStyle = preferences.themeMode == .system ? .unspecified : (preferences.themeMode == .dark ? .dark : .light)
                if self.overrideUserInterfaceStyle != interfaceStyle { self.overrideUserInterfaceStyle = interfaceStyle }
                if self.parent?.overrideUserInterfaceStyle != interfaceStyle { self.parent?.overrideUserInterfaceStyle = interfaceStyle }
                self.visualBinding.receive(preferences, interfaceStyle: self.traitCollection.userInterfaceStyle)
                self.refresh()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        isSceneActive = view.window?.windowScene?.activationState == .foregroundActive
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        body.cancelPendingTracking()
        if isBeingDismissed || parent?.isBeingDismissed == true {
            isVisible = false
            imageQueue = nil
            imagePicker?.delegate = nil
            configTransfer.deactivate()
            colorSelection.deactivate()
        }
    }

    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        body.cancelPendingTracking()
        super.present(controller, animated: animated, completion: completion)
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === viewIfLoaded?.window?.windowScene else { return }
        isSceneActive = notification.name == UIScene.didActivateNotification
        if !isSceneActive {
            body.cancelPendingTracking()
            imageQueue = nil
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded {
            visualBinding.updateInterfaceStyle(traitCollection.userInterfaceStyle)
            refresh()
        }
    }

    private func configureActions() {
        body.darkStatusSwitch.addTarget(self, action: #selector(changeDarkStatus), for: .valueChanged)
        body.underlineSwitch.addTarget(self, action: #selector(changeUnderline), for: .valueChanged)
        body.alphaSlider.addTarget(self, action: #selector(changeAlpha), for: .valueChanged)
        body.editNameButton.addAction(UIAction { [weak self] _ in self?.showRename() }, for: .touchUpInside)
        body.restoreButton.addAction(UIAction { [weak self] _ in self?.showRestore() }, for: .touchUpInside)
        body.textColorButton.addAction(UIAction { [weak self] _ in self?.showColor(.text) }, for: .touchUpInside)
        body.backgroundColorButton.addAction(UIAction { [weak self] _ in self?.showColor(.background) }, for: .touchUpInside)
        body.importButton.addAction(UIAction { [weak self] _ in self?.showConfigImport() }, for: .touchUpInside)
        body.exportButton.addAction(UIAction { [weak self] _ in self?.exportConfig() }, for: .touchUpInside)
        body.deleteButton.addAction(UIAction { [weak self] _ in self?.confirmDelete() }, for: .touchUpInside)
        body.imageStrip.onImport = { [weak self] in self?.showImageImport() }
        body.imageStrip.onSelect = { [weak self] item in
            guard let self, self.canUseControls else { return }
            self.writes.update { $0.androidCopy(backgroundImagePath: item.storedPath) }
        }
    }

    func refresh() {
        guard isViewLoaded else { return }
        body.apply(name: presetName, style: writes.style, isBusy: isPerformingCommand || visualBinding.isSwitching)
        body.apply(palette: ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection))
    }

    @objc private func changeDarkStatus() {
        guard canUseControls else {
            body.cancelPendingTracking()
            return
        }
        let enabled = body.darkStatusSwitch.isOn
        writes.update { $0.androidCopy(darkStatusIcon: enabled) }
    }

    @objc private func changeUnderline() {
        guard canUseControls, isUnderlineAvailable else {
            body.cancelPendingTracking()
            return
        }
        let enabled = body.underlineSwitch.isOn
        writes.update { $0.androidCopy(underline: enabled) }
    }

    @objc private func changeAlpha() {
        guard canUseControls else {
            body.cancelPendingTracking()
            return
        }
        let value = Int32(body.alphaSlider.value.rounded()).clamped(to: 0...100)
        writes.update { $0.androidCopy(backgroundAlpha: value) }
    }

    func runCommand(_ operation: @escaping () async throws -> Void) {
        guard !isPerformingCommand else { return }
        isPerformingCommand = true
        refresh()
        commandTask = Task { [self] in
            defer {
                isPerformingCommand = false
                commandTask = nil
                refresh()
            }
            do {
                try await visualBinding.flush()
                try await operation()
                let latest = try await ReaderAppearanceSnapshotRequest.read(facade: facade)
                visualBinding.acceptSnapshot(latest.preferences, interfaceStyle: traitCollection.userInterfaceStyle)
                try await visualBinding.flush()
            } catch {
                guard canPresentBackgroundAction, !(error is CancellationError) else { return }
                showActionError(error)
            }
        }
    }

    func showActionError(_ error: Error) {
        guard canPresentBackgroundAction, presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: error.userFacingMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .cancel))
        present(alert, animated: true)
    }

    private func showWriteFailure(_ error: Error) {
        guard canPresentBackgroundAction, presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: error.userFacingMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.retry, style: .default) { [weak self] _ in self?.visualBinding.retry() })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.visualBinding.discardFailedChanges() })
        present(alert, animated: true)
    }

    func showColor(_ target: AndroidReaderStyleColorTarget) {
        colorSelection.present(target)
    }

    func showImageImport() {
        guard canUseControls else { return }
        imageQueue = writes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        imagePicker = picker
        present(picker, animated: true)
    }

    func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard imagePicker === picker else { return }
        let queue = imageQueue
        self.imageQueue = nil
        imagePicker = nil
        picker.delegate = nil
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let queue, let url = urls.first, self.canUseControls, self.writes === queue else { return }
            self.runCommand { [weak self] in
                guard let self, self.canPresentBackgroundAction, self.writes === queue else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try ReaderBackgroundTextFiles.read(url, limit: 32 * 1024 * 1024)
                let path = try ReaderBackgroundTextFiles.importImage(data)
                queue.update { $0.androidCopy(backgroundImagePath: path) }
                try await queue.flush()
            }
        }
    }

    func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
        guard imagePicker === picker else { return }
        imageQueue = nil
        imagePicker = nil
        picker.delegate = nil
    }
}

extension Int32 {
    fileprivate func clamped(to range: ClosedRange<Int32>) -> Int32 { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
