import UIKit
import shared

final class ReaderMoreSettingsViewController: ReaderSettingsBoundViewController {
    static let preferredSheetHeight: CGFloat = 360

    var onTapZoneConfig: (() -> Void)?
    var onLocalSettingsChange: ((ReaderLocalSettings, ReaderLocalSettings) -> Void)?
    var onReaderRuntimeConfigChange: ((ReaderRuntimeConfig) -> Void)?
    var onDisableReturnKeyChange: (() -> Void)?

    private let listView = ReaderPreferenceListView()
    private var localSettings = ReaderLocalSettings.load()
    private var autoChangeSourceEnabled = ReaderMoreSettingsPreferenceBridge.autoChangeSourceEnabled()
    private var pendingRuntimeConfig: ReaderRuntimeConfig?
    private var runtimeWriteRevision = 0
    private var runtimeWriteTask: Task<Void, Never>?
    private var bookBinding: ReaderAppearanceBookBinding?
    private var isPresentationVisible = false
    private weak var presentationScene: UIWindowScene?
    private var isSceneActive = false

    func bind(to reader: ReaderContainerViewController) {
        bookBinding = ReaderAppearanceBookBinding(reader: reader)
    }

    private var displayedRuntimeConfig: ReaderRuntimeConfig? {
        pendingRuntimeConfig ?? state?.runtimeConfig.reader
    }

    func setLocalSettings(_ settings: ReaderLocalSettings) {
        localSettings = settings
        if isViewLoaded { rebuildRows() }
    }

    deinit {
        runtimeWriteTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.backgroundColor = AndroidReplicaTheme.bottomBackground
        view.accessibilityIdentifier = UIIdentifiers.ReaderMoreSettings.root
        stateView.setTestingIdentifier(UIIdentifiers.ReaderMoreSettings.state)
        preferredContentSize = CGSize(width: 0, height: Self.preferredSheetHeight)
        configureViews()
        listView.canInteract = { [weak self] in self?.canUseSettings == true }
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        rebuildRows()
        bootstrapReaderSettings()
        updateInteractionAvailability()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationVisible = true
        presentationScene = view.window?.windowScene
        isSceneActive = presentationScene?.activationState == .foregroundActive
        updateInteractionAvailability()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationVisible = false
        updateInteractionAvailability()
        if isBeingDismissed || isMovingFromParent || parent?.isBeingDismissed == true {
            runtimeWriteTask?.cancel()
        }
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === presentationScene else { return }
        isSceneActive = notification.name == UIScene.didActivateNotification
        updateInteractionAvailability()
    }

    private var ownsSettings: Bool {
        isPresentationVisible && isSceneActive && state != nil && bookBinding?.isCurrent != false
            && ReaderAppearanceSelectionContext.isVisible(self)
    }

    private var canUseSettings: Bool {
        guard ownsSettings else { return false }
        var controller: UIViewController? = self
        while let current = controller {
            guard current.presentedViewController == nil, !current.isBeingPresented else { return false }
            controller = current.parent
        }
        return true
    }

    private func updateInteractionAvailability() {
        guard isViewLoaded else { return }
        listView.setInteractionActive(ownsSettings)
    }

    private func presentSettingsEditor(_ controller: UIViewController) {
        guard canUseSettings else { return }
        listView.setInteractionActive(false)
        present(controller, animated: true) { [weak self] in self?.updateInteractionAvailability() }
    }

    override func apply(_ state: ReaderAppearanceState) {
        super.apply(state)
        if pendingRuntimeConfig == state.runtimeConfig.reader { pendingRuntimeConfig = nil }
        rebuildRows()
        updateInteractionAvailability()
    }

    private func configureViews() {
        listView.scrollView.accessibilityIdentifier = UIIdentifiers.ReaderMoreSettings.table
        for item in [listView, stateView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func rebuildRows() {
        let runtime = displayedRuntimeConfig
        // Match pref_config_read.xml order. Android-only cutout/body-height/CanvasRecorder controls are not simulated.
        let rows: [ReaderPreferenceItem] = [
            valueRow(
                title: L10n.Reader.screenOrientationTitle, value: localSettings.screenOrientation.title,
                identifier: UIIdentifiers.ReaderMoreSettings.screenOrientationRow
            ) { [weak self] in
                self?.openScreenOrientationPicker()
            },
            valueRow(
                title: L10n.Reader.screenTimeoutTitle,
                value: ReaderScreenTimeoutMenuSupport.title(localSettings.screenTimeout),
                identifier: UIIdentifiers.ReaderMoreSettings.screenTimeoutRow
            ) { [weak self] in
                self?.openScreenTimeoutPicker()
            },
            toggleRow(
                title: L10n.ReaderAppearance.hideStatusBar, isOn: runtime?.hideStatusBar ?? false,
                identifier: UIIdentifiers.ReaderMoreSettings.hideStatusBarSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.hideStatusBarRow,
                enabled: runtime != nil
            ) { [weak self] value in self?.updateReaderRuntimeConfig { $0.androidReaderMoreCopy(hideStatusBar: value) }
            },
            toggleRow(
                title: L10n.ReaderAppearance.hideNavigationBar, isOn: runtime?.hideNavigationBar ?? false,
                identifier: UIIdentifiers.ReaderMoreSettings.hideNavigationBarSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.hideNavigationBarRow,
                enabled: runtime != nil
            ) { [weak self] value in
                self?.updateReaderRuntimeConfig { $0.androidReaderMoreCopy(hideNavigationBar: value) }
            },
            valueRow(
                title: L10n.Reader.doublePageHorizontalTitle,
                value: AndroidReaderDoublePageHorizontalMenuSupport.title(localSettings.doubleHorizontalPage),
                identifier: UIIdentifiers.ReaderMoreSettings.doublePageHorizontalRow
            ) { [weak self] in self?.openDoublePageHorizontalPicker() },
            valueRow(
                title: L10n.Reader.progressBehaviorTitle, value: localSettings.progressBehavior.title,
                identifier: UIIdentifiers.ReaderMoreSettings.progressBehaviorRow
            ) { [weak self] in self?.openProgressBehaviorPicker() },
            toggleRow(
                title: L10n.Reader.zhLayoutTitle, isOn: runtime?.useZhLayout ?? false,
                identifier: UIIdentifiers.ReaderMoreSettings.zhLayoutSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.zhLayoutRow,
                enabled: runtime != nil
            ) { [weak self] value in self?.updateReaderRuntimeConfig { $0.androidReaderMoreCopy(useZhLayout: value) } },
            toggleRow(
                title: L10n.ReaderAppearance.textFullJustify, isOn: runtime?.textFullJustify ?? true,
                identifier: UIIdentifiers.ReaderMoreSettings.textFullJustifySwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.textFullJustifyRow,
                enabled: runtime != nil
            ) { [weak self] value in
                self?.updateReaderRuntimeConfig { $0.androidReaderMoreCopy(textFullJustify: value) }
            },
            toggleRow(
                title: L10n.ReaderAppearance.textBottomJustify, isOn: runtime?.textBottomJustify ?? true,
                identifier: UIIdentifiers.ReaderMoreSettings.textBottomJustifySwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.textBottomJustifyRow,
                enabled: runtime != nil
            ) { [weak self] value in
                self?.updateReaderRuntimeConfig { $0.androidReaderMoreCopy(textBottomJustify: value) }
            },
            toggleRow(
                title: L10n.Reader.mouseWheelPageTitle, isOn: ReaderHardwarePagingPreference.mouseWheelPageEnabled(),
                identifier: UIIdentifiers.ReaderMoreSettings.mouseWheelPageSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.mouseWheelPageRow
            ) { [weak self] in self?.updateMouseWheelPage($0) },
            toggleRow(
                title: L10n.Reader.keyPageTitle, isOn: ReaderHardwarePagingPreference.keyPageEnabled(),
                identifier: UIIdentifiers.ReaderMoreSettings.keyPageSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.keyPageRow
            ) { [weak self] in self?.updateKeyPage($0) },
            toggleRow(
                title: L10n.Reader.keyPageOnReadAloudTitle,
                isOn: ReaderHardwarePagingPreference.keyPageOnReadAloudEnabled(),
                identifier: UIIdentifiers.ReaderMoreSettings.keyPageOnReadAloudSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.keyPageOnReadAloudRow
            ) { [weak self] in self?.updateKeyPageOnReadAloud($0) },
            toggleRow(
                title: L10n.Reader.keyPageOnLongPressTitle,
                isOn: ReaderHardwarePagingPreference.keyPageOnLongPressEnabled(),
                identifier: UIIdentifiers.ReaderMoreSettings.keyPageOnLongPressSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.keyPageOnLongPressRow
            ) { [weak self] in self?.updateKeyPageOnLongPress($0) },
            actionRow(
                title: L10n.Reader.pageTouchSlopTitle, summary: pageTouchSlopSummary,
                identifier: UIIdentifiers.ReaderMoreSettings.pageTouchSlopRow
            ) { [weak self] in self?.openPageTouchSlopSheet() },
            toggleRow(
                title: L10n.Settings.autoChangeSourceTitle, isOn: autoChangeSourceEnabled,
                identifier: UIIdentifiers.ReaderMoreSettings.autoChangeSourceSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.autoChangeSourceRow
            ) { [weak self] in self?.updateAutoChangeSource($0) },
            toggleRow(
                title: L10n.Reader.textSelectableTitle, isOn: localSettings.textSelectable,
                identifier: UIIdentifiers.ReaderMoreSettings.textSelectableSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.textSelectableRow
            ) { [weak self] value in self?.updateLocalSettings { $0.textSelectable = value } },
            toggleRow(
                title: L10n.Reader.showBrightnessBarTitle, isOn: localSettings.showBrightnessBar,
                identifier: UIIdentifiers.ReaderMoreSettings.showBrightnessBarSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.showBrightnessBarRow
            ) { [weak self] value in self?.updateLocalSettings { $0.showBrightnessBar = value } },
            toggleRow(
                title: L10n.Reader.noAnimScrollPageTitle, isOn: localSettings.noAnimScrollPage,
                identifier: UIIdentifiers.ReaderMoreSettings.noAnimScrollPageSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.noAnimScrollPageRow
            ) { [weak self] value in self?.updateLocalSettings { $0.noAnimScrollPage = value } },
            toggleRow(
                title: L10n.Reader.previewImageByClickTitle, isOn: localSettings.previewImageByClick,
                identifier: UIIdentifiers.ReaderMoreSettings.previewImageByClickSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.previewImageByClickRow
            ) { [weak self] value in self?.updateLocalSettings { $0.previewImageByClick = value } },
            actionRow(
                title: L10n.Reader.tapZoneConfigTitle, identifier: UIIdentifiers.ReaderMoreSettings.tapZoneConfigRow
            ) { [weak self] in self?.onTapZoneConfig?() },
            toggleRow(
                title: L10n.Reader.disableReturnKeyTitle,
                isOn: ReaderMoreSettingsPreferenceBridge.disableReturnKeyEnabled(),
                identifier: UIIdentifiers.ReaderMoreSettings.disableReturnKeySwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.disableReturnKeyRow
            ) { [weak self] in self?.updateDisableReturnKey($0) },
            actionRow(
                title: L10n.Reader.customKeyPageTitle, identifier: UIIdentifiers.ReaderMoreSettings.customKeyPageRow
            ) { [weak self] in self?.openHardwareKeyConfigSheet() },
            toggleRow(
                title: L10n.Reader.expandTextMenuTitle, isOn: localSettings.expandTextMenu,
                identifier: UIIdentifiers.ReaderMoreSettings.expandTextMenuSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.expandTextMenuRow
            ) { [weak self] value in self?.updateLocalSettings { $0.expandTextMenu = value } },
            toggleRow(
                title: L10n.Reader.showTitleAdditionTitle, isOn: localSettings.showTitleAddition,
                identifier: UIIdentifiers.ReaderMoreSettings.showTitleAdditionSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.showTitleAdditionRow,
                isBottomBackground: false
            ) { [weak self] value in self?.updateLocalSettings { $0.showTitleAddition = value } },
            toggleRow(
                title: L10n.Reader.readBarStyleFollowPageTitle,
                isOn: state?.runtimeConfig.readBarStyleFollowPage ?? false,
                identifier: UIIdentifiers.ReaderMoreSettings.readBarStyleFollowPageSwitch,
                rowIdentifier: UIIdentifiers.ReaderMoreSettings.readBarStyleFollowPageRow,
                enabled: state != nil, isBottomBackground: false
            ) { [weak self] in self?.setReadBarStyleFollowPage(enabled: $0) },
        ]
        listView.update(items: rows)
    }

    private func actionRow(title: String, summary: String? = nil, identifier: String, action: @escaping () -> Void)
        -> ReaderPreferenceItem
    {
        ReaderPreferenceItem(id: identifier, title: title, summary: summary, accessory: .action, onActivate: action)
    }

    private func valueRow(title: String, value: String, identifier: String, action: @escaping () -> Void)
        -> ReaderPreferenceItem
    {
        ReaderPreferenceItem(id: identifier, title: title, accessory: .value(value), onActivate: action)
    }

    private func toggleRow(
        title: String, isOn: Bool, identifier: String, rowIdentifier: String, enabled: Bool = true,
        isBottomBackground: Bool = true,
        onChange: @escaping (Bool) -> Void
    ) -> ReaderPreferenceItem {
        ReaderPreferenceItem(
            id: rowIdentifier, title: title, accessory: .toggle(isOn), toggleIdentifier: identifier, isEnabled: enabled,
            isBottomBackground: isBottomBackground, onToggle: onChange)
    }

    private func openProgressBehaviorPicker() {
        guard presentedViewController == nil else { return }
        presentTextChoiceAlert(
            title: L10n.Reader.progressBehaviorTitle,
            selectedIndex: ReaderProgressBehavior.allCases.firstIndex(of: localSettings.progressBehavior) ?? 0,
            identifier: UIIdentifiers.ReaderMoreSettings.progressBehaviorRow + ".choice",
            choices: ReaderProgressBehavior.allCases.map { behavior in
                (
                    behavior.title,
                    { [weak self] in
                        self?.updateLocalSettings { $0.progressBehavior = behavior }
                    }
                )
            }
        )
    }

    private func openScreenOrientationPicker() {
        guard presentedViewController == nil else { return }
        presentTextChoiceAlert(
            title: L10n.Reader.screenOrientationTitle,
            selectedIndex: ReaderScreenOrientation.allCases.firstIndex(of: localSettings.screenOrientation) ?? 0,
            identifier: UIIdentifiers.ReaderMoreSettings.screenOrientationRow + ".choice",
            choices: ReaderScreenOrientation.allCases.map { orientation in
                (
                    orientation.title,
                    { [weak self] in
                        self?.updateLocalSettings { $0.screenOrientation = orientation }
                    }
                )
            }
        )
    }

    private func openScreenTimeoutPicker() {
        guard presentedViewController == nil else { return }
        presentTextChoiceAlert(
            title: L10n.Reader.screenTimeoutTitle,
            selectedIndex: ReaderScreenTimeout.allCases.firstIndex(of: localSettings.screenTimeout) ?? 0,
            identifier: UIIdentifiers.ReaderMoreSettings.screenTimeoutRow + ".choice",
            choices: ReaderScreenTimeout.allCases.map { timeout in
                (
                    ReaderScreenTimeoutMenuSupport.title(timeout),
                    { [weak self] in
                        self?.updateLocalSettings { $0.screenTimeout = timeout }
                    }
                )
            }
        )
    }

    private func openDoublePageHorizontalPicker() {
        guard presentedViewController == nil else { return }
        presentTextChoiceAlert(
            title: L10n.Reader.doublePageHorizontalTitle,
            selectedIndex: ReaderDoubleHorizontalPageMode.allCases.firstIndex(of: localSettings.doubleHorizontalPage)
                ?? 0,
            identifier: UIIdentifiers.ReaderMoreSettings.doublePageHorizontalRow + ".choice",
            choices: ReaderDoubleHorizontalPageMode.allCases.map { mode in
                (
                    AndroidReaderDoublePageHorizontalMenuSupport.title(mode),
                    { [weak self] in
                        self?.updateLocalSettings { $0.doubleHorizontalPage = mode }
                    }
                )
            }
        )
    }

    private func presentTextChoiceAlert(
        title: String, selectedIndex: Int, identifier: String, choices: [(String, () -> Void)]
    ) {
        let controller = ReaderPreferenceChoiceDialogViewController(
            title: title, items: choices.map(\.0), selectedIndex: selectedIndex, identifier: identifier
        ) { [weak self] index in
            guard let self, self.ownsSettings, choices.indices.contains(index)
            else { return }
            choices[index].1()
        }
        controller.canSelect = { [weak self] in self?.ownsSettings == true }
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        presentSettingsEditor(controller)
    }

    private func openPageTouchSlopSheet() {
        guard presentedViewController == nil else { return }
        let controller = AndroidReaderNumberPickerDialogViewController(
            titleText: L10n.Reader.pageTouchSlopDialogTitle,
            value: min(max(localSettings.pageTouchSlop, 0), 9999),
            range: 0...9999,
            valueTitle: { String($0) },
            completion: { [weak self] value in
                self?.updateLocalSettings {
                    $0.pageTouchSlop = value
                }
            }
        )
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        presentSettingsEditor(controller)
    }

    private func openHardwareKeyConfigSheet() {
        guard presentedViewController == nil else { return }
        let controller = AndroidReaderHardwareKeyConfigSheetViewController(
            binding: ReaderHardwarePagingPreference.customPageKeyBinding()
        ) { [weak self] binding in
            ReaderHardwarePagingPreference.setCustomPageKeyBinding(binding)
            self?.rebuildRows()
        }
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        presentSettingsEditor(controller)
    }

    private func updateAutoChangeSource(_ isEnabled: Bool) {
        guard autoChangeSourceEnabled != isEnabled else { return }
        autoChangeSourceEnabled = isEnabled
        ReaderMoreSettingsPreferenceBridge.setAutoChangeSourceEnabled(isEnabled)
        rebuildRows()
    }

    private func updateMouseWheelPage(_ isEnabled: Bool) {
        ReaderHardwarePagingPreference.setMouseWheelPageEnabled(isEnabled)
        rebuildRows()
    }

    private func updateKeyPage(_ isEnabled: Bool) {
        ReaderHardwarePagingPreference.setKeyPageEnabled(isEnabled)
        rebuildRows()
    }

    private func updateKeyPageOnReadAloud(_ isEnabled: Bool) {
        ReaderHardwarePagingPreference.setKeyPageOnReadAloudEnabled(isEnabled)
        rebuildRows()
    }

    private func updateKeyPageOnLongPress(_ isEnabled: Bool) {
        ReaderHardwarePagingPreference.setKeyPageOnLongPressEnabled(isEnabled)
        rebuildRows()
    }

    private func updateDisableReturnKey(_ isEnabled: Bool) {
        ReaderMoreSettingsPreferenceBridge.setDisableReturnKeyEnabled(isEnabled)
        onDisableReturnKeyChange?()
        rebuildRows()
    }

    private func updateLocalSettings(_ mutate: (inout ReaderLocalSettings) -> Void) {
        let previous = localSettings
        var updated = localSettings
        mutate(&updated)
        guard hasLocalSettingsChange(previous, updated) else { return }
        updated.persist()
        localSettings = updated
        rebuildRows()
        onLocalSettingsChange?(previous, updated)
    }

    private func updateReaderRuntimeConfig(_ mutate: (ReaderRuntimeConfig) -> ReaderRuntimeConfig) {
        guard let config = displayedRuntimeConfig else { return }
        pendingRuntimeConfig = mutate(config)
        runtimeWriteRevision += 1
        rebuildRows()
        guard runtimeWriteTask == nil else { return }
        runtimeWriteTask = Task { @MainActor [weak self] in
            defer { self?.runtimeWriteTask = nil }
            do {
                while let self, let snapshot = self.pendingRuntimeConfig {
                    let revision = self.runtimeWriteRevision
                    try Task.checkCancellation()
                    try await self.screen.setReaderRuntimeConfig(config: snapshot)
                    try Task.checkCancellation()
                    self.onReaderRuntimeConfigChange?(snapshot)
                    if revision == self.runtimeWriteRevision { break }
                }
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.pendingRuntimeConfig = nil
                self.rebuildRows()
                if self.viewIfLoaded?.window != nil { self.presentError(error) }
            }
        }
    }

    private func setReadBarStyleFollowPage(enabled: Bool) {
        runSettingTask { [weak self] in
            guard let self else { return }
            try await self.screen.setReadBarStyleFollowPage(enabled: enabled)
        }
    }

    private func hasLocalSettingsChange(_ lhs: ReaderLocalSettings, _ rhs: ReaderLocalSettings) -> Bool {
        return lhs.showBrightnessBar != rhs.showBrightnessBar
            || lhs.showTitleAddition != rhs.showTitleAddition
            || lhs.screenTimeout != rhs.screenTimeout
            || lhs.brightnessAuto != rhs.brightnessAuto
            || lhs.brightnessOnRight != rhs.brightnessOnRight
            || lhs.progressBehavior != rhs.progressBehavior
            || lhs.screenOrientation != rhs.screenOrientation
            || lhs.textSelectable != rhs.textSelectable
            || lhs.expandTextMenu != rhs.expandTextMenu
            || lhs.doubleHorizontalPage != rhs.doubleHorizontalPage
            || lhs.noAnimScrollPage != rhs.noAnimScrollPage
            || lhs.previewImageByClick != rhs.previewImageByClick
            || lhs.touchSensitivity != rhs.touchSensitivity
            || lhs.pageTouchSlop != rhs.pageTouchSlop
    }

    private static var pageTouchSlopSystemDefaultValue: Int {
        Int(ReaderLocalSettings.defaultPageTouchSlop.rounded())
    }

    private var pageTouchSlopSummary: String {
        L10n.Reader.pageTouchSlopSummary(Self.pageTouchSlopSystemDefaultValue)
    }

}

enum ReaderMoreSettingsPreferenceBridge {
    private static let disableReturnKeyKey = "disableReturnKey"
    private static let legacyDisableReturnKeyKey = "disable_return_key"
    private static let optimizeRenderKey = "optimizeRender"
    private static let iosOptimizeRenderKey = "optimize_render"

    static func autoChangeSourceEnabled() -> Bool {
        ReaderAutoChangeSourcePreference.isEnabled()
    }

    static func setAutoChangeSourceEnabled(_ isEnabled: Bool) {
        ReaderAutoChangeSourcePreference.setEnabled(isEnabled)
    }

    static func disableReturnKeyEnabled() -> Bool {
        bool(forKey: disableReturnKeyKey, fallbackKey: legacyDisableReturnKeyKey)
    }

    static func setDisableReturnKeyEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: disableReturnKeyKey)
        UserDefaults.standard.set(isEnabled, forKey: legacyDisableReturnKeyKey)
    }

    static func optimizeRenderEnabled() -> Bool {
        bool(forKey: optimizeRenderKey, fallbackKey: iosOptimizeRenderKey)
    }

    static func setOptimizeRenderEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: optimizeRenderKey)
        UserDefaults.standard.set(isEnabled, forKey: iosOptimizeRenderKey)
    }

    private static func bool(forKey key: String, fallbackKey: String) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool {
            return value
        }
        return UserDefaults.standard.object(forKey: fallbackKey) as? Bool ?? false
    }
}

extension ReaderRuntimeConfig {
    fileprivate func androidReaderMoreCopy(
        textFullJustify: Bool? = nil,
        textBottomJustify: Bool? = nil,
        hideStatusBar: Bool? = nil,
        hideNavigationBar: Bool? = nil,
        useZhLayout: Bool? = nil,
        readBodyToLh: Bool? = nil
    ) -> ReaderRuntimeConfig {
        ReaderRuntimeConfig(
            brightnessDay: brightnessDay,
            brightnessNight: brightnessNight,
            pageAnimation: pageAnimation,
            shareLayout: shareLayout,
            readStyleIndex: readStyleIndex,
            comicStyleIndex: comicStyleIndex,
            autoReadSpeed: autoReadSpeed,
            ttsFollowSystemRate: ttsFollowSystemRate,
            ttsSpeechRate: ttsSpeechRate,
            ttsTimerMinutes: ttsTimerMinutes,
            ttsVoiceIdentifier: ttsVoiceIdentifier,
            textFullJustify: textFullJustify ?? self.textFullJustify,
            textBottomJustify: textBottomJustify ?? self.textBottomJustify,
            hideStatusBar: hideStatusBar ?? self.hideStatusBar,
            hideNavigationBar: hideNavigationBar ?? self.hideNavigationBar,
            chineseMode: chineseMode,
            tapZoneActions: tapZoneActions,
            useZhLayout: useZhLayout ?? self.useZhLayout,
            readBodyToLh: readBodyToLh ?? self.readBodyToLh,
            isComic: isComic
        )
    }
}
