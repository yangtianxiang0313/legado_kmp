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
    private let recoveryBar = UIView()
    private let retryWritesButton = UIButton(type: .system)
    private let discardWritesButton = UIButton(type: .system)
    private var recoveryBarHeight: NSLayoutConstraint?
    private var bodyContentHeight: CGFloat = 380
    private weak var failedWriteQueue: ReaderBackgroundTextWriteQueue?
    private var writeFailureID: UUID?
    private var failedDuringRebinding = false
    private var recoveryTask: Task<Void, Never>?
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

    override func loadView() {
        view = UIView()
        for child in [body, recoveryBar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        recoveryBar.isHidden = true
        recoveryBar.accessibilityIdentifier = "readerAppearance.backgroundText.recovery"
        let height = recoveryBar.heightAnchor.constraint(equalToConstant: 0)
        recoveryBarHeight = height
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: recoveryBar.topAnchor),
            recoveryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recoveryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            recoveryBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        for (button, symbol, title, identifier, discard) in [
            (retryWritesButton, "arrow.clockwise", "重试背景配置", "retry", false),
            (discardWritesButton, "xmark", "放弃未保存的背景改动", "discard", true),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = title
            button.accessibilityIdentifier = "readerAppearance.backgroundText.recovery.\(identifier)"
            button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
            button.addAction(UIAction { [weak self] _ in self?.recoverFailedWrites(discard: discard) }, for: .touchUpInside)
            recoveryBar.addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
                button.topAnchor.constraint(equalTo: recoveryBar.topAnchor, constant: 4),
            ])
        }
        NSLayoutConstraint.activate([
            discardWritesButton.trailingAnchor.constraint(equalTo: recoveryBar.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            retryWritesButton.trailingAnchor.constraint(equalTo: discardWritesButton.leadingAnchor, constant: -4),
            retryWritesButton.leadingAnchor.constraint(greaterThanOrEqualTo: recoveryBar.safeAreaLayoutGuide.leadingAnchor, constant: 10),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "readerAppearance.backgroundText"
        body.onContentHeightChange = { [weak self] height in
            guard let self else { return }
            self.bodyContentHeight = height
            self.preferredContentSize.height = height + (self.recoveryBarHeight?.constant ?? 0)
        }
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
        refresh()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        refresh()
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
        refresh()
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
        if let failedWriteQueue, !visualBinding.isSwitching,
            writes !== failedWriteQueue || (!failedDuringRebinding && !writes.isPending)
        {
            writeFailureID = nil
            self.failedWriteQueue = nil
            failedDuringRebinding = false
        }
        body.apply(name: presetName, style: writes.style, isBusy: isPerformingCommand || visualBinding.isSwitching)
        body.apply(palette: ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection))
        view.backgroundColor = AndroidReplicaTheme.bottomBackground
        recoveryBar.isHidden = writeFailureID == nil
        recoveryBar.accessibilityElementsHidden = recoveryBar.isHidden
        recoveryBarHeight?.constant = recoveryBar.isHidden ? 0 : 52 + view.safeAreaInsets.bottom
        preferredContentSize.height = bodyContentHeight + (recoveryBarHeight?.constant ?? 0)
        let canRecover = writeFailureID != nil && recoveryTask == nil && canUseControls && failedWriteQueue === writes
        retryWritesButton.isEnabled = canRecover
        discardWritesButton.isEnabled = canRecover
        retryWritesButton.tintColor = AndroidReplicaTheme.accent
        discardWritesButton.tintColor = ReaderSearchChromePalette.foreground
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
        presentError(error)
    }

    private func showWriteFailure(_ error: Error) {
        failedDuringRebinding = visualBinding.isSwitching || (failedWriteQueue === writes && failedDuringRebinding)
        failedWriteQueue = writes
        writeFailureID = UUID()
        refresh()
        guard canPresentBackgroundAction, presentedViewController == nil else { return }
        showTransientMessage(error.userFacingMessage)
    }

    private func recoverFailedWrites(discard: Bool) {
        guard let failureID = writeFailureID, let failedWriteQueue,
            failedWriteQueue === writes, recoveryTask == nil, canUseControls
        else { return }
        body.cancelPendingTracking()
        recoveryTask = Task { @MainActor [self] in
            defer {
                recoveryTask = nil
                refresh()
            }
            guard writeFailureID == failureID, failedWriteQueue === writes, canUseControls else { return }
            if discard {
                visualBinding.discardFailedChanges()
            } else {
                visualBinding.retry()
            }
            do {
                try await visualBinding.flush()
                // A rebind reports through onFailure before flush returns; never clear that newer failure.
                guard writeFailureID == failureID, !visualBinding.isSwitching, !writes.isPending else { return }
                writeFailureID = nil
                self.failedWriteQueue = nil
                failedDuringRebinding = false
            } catch {
                if writeFailureID == failureID { showWriteFailure(error) }
            }
        }
        refresh()
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
