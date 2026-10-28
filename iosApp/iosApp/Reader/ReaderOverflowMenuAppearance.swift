import UIKit

struct ReaderOverflowMenuAppearance {
    let background: UIColor
    let text: UIColor
    let disabledText: UIColor
    let checked: UIColor
    let highlight: UIColor
    let control: UIColor
    let disabledControl: UIColor
    let icon: UIColor

    // Toolbar PopupOverlay resolves AppCompat's popup surface, not bg_popup_menu.
    static let cornerRadius: CGFloat = 2

    init(isDark: Bool) {
        background = Self.rgb(isDark ? 0x212121 : 0xEEEEEE)
        text = Self.rgb(isDark ? 0xB7B7B7 : 0x383838)

        // Style.MenuItemText uses a scalar menu_color_default, not a disabled selector.
        disabledText = text

        // AppTheme.PopupOverlay, NOT AppTheme.AppBarOverlay.Dark (whose accent is grey_50).
        // values[-night]/styles.xml: grey_900 / grey_100; no theme preferences are read here.
        checked = Self.rgb(isDark ? 0xF5F5F5 : 0x212121)

        // AppCompat 1.7.1 ThemeOverlay: colorControlNormal -> textColorSecondary;
        // abc_tint_btn_checkable multiplies its default alpha by disabledAlpha (0.26/0.30).
        let controlAlpha: CGFloat = isDark ? 179 : 138
        let disabledAlpha: CGFloat = isDark ? 0.30 : 0.26
        control = UIColor(white: isDark ? 1 : 0, alpha: controlAlpha / 255)
        disabledControl = UIColor(
            white: isDark ? 1 : 0,
            alpha: (controlAlpha * disabledAlpha).rounded() / 255)

        // AppCompat ripple_material_light/dark, not an opacity sampled from a screenshot.
        highlight = UIColor(white: isDark ? 1 : 0, alpha: (isDark ? 51.0 : 31.0) / 255)

        // MenuExtensions.applyOpenTint uses primaryText, independently of checkbox tint.
        icon = UIColor(white: isDark ? 1 : 0, alpha: isDark ? 1 : 222.0 / 255)
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}
