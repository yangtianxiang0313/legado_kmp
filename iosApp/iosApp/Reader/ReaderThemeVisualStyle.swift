import CoreText
import UIKit
import shared

enum ReaderThemeVisualStyle {
    static func tipFont(name: String?) -> UIFont {
        guard let name, !name.isEmpty else { return defaultTipFont }
        if let imported = ReaderFontStore.shared.font(for: name, size: 12) { return imported }
        if !name.hasPrefix("reader-font:"), let named = UIFont(name: name, size: 12) { return named }
        return defaultTipFont
    }

    private static var defaultTipFont: UIFont {
        ReaderAndroidDefaultFont.font(size: 12) ?? .systemFont(ofSize: 12)
    }

    static func variant(
        preferences: AppUiPreferences, userInterfaceStyle: UIUserInterfaceStyle
    ) -> ReaderVisualVariant {
        if preferences.themeMode == .eInk { return .eInk }
        if preferences.themeMode == .dark { return .night }
        if preferences.themeMode == .light { return .day }
        return userInterfaceStyle == .dark ? .night : .day
    }

    static func style(
        preferences: AppUiPreferences, userInterfaceStyle: UIUserInterfaceStyle
    ) -> ReaderStylePreferences {
        guard let preset = preferences.readerPreset else { return preferences.readerStyle }
        return preset.styleForVariant(
            variant: variant(preferences: preferences, userInterfaceStyle: userInterfaceStyle)
        ).withSharedLayoutFrom(shared: preferences.readerStyle)
    }
}

enum ReaderChromeNumberFont {
    private static let graphicsFont: CGFont? = {
        guard let url = Bundle.main.url(forResource: "ReaderAndroidNumber", withExtension: "ttf"),
            let provider = CGDataProvider(url: url as CFURL)
        else { return nil }
        return CGFont(provider)
    }()

    static let font: UIFont = {
        guard let graphicsFont else { return .systemFont(ofSize: 11) }
        // Keep the asset private instead of registering a Roboto name over an imported reader font.
        return CTFontCreateWithGraphicsFont(graphicsFont, 11, nil, nil) as UIFont
    }()

    private static let bounds = CTFontGetBoundingBox(font as CTFont)
    private static let displayScale = max(UIScreen.main.scale, 1)
    static let baselineOffset =
        ceil(
            (graphicsFont == nil ? font.ascender : bounds.maxY) * displayScale) / displayScale
    static let lineHeight =
        graphicsFont == nil
        ? ceil(font.lineHeight * displayScale) / displayScale
        : baselineOffset - floor(bounds.minY * displayScale) / displayScale
}
