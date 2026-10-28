import UIKit

/// Android ReadMenu colors at legado 5f5d314, including persisted global theme colors.
/// Pass the reader view's traits, which include its explicit day/night override.
/// This is a snapshot; the owner must reapply it after androidReplicaThemeDidChange.
struct ReaderMenuPalette {
    let titleBackground: UIColor
    let bottomBackground: UIColor
    let floatingBackground: UIColor
    let floatingPressedBackground: UIColor
    let edgeBorder: UIColor?
    let titleText: UIColor
    let titleSecondaryText: UIColor
    let bodyText: UIColor
    let accent: UIColor
    let sourceText: UIColor
    let brightnessBackground: UIColor
    /// ReadMenu.upBrightnessState(): inactive automatic-brightness icon.
    let disabled: UIColor
    /// TintHelper.setTint(SeekBar): disabled thumb and progress, not the auto icon.
    let sliderDisabled: UIColor

    init(readerTheme: ReaderThemeController, traits: UITraitCollection) {
        // ReaderThemeController has no day/night flag. Do not infer it from a
        // custom page color or darkStatusIcon; the reader overrides its traits.
        let isNight = ReaderPaletteColor.isNightResource(traits: traits)

        let primary = ReaderPaletteColor.theme(
            "primaryColor", traits: traits, fallback: isNight ? 0xFF54_6E7A : 0xFF79_5548)
        let bottom = ReaderPaletteColor.theme(
            "bottomBackground", traits: traits, fallback: isNight ? 0xFF30_3030 : 0xFFEE_EEEE)
        let accentColor = ReaderPaletteColor.theme(
            "accentColor", traits: traits, fallback: isNight ? 0xFFD8_4315 : 0xFFE5_3935)

        // ReadMenu.immersiveMenu: follow only a solid page, including custom text.
        if readerTheme.canReadBarStyleFollowPage {
            let pageColor = readerTheme.backgroundColor.resolvedColor(with: traits)
            let pageText = readerTheme.textColor.resolvedColor(with: traits)
            // initView applies the white E-Ink border drawables AFTER immersive colors.
            // Floating controls and brightness still retain the immersive bgColor.
            titleBackground = ReaderPaletteColor.isEInk ? .white : pageColor
            bottomBackground = ReaderPaletteColor.isEInk ? .white : pageColor
            floatingBackground = pageColor
            titleText = pageText
            bodyText = pageText
            // initView(): withAlpha(lightenColor(textColor), 0.75f), truncated to 191.
            titleSecondaryText = Self.shiftValue(pageText, by: 1.1)
                .withAlphaComponent(191.0 / 255.0)
        } else {
            titleBackground = ReaderPaletteColor.isEInk ? .white : primary
            bottomBackground = ReaderPaletteColor.isEInk ? .white : bottom
            floatingBackground = bottom
            let toolbarText = Self.primaryText(on: primary)
            titleText = toolbarText
            // initView(reset = true) uses the same text for chapter name and URL.
            titleSecondaryText = toolbarText
            bodyText = Self.primaryText(on: bottom)
        }

        // ReadMenu.bottomBackgroundList and the E-Ink 1dp layer-list borders.
        floatingPressedBackground = Self.shiftValue(floatingBackground, by: 0.9)
        edgeBorder = ReaderPaletteColor.isEInk ? Self.argb(0x6666_6666) : nil

        // ThemeSeekBar/VerticalSeekBar.applyTint(): accent colors thumb and progress.
        accent = accentColor
        // AccentBgTextView: accent background with black/white contrast text.
        sourceText = Self.argb(Self.isLight(accentColor) ? 0xFF00_0000 : 0xFFFF_FFFF)

        // ReadMenu.initView(): adjustAlpha(bgColor, 0.5f).
        let brightnessAlpha = (floatingBackground.cgColor.alpha * 255 * 0.5).rounded() / 255
        brightnessBackground = floatingBackground.withAlphaComponent(brightnessAlpha)

        // MaterialValueHelper.buttonDisabledColor checks PRIMARY luminance, not
        // isNightTheme; preserve its intentionally inverse disabled-color choice.
        disabled = Self.argb(Self.isLight(primary) ? 0x4DFF_FFFF : 0x6100_0000)
        // values/colors.xml: ate_control_disabled_dark / ate_control_disabled_light.
        sliderDisabled = Self.argb(isNight ? 0x4DFF_FFFF : 0x4300_0000)
    }

    private static func argb(_ value: UInt32) -> UIColor { ReaderPaletteColor.argb(value) }

    private static func primaryText(on background: UIColor) -> UIColor {
        ReaderPaletteColor.primaryText(on: background)
    }

    private static func isLight(_ color: UIColor) -> Bool { ReaderPaletteColor.isLight(color) }

    private static func shiftValue(_ color: UIColor, by factor: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var value: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha) else {
            return color
        }
        // ColorUtils.shiftColor(): change HSV value, preserving hue/saturation/alpha.
        return UIColor(
            hue: hue, saturation: saturation, brightness: min(value * factor, 1), alpha: alpha)
    }
}

/// Shared Android color math. Luminance chooses contrast, NEVER the day/night channel.
enum ReaderPaletteColor {
    static var isEInk: Bool {
        // Match AndroidReplicaThemePalette's persisted mode, not reader/page luminance.
        UserDefaults.standard.string(forKey: "theme_mode") == "E_INK"
    }

    static func isNightResource(traits: UITraitCollection) -> Bool {
        // AppConfig.isNightTheme is explicitly false in E-Ink mode.
        !isEInk && traits.userInterfaceStyle == .dark
    }

    static func theme(_ field: String, traits: UITraitCollection, fallback: UInt32) -> UIColor {
        // Defaults are defensive only; the shared provider owns persisted colors and E-Ink.
        AndroidReplicaThemePalette.shared.color(for: field, traits: traits, followsTraits: true)
            ?? argb(fallback)
    }

    static func argb(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: CGFloat((value >> 24) & 0xFF) / 255
        )
    }

    static func primaryText(on background: UIColor) -> UIColor {
        // MaterialValueHelper.getPrimaryTextColor: md_light/dark_primary_text.
        argb(isLight(background) ? 0xDE00_0000 : 0xFFFF_FFFF)
    }

    static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return true
        }
        // ColorUtils.isColorLight(): AndroidX sRGB relative luminance >= 0.5.
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045
                ? channel / 12.92
                : CGFloat(pow(Double((channel + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) >= 0.5
    }
}
