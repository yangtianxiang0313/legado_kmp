import UIKit
import shared

@MainActor
final class AndroidReaderStyleSheetViewController: UIViewController {
    static let preferredSheetHeight: CGFloat = AndroidReaderStyleSheetBodyView.contentHeight

    let screen = ReaderAppearanceScreenAdapter()
    var state: ReaderAppearanceState?
    private let bodyView = AndroidReaderStyleSheetBodyView()
    private var bootstrapTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var writes: ReaderBackgroundTextWriteQueue?
    private var isPerformingCommand = false
    private var bookBinding: ReaderAppearanceBookBinding?
    private var isPresentationVisible = false
    private weak var presentationScene: UIWindowScene?
    private var isSceneActive = false

    func bind(to reader: ReaderContainerViewController) {
        bookBinding = ReaderAppearanceBookBinding(reader: reader)
    }

    deinit {
        bootstrapTask?.cancel()
        screen.unbind()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationVisible = false
        updateControlAvailability()
        if isBeingDismissed || parent?.isBeingDismissed == true {
            bootstrapTask?.cancel()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = UIIdentifiers.ReaderAppearance.root
        preferredContentSize = CGSize(width: 0, height: Self.preferredSheetHeight)
        configureViews()
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        bindScreen()
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationVisible = true
        presentationScene = view.window?.windowScene
        isSceneActive = presentationScene?.activationState == .foregroundActive
        updateControlAvailability()
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === presentationScene else { return }
        isSceneActive = notification.name == UIScene.didActivateNotification
        updateControlAvailability()
    }

    private var canUseControls: Bool {
        guard isPresentationVisible, isSceneActive, !isPerformingCommand, state != nil,
            bookBinding?.isCurrent != false, ReaderAppearanceSelectionContext.isVisible(self)
        else { return false }
        var controller: UIViewController? = self
        while let current = controller {
            guard current.presentedViewController == nil, !current.isBeingPresented else { return false }
            controller = current.parent
        }
        return true
    }

    private func updateControlAvailability() {
        guard isViewLoaded else { return }
        let enabled =
            isPresentationVisible && isSceneActive && state != nil
            && !isPerformingCommand && bookBinding?.isCurrent != false
        bodyView.setSliderInteractionEnabled(enabled)
        bodyView.isUserInteractionEnabled = enabled
        bodyView.accessibilityElementsHidden = state == nil
    }

    func controlBookValidation() -> () -> Bool {
        let binding = bookBinding
        return { binding?.isCurrent != false }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { render() }
    }

    private var palette: ReaderMenuPalette {
        ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection)
    }

    private func configureViews() {
        bodyView.canInteract = { [weak self] in self?.canUseControls == true }
        bodyView.onContentHeightChange = { [weak self] height in self?.preferredContentSize.height = height }
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bodyView)
        NSLayoutConstraint.activate([
            bodyView.topAnchor.constraint(equalTo: view.topAnchor),
            bodyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configureSliders()
        let actions: [(AndroidReaderStyleQuickButton, String, () -> Void)] = [
            (bodyView.fontWeightButton, UIIdentifiers.ReaderAppearance.fontWeightButton, { [weak self] in self?.openFontWeightPicker() }),
            (bodyView.fontButton, UIIdentifiers.ReaderAppearance.fontButton, { [weak self] in self?.openFontPicker() }),
            (bodyView.indentButton, UIIdentifiers.ReaderAppearance.indentButton, { [weak self] in self?.openIndentPicker() }),
            (bodyView.chineseButton, UIIdentifiers.ReaderAppearance.chineseButton, { [weak self] in self?.openChineseModePicker() }),
            (bodyView.paddingButton, UIIdentifiers.ReaderAppearance.paddingButton, { [weak self] in self?.openPaddingPicker() }),
            (bodyView.tipButton, UIIdentifiers.ReaderAppearance.tipButton, { [weak self] in self?.openTipPicker() }),
        ]
        for (button, identifier, action) in actions {
            button.accessibilityIdentifier = identifier
            button.addAction(
                UIAction { [weak self] _ in
                    self?.runSettingTask { [weak self] in
                        guard let self, self.viewIfLoaded?.window != nil,
                            !self.isBeingDismissed, self.parent?.isBeingDismissed != true
                        else { return }
                        action()
                    }
                }, for: .touchUpInside)
        }
        bodyView.onPageAnimationSelected = { [weak self] option in
            self?.selectPageAnimation(option)
        }
        bodyView.shareLayoutButton.addAction(
            UIAction { [weak self] _ in
                guard let self, let state = self.state else { return }
                let enabled = !state.runtimeConfig.reader.shareLayout
                self.runSettingTask { try await self.screen.setShareLayout(enabled: enabled) }
            }, for: .touchUpInside)
        bodyView.onPresetSelected = { [weak self] index in self?.selectPreset(index: index, edit: false) }
        bodyView.onPresetEdit = { [weak self] index in self?.selectPreset(index: index, edit: true) }
        bodyView.onAddPreset = { [weak self] in self?.createPreset() }
    }

    private func configureSliders() {
        bodyView.fontSizeRow.configure(min: 5, max: 50) { [weak self] value in
            self?.updateStyle { $0.androidCopy(fontSizeSp: AndroidReaderStyleScale.roundFontSize(value)) }
        }
        bodyView.letterSpacingRow.configure(
            min: AndroidReaderStyleScale.letterSpacingRange.lowerBound,
            max: AndroidReaderStyleScale.letterSpacingRange.upperBound
        ) { [weak self] value in
            self?.updateStyle { $0.androidCopy(letterSpacing: AndroidReaderStyleScale.roundLetterSpacing(value)) }
        }
        bodyView.lineSpacingRow.configure(
            min: AndroidReaderStyleScale.lineProgressRange.lowerBound,
            max: AndroidReaderStyleScale.lineProgressRange.upperBound
        ) { [weak self] value in
            self?.updateStyle {
                $0.androidCopy(lineSpacingMultiplier: AndroidReaderStyleScale.lineSpacingMultiplier(progress: AndroidReaderStyleScale.roundProgress(value)))
            }
        }
        bodyView.paragraphSpacingRow.configure(
            min: AndroidReaderStyleScale.paragraphProgressRange.lowerBound,
            max: AndroidReaderStyleScale.paragraphProgressRange.upperBound
        ) { [weak self] value in
            self?.updateStyle { $0.androidCopy(paragraphSpacing: Int32(AndroidReaderStyleScale.roundProgress(value))) }
        }
    }

    private func bindScreen() {
        screen.onStateChange = { [weak self] value in self?.apply(value) }
        switch screen.bootstrap() {
        case .success:
            bootstrapTask = Task { [weak self] in
                do { try await self?.screen.bootstrapDefaultsIfNeeded() } catch is CancellationError {} catch { self?.showActionError(error) }
            }
        case .failure(let error): showActionError(error)
        }
    }

    private func apply(_ state: ReaderAppearanceState) {
        guard !isPerformingCommand else { return }
        self.state = state
        let interfaceStyle: UIUserInterfaceStyle =
            state.preferences.themeMode == .system ? .unspecified : (state.preferences.themeMode == .dark ? .dark : .light)
        if overrideUserInterfaceStyle != interfaceStyle { overrideUserInterfaceStyle = interfaceStyle }
        if parent?.overrideUserInterfaceStyle != interfaceStyle { parent?.overrideUserInterfaceStyle = interfaceStyle }
        if let writes {
            writes.absorb(state.preferences.readerStyle)
        } else {
            let screen = screen
            let queue = ReaderBackgroundTextWriteQueue(style: state.preferences.readerStyle) {
                try await screen.setReaderStyle(style: $0)
            }
            queue.onChange = { [weak self] in self?.render() }
            queue.onFailure = { [weak self] error in self?.showWriteFailure(error) }
            writes = queue
        }
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        view.backgroundColor = palette.bottomBackground
        bodyView.apply(palette: palette)
        if let state {
            bodyView.apply(
                state: state, presets: screen.readerPresets, palette: palette, styleOverride: writes?.style,
                effectivePageAnimation: bookBinding?.effectiveAnimation(globalValue: Int(state.runtimeConfig.reader.pageAnimation)))
        }
        updateControlAvailability()
    }

    private func updateStyle(_ update: (ReaderStylePreferences) -> ReaderStylePreferences) {
        guard canUseControls else {
            bodyView.cancelPendingSliderTracking()
            return
        }
        writes?.update(update)
    }

    /// Commands are barriers: edits settle before changing their owning preset or opening another editor.
    func runSettingTask(_ operation: @escaping () async throws -> Void) {
        // Child editors also submit here while their parent panel remains covered.
        guard !isPerformingCommand, state != nil, ReaderAppearanceSelectionContext.isVisible(self), bookBinding?.isCurrent != false else { return }
        isPerformingCommand = true
        render()
        commandTask = Task { [self] in
            defer {
                isPerformingCommand = false
                commandTask = nil
                render()
            }
            do {
                try await writes?.flush()
                let before = try await screen.readSnapshot()
                state = before
                writes?.absorb(before.preferences.readerStyle)
                guard ReaderAppearanceSelectionContext.isVisible(self), bookBinding?.isCurrent != false else { return }
                try await operation()
                let after = try await screen.readSnapshot()
                state = after
                writes?.absorb(after.preferences.readerStyle)
            } catch is CancellationError {
            } catch {
                if let actual = try? await screen.readSnapshot() {
                    state = actual
                    writes?.absorb(actual.preferences.readerStyle)
                }
                showActionError(error)
            }
        }
    }

    private func selectPreset(index: Int, edit: Bool) {
        guard screen.readerPresets.indices.contains(index) else { return }
        runSettingTask { [self] in
            if state?.preferences.readerPresetIndex != Int32(index) { try await screen.setReaderPreset(index: Int32(index)) }
            let current = try await screen.readSnapshot()
            state = current
            writes?.absorb(current.preferences.readerStyle)
            if edit { openBackgroundPicker(style: current.preferences.readerStyle, name: current.preferences.readerPresetName) }
        }
    }

    private func createPreset() {
        runSettingTask { [self] in
            _ = try await screen.createReaderPreset()
            let current = try await screen.readSnapshot()
            state = current
            writes?.absorb(current.preferences.readerStyle)
            openBackgroundPicker(style: current.preferences.readerStyle, name: current.preferences.readerPresetName)
        }
    }

    private func openBackgroundPicker(style: ReaderStylePreferences, name: String) {
        guard viewIfLoaded?.window != nil, !isBeingDismissed, parent?.isBeingDismissed != true,
            presentedViewController == nil, controlBookValidation()(),
            let presenter = parent?.presentingViewController ?? presentingViewController
        else { return }
        do {
            let controller = AndroidReaderBackgroundTextSheetViewController(
                style: state?.preferences.effectiveReaderStyle(userInterfaceStyle: traitCollection.userInterfaceStyle) ?? style,
                presetName: name, facade: try SharedRuntime.settingsFacade().get(),
                visualVariant: state.map { ReaderThemeVisualStyle.variant(preferences: $0.preferences, userInterfaceStyle: traitCollection.userInterfaceStyle) }
                    ?? .day,
                presetIndex: state?.preferences.readerPresetIndex ?? 0)
            let interfaceStyle: UIUserInterfaceStyle = state?.preferences.themeMode == .system ? .unspecified : overrideUserInterfaceStyle
            controller.overrideUserInterfaceStyle = interfaceStyle
            let bookIsCurrent = controlBookValidation()
            controller.isBookCurrent = bookIsCurrent
            controller.isUnderlineAvailable = bookBinding?.isImageBook != true
            controller.loadViewIfNeeded()
            let panel = ReaderBottomSheetNavigationController(contentViewController: controller, chromeStyle: .androidPanel)
            panel.overrideUserInterfaceStyle = interfaceStyle
            panel.preferredContentSize = controller.preferredContentSize
            dismiss(animated: true) { [weak presenter] in
                guard let presenter, presenter.presentedViewController == nil,
                    presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive, bookIsCurrent()
                else { return }
                presenter.present(panel, animated: true)
            }
        } catch { showActionError(error) }
    }

    private func openFontWeightPicker() {
        presentStyleChoice(.fontWeight, option: .fontWeight)
    }

    private func openIndentPicker() {
        presentStyleChoice(.indent, option: .paragraphIndent)
    }

    private func openChineseModePicker() {
        presentStyleChoice(.chineseMode, option: .chineseMode)
    }

    private func presentStyleChoice(_ choice: ReaderStyleChoice, option: ReaderAppearanceQuickOption) {
        guard presentedViewController == nil, let state else { return }
        let context = ReaderAppearanceSelectionContext(state)
        let sourceIsCurrent: () -> Bool = { [weak self] in
            guard let self, let state = self.state else { return false }
            return ReaderAppearanceSelectionContext.isVisible(self) && self.bookBinding?.isCurrent != false && context.matches(state)
        }
        let controller = ReaderStyleChoiceDialogViewController(titleText: choice.titleText, items: choice.items) { [weak self] index in
            guard let self, sourceIsCurrent() else { return }
            self.runSettingTask {
                guard sourceIsCurrent() else { throw CancellationError() }
                try await self.screen.setReaderQuickOption(option, value: Int32(index), context: context)
            }
        }
        controller.canSelect = sourceIsCurrent
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        present(controller, animated: true)
    }

    private func selectPageAnimation(_ option: ReaderPageAnimationOption) {
        guard let state else { return }
        let context = ReaderAppearanceSelectionContext(state)
        runSettingTask { [self] in
            guard let current = self.state, context.matches(current) else { throw CancellationError() }
            if let bookBinding {
                try await bookBinding.saveAnimation(option.rawValue) { try await self.screen.setPageAnimation(value: option.rawValue) }
            } else {
                try await screen.setPageAnimation(value: option.rawValue)
            }
        }
    }

    private func openFontPicker() {
        guard presentedViewController == nil, let state,
            viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            !isBeingDismissed, parent?.isBeingDismissed != true
        else { return }
        let expectedName = state.preferences.readerPresetName
        let expectedIndex = state.preferences.readerPresetIndex
        let expectedShareLayout = state.runtimeConfig.reader.shareLayout
        let bookIsCurrent = controlBookValidation()
        let sourceIsCurrent: () -> Bool = { [weak self] in
            guard let self, let current = self.state else { return false }
            // The font dialog owns foreground input; this gate tracks the book/style identity.
            return bookIsCurrent() && !self.isBeingDismissed && self.parent?.isBeingDismissed != true
                && current.preferences.readerPresetName == expectedName
                && current.preferences.readerPresetIndex == expectedIndex
                && current.runtimeConfig.reader.shareLayout == expectedShareLayout
        }
        do {
            let facade = try SharedRuntime.settingsFacade().get()
            let controller = ReaderFontDialogViewController(selectedFontName: state.preferences.readerStyle.fontName) { name in
                guard sourceIsCurrent() else { throw CancellationError() }
                try await facade.setReaderFontSelectionAsync(
                    fontName: name, expectedName: expectedName, expectedIndex: expectedIndex,
                    expectedShareLayout: expectedShareLayout)
            }
            controller.canSubmit = { [weak self, weak controller] in
                guard let self, let controller else { return false }
                return self.presentedViewController === controller && sourceIsCurrent()
            }
            controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            present(controller, animated: true)
        } catch { showActionError(error) }
    }

    func presentOptionSheet(title: String, height: CGFloat, options: [AndroidReaderOptionSheetViewController.Option]) {
        presentAppearanceDetail(AndroidReaderOptionSheetViewController(titleText: title, options: options), height: height)
    }

    func presentAppearanceDetail(_ controller: UIViewController, height: CGFloat) {
        guard presentedViewController == nil else { return }
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        let panel = controller.wrappedInReaderBottomSheet(fixedHeight: height)
        panel.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        present(panel, animated: true)
    }

    private func showActionError(_ error: Error) {
        guard presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        presentError(error)
    }

    private func showWriteFailure(_ error: Error) {
        guard presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: nil, message: error.userFacingMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.retry, style: .default) { [weak self] _ in self?.writes?.retry() })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.writes?.discardFailedChanges() })
        present(alert, animated: true)
    }
}
