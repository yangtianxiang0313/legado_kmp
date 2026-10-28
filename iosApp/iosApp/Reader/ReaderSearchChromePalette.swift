import UIKit

enum ReaderSearchChromePalette {
    static let foreground = UIColor { traits in
        foreground(on: AndroidReplicaTheme.bottomBackground, traits: traits)
    }

    static let pressedBackground = UIColor { traits in
        pressed(AndroidReplicaTheme.bottomBackground, traits: traits)
    }

    static func foreground(on background: UIColor, traits: UITraitCollection) -> UIColor {
        let color = background.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return AndroidReplicaTheme.primaryText.resolvedColor(with: traits)
        }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        // SearchMenu/SearchContentActivity use ColorUtils.isColorLight, not the app's night flag.
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.5 ? UIColor(white: 0, alpha: 222.0 / 255) : .white
    }

    static func pressed(_ background: UIColor, traits: UITraitCollection) -> UIColor {
        let color = background.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
        // ColorUtils.darkenColor scales HSV value by 0.9; RGB scales equally, rounded to ARGB bytes.
        func darken(_ value: CGFloat) -> CGFloat { (value * 255 * 0.9).rounded() / 255 }
        return UIColor(red: darken(red), green: darken(green), blue: darken(blue), alpha: alpha)
    }
}
