import UIKit

/// Legado 5f5d314 TOC: ThemeStore chrome/decor plus independent day/night resources.
/// A snapshot, rebuilt by owners on trait and androidReplicaThemeDidChange updates.
struct ReaderTocPalette {
    let background: UIColor
    let titleBackground: UIColor
    let bottomBackground: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let toolbarText: UIColor
    let toolbarSecondaryText: UIColor
    let toolbarAccent: UIColor
    let bottomText: UIColor
    let accent: UIColor
    let divider: UIColor
    let volumeBackground: UIColor

    init(traits: UITraitCollection) {
        let isNight = ReaderPaletteColor.isNightResource(traits: traits)

        // activity_chapter_list / fragment_chapter_list are transparent. BaseActivity
        // initTheme() tints the decor with ThemeStore.backgroundColor, not R.color.background.
        background = ReaderPaletteColor.theme(
            "backgroundColor", traits: traits, fallback: isNight ? 0xFF21_2121 : 0xFFF5_F5F5)
        titleBackground = ReaderPaletteColor.theme(
            "primaryColor", traits: traits, fallback: isNight ? 0xFF54_6E7A : 0xFF79_5548)
        bottomBackground = ReaderPaletteColor.theme(
            "bottomBackground", traits: traits, fallback: isNight ? 0xFF30_3030 : 0xFFEE_EEEE)
        // ChapterListAdapter explicitly uses primaryText; icons use secondaryText resources.
        primaryText = Self.argb(isNight ? 0xFFFF_FFFF : 0xDE00_0000)
        secondaryText = Self.argb(isNight ? 0xB3FF_FFFF : 0x8A00_0000)
        // BaseActivity's AppBarOverlay follows actual PRIMARY luminance.
        toolbarText = ReaderPaletteColor.primaryText(on: titleBackground)
        let isLightToolbar = ReaderPaletteColor.isLight(titleBackground)
        // TabLayout's legacy selector uses the AppBarOverlay's secondary text resource.
        toolbarSecondaryText = Self.argb(isLightToolbar ? 0x8A00_0000 : 0xB3FF_FFFF)
        // AppTheme.AppBarOverlay.Light/Dark overrides colorAccent for SearchView controls.
        toolbarAccent = Self.argb(isLightToolbar ? 0xFF21_2121 : 0xFFFA_FAFA)
        // ChapterListFragment computes btc independently from the actual BOTTOM color.
        bottomText = ReaderPaletteColor.primaryText(on: bottomBackground)
        accent = ReaderPaletteColor.theme(
            "accentColor", traits: traits, fallback: isNight ? 0xFFD8_4315 : 0xFFE5_3935)
        // VerticalDivider -> ic_divider -> bg_divider_line, not R.color.divider.
        divider = Self.argb(isNight ? 0xFF36_3636 : 0x8FE0_E0E0)
        volumeBackground = Self.argb(isNight ? 0x634D_4D4D : 0x63AC_ACAC)
    }

    private static func argb(_ value: UInt32) -> UIColor {
        ReaderPaletteColor.argb(value)
    }
}
