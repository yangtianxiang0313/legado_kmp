import UIKit
import shared

final class ReaderAppearanceScreenAdapter {
    private let bindings = ScreenBindingController(owner: "ReaderAppearanceScreen")
    private var facade: SettingsFacade?
    private var latestPreferences: AppUiPreferences?
    private var latestRuntimeConfig: AppRuntimeConfig?

    var onStateChange: ((ReaderAppearanceState) -> Void)?

    var readerPresets: [ReaderPreset] {
        facade?.readerPresets ?? []
    }

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()
        latestPreferences = nil
        latestRuntimeConfig = nil

        switch SharedRuntime.settingsFacade() {
        case .success(let facade):
            self.facade = facade
            bindings.bind(
                facade.watchPreferences { [weak self] preferences in
                    DispatchQueue.main.async {
                        self?.latestPreferences = preferences
                        self?.emitStateIfReady()
                    }
                })
            bindings.bind(
                facade.watchRuntimeConfig { [weak self] runtimeConfig in
                    DispatchQueue.main.async {
                        self?.latestRuntimeConfig = runtimeConfig
                        self?.emitStateIfReady()
                    }
                })
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindings.cancelAll()
    }

    func bootstrapDefaultsIfNeeded() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.bootstrapDefaultsIfNeededAsync()
    }

    func setReaderPreset(name: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderPresetAsync(name: name)
    }

    func setReaderPreset(index: Int32) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReadStyleIndexAsync(index: index)
    }

    func setReaderFontSize(fontSizeSp: Float) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderFontSizeAsync(fontSizeSp: fontSizeSp)
    }

    func setReaderLineSpacing(multiplier: Float) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderLineSpacingAsync(multiplier: multiplier)
    }

    func setReaderHorizontalPadding(paddingDp: Float) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderHorizontalPaddingAsync(paddingDp: paddingDp)
    }

    func setReaderBackgroundMode(mode: ReaderBackgroundMode) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderBackgroundModeAsync(mode: mode)
    }

    func setReaderStyle(style: ReaderStylePreferences) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderLayoutAsync(style: style)
    }

    @MainActor
    func readSnapshot() async throws -> ReaderAppearanceState {
        guard let facade else { throw runtimeNotReadyError() }
        return try await ReaderAppearanceSnapshotRequest.read(facade: facade)
    }

    func setBrightnessDay(value: Int) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setBrightnessDayAsync(value: Int32(value))
    }

    func setBrightnessNight(value: Int) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setBrightnessNightAsync(value: Int32(value))
    }

    func setPageAnimation(value: Int) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setPageAnimationAsync(value: Int32(value))
    }

    func setReaderQuickOption(_ option: ReaderAppearanceQuickOption, value: Int32, context: ReaderAppearanceSelectionContext) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderQuickOptionAsync(
            option: option, value: value, expectedName: context.presetName,
            expectedIndex: context.presetIndex, expectedShareLayout: context.shareLayout)
    }

    func setShareLayout(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setShareLayoutAsync(enabled: enabled)
    }

    func setAutoReadSpeed(value: Int) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setAutoReadSpeedAsync(value: Int32(value))
    }

    func setTextFullJustify(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setTextFullJustifyAsync(enabled: enabled)
    }

    func setTextBottomJustify(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setTextBottomJustifyAsync(enabled: enabled)
    }

    func setHideStatusBar(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setHideStatusBarAsync(enabled: enabled)
    }

    func setHideNavigationBar(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setHideNavigationBarAsync(enabled: enabled)
    }

    func setReaderRuntimeConfig(config: ReaderRuntimeConfig) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReaderRuntimeConfigAsync(config: config)
    }

    func setReadBarStyleFollowPage(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReadBarStyleFollowPageAsync(enabled: enabled)
    }

    func setIgnoreAudioFocus(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setIgnoreAudioFocusAsync(enabled: enabled)
    }

    func setPauseReadAloudWhilePhoneCalls(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setPauseReadAloudWhilePhoneCallsAsync(enabled: enabled)
    }

    func setStreamReadAloudAudio(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setStreamReadAloudAudioAsync(enabled: enabled)
    }

    func setTtsEngine(engine: String?) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setTtsEngineAsync(engine: engine)
    }

    func setTapZoneActions(actions: ReaderTapZoneActions) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setTapZoneActionsAsync(actions: actions)
    }

    func renameReaderPreset(oldName: String, newName: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.renameReaderPresetAsync(oldName: oldName, newName: newName)
    }

    func deleteReaderPreset(name: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.deleteReaderPresetAsync(name: name)
    }

    func exportReaderPresetJson(name: String) -> String? {
        facade?.exportReaderPresetJson(name: name)
    }

    func importReaderPresetJson(jsonString: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.importReaderPresetJsonAsync(jsonString: jsonString)
    }

    func createReaderPreset() async throws -> ReaderPreset {
        guard let facade else { throw runtimeNotReadyError() }
        let sharesLayout = latestRuntimeConfig?.reader.shareLayout ?? false
        let sharedStyle = sharesLayout ? latestPreferences?.readerStyle : nil
        // ReadBookConfig.kt Config at 5f5d314; map indent and tip slots to shared's numeric representation.
        let payload: [String: Any] = [
            "name": "",
            "bgStr": "#EEEEEE",
            "bgStrNight": "#000000",
            "bgStrEInk": "#FFFFFF",
            "bgAlpha": 100,
            "bgType": 0,
            "bgTypeNight": 0,
            "bgTypeEInk": 0,
            "backgroundImagePath": NSNull(),
            "darkStatusIcon": true,
            "darkStatusIconNight": false,
            "darkStatusIconEInk": true,
            "textColor": "#3E3D3B",
            "textColorNight": "#ADADAD",
            "textColorEInk": "#000000",
            "pageAnimEInk": 4,
            "textFont": "",
            "textBold": 0,
            "textSize": 20,
            "letterSpacing": 0.1,
            "lineSpacingExtra": 12,
            "paragraphSpacing": 2,
            "paragraphIndent": 2,
            "underline": false,
            "titleMode": 0,
            "titleSize": 0,
            "titleTopSpacing": 0,
            "titleBottomSpacing": 0,
            "paddingTop": 6,
            "paddingBottom": 6,
            "paddingLeft": 16,
            "paddingRight": 16,
            "headerPaddingTop": 0,
            "headerPaddingBottom": 0,
            "headerPaddingLeft": 16,
            "headerPaddingRight": 16,
            "footerPaddingTop": 6,
            "footerPaddingBottom": 6,
            "footerPaddingLeft": 16,
            "footerPaddingRight": 16,
            "showHeaderLine": false,
            "showFooterLine": true,
            "tipHeaderLeft": 2,
            "tipHeaderMiddle": 0,
            "tipHeaderRight": 3,
            "tipFooterLeft": 1,
            "tipFooterMiddle": 0,
            "tipFooterRight": 6,
            "tipColorHex": NSNull(),
            "tipDividerColorHex": NSNull(),
            "headerMode": 0,
            "footerMode": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        let created = try ReaderPresetTransferCodec().decode(jsonString: json)
        try await SharedAsync.void { facade.addReaderPreset(preset: created, completionHandler: $0) }
        guard let preset = readerPresets.last else {
            throw NSError(
                domain: "io.legado.kmp.ios.readerStyle",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "未能创建配色方案"]
            )
        }
        // ReaderPreset has no regular pageAnim field; apply Config.pageAnim = 0 through runtime.
        if let sharedStyle {
            let current = try await readSnapshot()
            try await facade.setReaderLayoutAsync(style: current.preferences.readerStyle.withSharedLayoutFrom(shared: sharedStyle))
        } else if !sharesLayout {
            try await facade.setPageAnimationAsync(value: 0)
        }
        return preset
    }

    private func emitStateIfReady() {
        guard let preferences = latestPreferences, let runtimeConfig = latestRuntimeConfig else { return }
        onStateChange?(ReaderAppearanceState(preferences: preferences, runtimeConfig: runtimeConfig))
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.ReaderAppearance.unavailable]
        )
    }
}

struct ReaderAppearanceState {
    let preferences: AppUiPreferences
    let runtimeConfig: AppRuntimeConfig
}

enum ReaderPageAnimationOption: Int, CaseIterable {
    case cover = 0
    case slide = 1
    case simulation = 2
    case scroll = 3
    case none = 4

    var title: String {
        switch self {
        case .cover:
            return L10n.ReaderAppearance.pageAnimationCover
        case .slide:
            return L10n.ReaderAppearance.pageAnimationSlide
        case .simulation:
            return L10n.ReaderAppearance.pageAnimationSimulation
        case .scroll:
            return L10n.ReaderAppearance.pageAnimationScroll
        case .none:
            return L10n.ReaderAppearance.pageAnimationNone
        }
    }
}
