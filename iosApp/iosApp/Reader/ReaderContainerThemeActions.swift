import UIKit
import shared

enum ReaderProgressBehavior: String, CaseIterable {
    case page
    case chapter

    var title: String {
        switch self {
        case .page:
            return L10n.Reader.progressBehaviorPage
        case .chapter:
            return L10n.Reader.progressBehaviorChapter
        }
    }
}

enum ReaderScreenOrientation: String, CaseIterable {
    case system = "0"
    case portrait = "1"
    case landscape = "2"
    case auto = "3"
    case reversePortrait = "4"

    var title: String {
        switch self {
        case .system:
            return L10n.Reader.screenOrientationSystem
        case .portrait:
            return L10n.Reader.screenOrientationPortrait
        case .landscape:
            return L10n.Reader.screenOrientationLandscape
        case .auto:
            return L10n.Reader.screenOrientationAuto
        case .reversePortrait:
            return L10n.Reader.screenOrientationReversePortrait
        }
    }

    var interfaceOrientations: UIInterfaceOrientationMask {
        switch self {
        case .system, .auto:
            return .allButUpsideDown
        case .portrait:
            return .portrait
        case .landscape:
            return .landscape
        case .reversePortrait:
            return .portraitUpsideDown
        }
    }

    var preferredInterfaceOrientation: UIInterfaceOrientation {
        switch self {
        case .landscape:
            return .landscapeRight
        case .reversePortrait:
            return .portraitUpsideDown
        case .system, .portrait, .auto:
            return .portrait
        }
    }

    var allowsAutorotation: Bool {
        switch self {
        case .system, .auto:
            return true
        case .portrait, .landscape, .reversePortrait:
            return false
        }
    }
}

enum ReaderTouchSensitivity: String, CaseIterable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low:
            return L10n.Reader.pageTouchSensitivityLow
        case .medium:
            return L10n.Reader.pageTouchSensitivityMedium
        case .high:
            return L10n.Reader.pageTouchSensitivityHigh
        }
    }

    var tapAllowableMovement: CGFloat {
        switch self {
        case .low:
            return 6
        case .medium:
            return 14
        case .high:
            return 24
        }
    }
}

enum ReaderScreenTimeout: String, CaseIterable {
    case system = "0"
    case oneMinute = "60"
    case fiveMinutes = "300"
    case tenMinutes = "600"
    case always = "-1"

    var seconds: Int? {
        switch self {
        case .system:
            return nil
        case .oneMinute, .fiveMinutes, .tenMinutes:
            return Int(rawValue)
        case .always:
            return nil
        }
    }

    var disablesSystemAutoLock: Bool {
        self == .always
    }
}

enum ReaderDoubleHorizontalPageMode: Int, CaseIterable {
    case singlePage = 0
    case doublePage = 1
    case landscape = 2
    case tabletOrLandscape = 3

    static let defaultMode: ReaderDoubleHorizontalPageMode = .singlePage

    var isEnabledForLegacyDualPageMode: Bool {
        self != .singlePage
    }

    static func fromLegacyDualPageMode(_ enabled: Bool) -> ReaderDoubleHorizontalPageMode {
        enabled ? .doublePage : .singlePage
    }

    static func fromStoredValue(_ value: Any?) -> ReaderDoubleHorizontalPageMode {
        guard let value else { return defaultMode }
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return fromLegacyDualPageMode(number.boolValue)
            }
            return ReaderDoubleHorizontalPageMode(rawValue: number.intValue) ?? defaultMode
        }
        if let rawValue = value as? String {
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let intValue = Int(normalized) {
                return ReaderDoubleHorizontalPageMode(rawValue: intValue) ?? defaultMode
            }
            switch normalized {
            case "true", "yes", "on":
                return fromLegacyDualPageMode(true)
            case "false", "no", "off":
                return fromLegacyDualPageMode(false)
            default:
                return defaultMode
            }
        }
        if let enabled = value as? Bool {
            return fromLegacyDualPageMode(enabled)
        }
        return defaultMode
    }

    func shouldActivate(in bounds: CGRect, pageAnimation: Int, userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool {
        guard bounds.width > 1, bounds.height > 1 else { return false }
        switch self {
        case .singlePage:
            return false
        case .doublePage:
            return true
        case .landscape:
            guard pageAnimation != 3 else { return false }
            return bounds.width > bounds.height
        case .tabletOrLandscape:
            guard pageAnimation != 3 else { return false }
            return bounds.width > bounds.height || userInterfaceIdiom == .pad
        }
    }
}

struct ReaderLocalSettings {
    var showBrightnessBar: Bool = true
    var showTitleAddition: Bool = true
    var screenTimeout: ReaderScreenTimeout = .system
    var brightnessAuto: Bool = true
    var brightnessOnRight: Bool = false
    var progressBehavior: ReaderProgressBehavior = .page
    var screenOrientation: ReaderScreenOrientation = .system
    var textSelectable: Bool = true
    var expandTextMenu: Bool = false
    var doubleHorizontalPage: ReaderDoubleHorizontalPageMode = .defaultMode
    var paddingDisplayCutouts: Bool = false
    var noAnimScrollPage: Bool = false
    var previewImageByClick: Bool = false
    var touchSensitivity: ReaderTouchSensitivity = .medium
    var pageTouchSlop: Int = 0

    private static let showBrightnessBarKey = "reader.local.showBrightnessBar"
    private static let showTitleAdditionKey = "reader.local.showTitleAddition"
    private static let keepLightKey = "keep_light"
    private static let keepScreenAwakeKey = "reader.local.keepScreenAwake"
    private static let brightnessAutoKey = "reader.local.brightnessAuto"
    private static let brightnessOnRightKey = "reader.local.brightnessOnRight"
    private static let progressBehaviorKey = "progressBarBehavior"
    private static let sharedProgressBehaviorKey = "progress_bar_behavior"
    private static let legacyProgressBehaviorKey = "reader.local.progressBehavior"
    private static let screenOrientationKey = "screenOrientation"
    private static let sharedScreenOrientationKey = "screen_orientation"
    private static let legacyScreenOrientationKey = "reader.local.screenOrientation"
    private static let textSelectableKey = "selectText"
    private static let legacyTextSelectableKey = "reader.local.textSelectable"
    private static let expandTextMenuKey = "reader.local.expandTextMenu"
    private static let doubleHorizontalPageKey = "doubleHorizontalPage"
    private static let legacyDoubleHorizontalPageKey = "reader.local.doubleHorizontalPage"
    private static let sharedDoubleHorizontalPageKey = "double_page_horizontal"
    private static let dualPageModeKey = "reader.local.dualPageMode"
    private static let paddingDisplayCutoutsKey = "padding_display_cutouts"
    private static let legacyPaddingDisplayCutoutsKey = "paddingDisplayCutouts"
    private static let noAnimScrollPageKey = "no_anim_scroll_page"
    private static let previewImageByClickKey = "previewImageByClick"
    private static let legacyPreviewImageByClickKey = "preview_image_by_click"
    private static let touchSensitivityKey = "reader.local.touchSensitivity"
    private static let pageTouchSlopKey = "pageTouchSlop"
    private static let sharedPageTouchSlopKey = "page_touch_slop"
    private static let legacyPageTouchSlopKey = "reader.local.pageTouchSlop"

    static func load() -> ReaderLocalSettings {
        let defaults = UserDefaults.standard
        return ReaderLocalSettings(
            showBrightnessBar: defaults.object(forKey: showBrightnessBarKey) as? Bool ?? true,
            showTitleAddition: defaults.object(forKey: showTitleAdditionKey) as? Bool ?? true,
            screenTimeout: loadScreenTimeout(defaults: defaults),
            brightnessAuto: defaults.object(forKey: brightnessAutoKey) as? Bool ?? true,
            brightnessOnRight: defaults.object(forKey: brightnessOnRightKey) as? Bool ?? false,
            progressBehavior: ReaderProgressBehavior(
                rawValue: loadString(
                    defaults: defaults,
                    keys: [progressBehaviorKey, sharedProgressBehaviorKey, legacyProgressBehaviorKey],
                    defaultValue: ReaderProgressBehavior.page.rawValue
                )
            ) ?? .page,
            screenOrientation: ReaderScreenOrientation(
                rawValue: loadString(
                    defaults: defaults,
                    keys: [screenOrientationKey, sharedScreenOrientationKey, legacyScreenOrientationKey],
                    defaultValue: ReaderScreenOrientation.system.rawValue
                )
            ) ?? .system,
            textSelectable: loadBool(defaults: defaults, key: textSelectableKey, fallbackKey: legacyTextSelectableKey, defaultValue: true),
            expandTextMenu: defaults.object(forKey: expandTextMenuKey) as? Bool ?? false,
            doubleHorizontalPage: loadDoubleHorizontalPage(defaults: defaults),
            paddingDisplayCutouts: loadPaddingDisplayCutouts(defaults: defaults),
            noAnimScrollPage: defaults.object(forKey: noAnimScrollPageKey) as? Bool ?? false,
            previewImageByClick: loadBool(defaults: defaults, key: previewImageByClickKey, fallbackKey: legacyPreviewImageByClickKey, defaultValue: false),
            touchSensitivity: ReaderTouchSensitivity(
                rawValue: defaults.string(forKey: touchSensitivityKey) ?? ReaderTouchSensitivity.medium.rawValue
            ) ?? .medium,
            pageTouchSlop: loadPageTouchSlop(defaults: defaults)
        )
    }

    private static func loadBool(defaults: UserDefaults, key: String, fallbackKey: String, defaultValue: Bool) -> Bool {
        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }
        if let value = defaults.object(forKey: fallbackKey) as? Bool {
            return value
        }
        return defaultValue
    }

    private static func loadString(defaults: UserDefaults, keys: [String], defaultValue: String) -> String {
        for key in keys {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                return value
            }
        }
        return defaultValue
    }

    private static func loadScreenTimeout(defaults: UserDefaults) -> ReaderScreenTimeout {
        for key in [keepLightKey, keepScreenAwakeKey] {
            let storedValue = defaults.object(forKey: key)
            if let rawValue = storedValue as? String,
                let timeout = ReaderScreenTimeout(rawValue: rawValue)
            {
                return timeout
            }
            if let number = storedValue as? NSNumber {
                return number.boolValue ? .always : .system
            }
        }
        return .system
    }

    private static func loadDoubleHorizontalPage(defaults: UserDefaults) -> ReaderDoubleHorizontalPageMode {
        if defaults.object(forKey: doubleHorizontalPageKey) != nil {
            return ReaderDoubleHorizontalPageMode.fromStoredValue(defaults.object(forKey: doubleHorizontalPageKey))
        }
        if defaults.object(forKey: sharedDoubleHorizontalPageKey) != nil {
            return ReaderDoubleHorizontalPageMode.fromStoredValue(defaults.object(forKey: sharedDoubleHorizontalPageKey))
        }
        if defaults.object(forKey: legacyDoubleHorizontalPageKey) != nil {
            return ReaderDoubleHorizontalPageMode.fromStoredValue(defaults.object(forKey: legacyDoubleHorizontalPageKey))
        }
        return ReaderDoubleHorizontalPageMode.fromStoredValue(defaults.object(forKey: dualPageModeKey))
    }

    private static func loadPaddingDisplayCutouts(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: paddingDisplayCutoutsKey) != nil {
            return defaults.bool(forKey: paddingDisplayCutoutsKey)
        }
        if defaults.object(forKey: legacyPaddingDisplayCutoutsKey) != nil {
            return defaults.bool(forKey: legacyPaddingDisplayCutoutsKey)
        }
        return false
    }

    private static func loadPageTouchSlop(defaults: UserDefaults) -> Int {
        for key in [pageTouchSlopKey, sharedPageTouchSlopKey, legacyPageTouchSlopKey] where defaults.object(forKey: key) != nil {
            return max(0, defaults.integer(forKey: key))
        }
        return 0
    }

    static let defaultPageTouchSlop: CGFloat = 18

    var dualPageMode: Bool {
        get {
            doubleHorizontalPage.isEnabledForLegacyDualPageMode
        }
        set {
            doubleHorizontalPage = ReaderDoubleHorizontalPageMode.fromLegacyDualPageMode(newValue)
        }
    }

    var keepScreenAwake: Bool {
        get {
            screenTimeout.disablesSystemAutoLock
        }
        set {
            screenTimeout = newValue ? .always : .system
        }
    }

    var effectivePageTouchSlop: CGFloat {
        guard pageTouchSlop > 0 else {
            return Self.defaultPageTouchSlop
        }
        return CGFloat(min(pageTouchSlop, 9999))
    }

    fileprivate static func persistBrightnessAuto(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: brightnessAutoKey)
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(showBrightnessBar, forKey: Self.showBrightnessBarKey)
        defaults.set(showTitleAddition, forKey: Self.showTitleAdditionKey)
        defaults.set(screenTimeout.rawValue, forKey: Self.keepLightKey)
        defaults.set(screenTimeout.rawValue, forKey: Self.keepScreenAwakeKey)
        Self.persistBrightnessAuto(brightnessAuto)
        defaults.set(brightnessOnRight, forKey: Self.brightnessOnRightKey)
        defaults.set(progressBehavior.rawValue, forKey: Self.progressBehaviorKey)
        defaults.set(progressBehavior.rawValue, forKey: Self.sharedProgressBehaviorKey)
        defaults.set(progressBehavior.rawValue, forKey: Self.legacyProgressBehaviorKey)
        defaults.set(screenOrientation.rawValue, forKey: Self.screenOrientationKey)
        defaults.set(screenOrientation.rawValue, forKey: Self.sharedScreenOrientationKey)
        defaults.set(screenOrientation.rawValue, forKey: Self.legacyScreenOrientationKey)
        defaults.set(textSelectable, forKey: Self.textSelectableKey)
        defaults.set(textSelectable, forKey: Self.legacyTextSelectableKey)
        defaults.set(expandTextMenu, forKey: Self.expandTextMenuKey)
        defaults.set(String(doubleHorizontalPage.rawValue), forKey: Self.doubleHorizontalPageKey)
        defaults.set(String(doubleHorizontalPage.rawValue), forKey: Self.legacyDoubleHorizontalPageKey)
        defaults.set(String(doubleHorizontalPage.rawValue), forKey: Self.sharedDoubleHorizontalPageKey)
        defaults.set(dualPageMode, forKey: Self.dualPageModeKey)
        defaults.set(paddingDisplayCutouts, forKey: Self.paddingDisplayCutoutsKey)
        defaults.set(paddingDisplayCutouts, forKey: Self.legacyPaddingDisplayCutoutsKey)
        defaults.set(noAnimScrollPage, forKey: Self.noAnimScrollPageKey)
        defaults.set(previewImageByClick, forKey: Self.previewImageByClickKey)
        defaults.set(previewImageByClick, forKey: Self.legacyPreviewImageByClickKey)
        defaults.set(touchSensitivity.rawValue, forKey: Self.touchSensitivityKey)
        defaults.set(max(0, pageTouchSlop), forKey: Self.pageTouchSlopKey)
        defaults.set(max(0, pageTouchSlop), forKey: Self.sharedPageTouchSlopKey)
        defaults.set(max(0, pageTouchSlop), forKey: Self.legacyPageTouchSlopKey)
    }
}

extension ReaderContainerViewController {
    func toggleNightTheme() {
        let currentMode = preferences?.themeMode ?? ThemeMode.system
        let nextMode: ThemeMode = isNightTheme(currentMode) ? .light : .dark
        applyThemeMode(nextMode)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.setThemeMode(nextMode)
                await MainActor.run {
                    self.showToast(nextMode == ThemeMode.dark ? L10n.Reader.menuNightTheme : L10n.Reader.menuDayTheme)
                }
            } catch {
                await MainActor.run {
                    if let mode = self.preferences?.themeMode {
                        self.applyThemeMode(mode)
                    }
                    self.showToast(error.userFacingMessage)
                }
            }
        }
    }

    func applyThemeMode(_ mode: ThemeMode, refresh: Bool = true) {
        let active = isNightTheme(mode)
        switch mode {
        case ThemeMode.dark:
            view.overrideUserInterfaceStyle = .dark
        case ThemeMode.light:
            view.overrideUserInterfaceStyle = .light
        default:
            view.overrideUserInterfaceStyle = .unspecified
        }
        if let preferences {
            themeController.apply(preferences: preferences, userInterfaceStyle: active ? .dark : .light)
        }
        readMenu.setNightThemeActive(active)
        applyReaderBrightnessIfNeeded()
        guard refresh else { return }
        applyTheme()
        repaginate(restoreLocation: currentCharacterOffset())
        setNeedsStatusBarAppearanceUpdate()
    }

    func beginReaderBrightnessControlIfNeeded() {
        readerBrightnessAutoPreference = ReaderLocalSettings.load().brightnessAuto
        if originalScreenBrightness == nil {
            originalScreenBrightness = UIScreen.main.brightness
        }
        applyReaderBrightnessIfNeeded()
    }

    func restoreSystemBrightnessIfNeeded() {
        guard let originalScreenBrightness else { return }
        UIScreen.main.brightness = originalScreenBrightness
        self.originalScreenBrightness = nil
    }

    func applyReaderBrightnessIfNeeded(localSettings: ReaderLocalSettings = ReaderLocalSettings.load()) {
        readerBrightnessAutoPreference = localSettings.brightnessAuto
        guard localSettings.brightnessAuto == false else {
            restoreSystemBrightnessIfNeeded()
            readMenu.setBrightnessValue(Float(UIScreen.main.brightness))
            return
        }
        // Lifecycle/configuration callbacks wait silently, including after the reader has exited.
        guard originalScreenBrightness != nil, let readerConfig = runtimeConfig?.reader else { return }
        let value = activeReaderBrightnessValue(from: readerConfig)
        UIScreen.main.brightness = CGFloat(value) / 100
        readMenu.setBrightnessValue(Float(value) / 100)
    }

    func handleReaderBrightnessSlider(_ value: Float) {
        guard prepareReaderManualBrightnessChange() else { return }
        if originalScreenBrightness == nil {
            originalScreenBrightness = UIScreen.main.brightness
        }
        let brightness = max(1, min(100, Int((value * 100).rounded())))
        UIScreen.main.brightness = CGFloat(brightness) / 100
        readMenu.setBrightnessValue(Float(brightness) / 100)
        saveReaderBrightness(value: brightness)
    }

    func handleReaderBrightnessAuto(isAuto: Bool, sliderValue: Float) {
        if isAuto {
            readerBrightnessAutoPreference = true
            restoreSystemBrightnessIfNeeded()
            readMenu.setBrightnessValue(Float(UIScreen.main.brightness))
        } else {
            handleReaderBrightnessSlider(sliderValue)
        }
    }

    private func prepareReaderManualBrightnessChange() -> Bool {
        guard runtimeConfig?.reader != nil, preferences != nil else {
            // The menu persists its auto toggle before invoking the brightness callbacks.
            ReaderLocalSettings.persistBrightnessAuto(readerBrightnessAutoPreference)
            readMenu.reloadLocalSettings()
            readMenu.setBrightnessValue(Float(UIScreen.main.brightness))
            showToast("阅读亮度配置尚未加载，稍后再试")
            return false
        }
        readerBrightnessAutoPreference = false
        return true
    }

    private func saveReaderBrightness(value: Int) {
        let isNight = isNightTheme(preferences?.themeMode ?? ThemeMode.system)
        pendingReaderBrightnessValue = value
        pendingReaderBrightnessIsNight = isNight
        readerBrightnessSaveTask?.cancel()
        readerBrightnessSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                guard let self, Task.isCancelled == false else { return }
                try await self.screen.setReaderBrightness(value: value, isNightTheme: isNight)
                await MainActor.run { [weak self] in
                    guard self?.pendingReaderBrightnessValue == value,
                        self?.pendingReaderBrightnessIsNight == isNight
                    else { return }
                    self?.pendingReaderBrightnessValue = nil
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in self?.showToast(error.userFacingMessage) }
            }
        }
    }

    func flushPendingReaderBrightness() {
        guard let value = pendingReaderBrightnessValue else { return }
        let isNight = pendingReaderBrightnessIsNight
        pendingReaderBrightnessValue = nil
        readerBrightnessSaveTask?.cancel()
        readerBrightnessSaveTask = nil
        Task { [screen] in
            try? await screen.setReaderBrightness(value: value, isNightTheme: isNight)
        }
    }

    private func activeReaderBrightnessValue(from readerConfig: ReaderRuntimeConfig) -> Int {
        let isNight = isNightTheme(preferences?.themeMode ?? ThemeMode.system)
        let value = isNight ? readerConfig.brightnessNight : readerConfig.brightnessDay
        return max(1, min(100, Int(value)))
    }

    func isNightTheme(_ mode: ThemeMode) -> Bool {
        switch mode {
        case ThemeMode.dark:
            return true
        case ThemeMode.light:
            return false
        default:
            return traitCollection.userInterfaceStyle == .dark
        }
    }
}
