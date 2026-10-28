import UIKit

/// The change-source XMLs use R.color.background, not the TOC activity's themed decor.
struct ChangeSourcePalette {
    let background: UIColor
    let titleBackground: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let toolbarText: UIColor
    let accent: UIColor
    let divider: UIColor
    let volumeBackground: UIColor
    let selectionBackground: UIColor

    init(traits: UITraitCollection) {
        let base = ReaderTocPalette(traits: traits)
        let isNight = ReaderPaletteColor.isNightResource(traits: traits)
        background = ReaderPaletteColor.argb(isNight ? 0xFF21_2121 : 0xFFFA_FAFA)
        titleBackground = base.titleBackground
        primaryText = base.primaryText
        secondaryText = base.secondaryText
        toolbarText = base.toolbarText
        accent = base.accent
        divider = base.divider
        volumeBackground = base.volumeBackground
        selectionBackground =
            isNight ? UIColor.white.withAlphaComponent(51 / 255) : UIColor.black.withAlphaComponent(31 / 255)
    }
}

/// UIKit's shadow equivalent of the dialogs' elevated toolbar and TOC close strip.
enum ChangeSourceElevation {
    static func apply(to view: UIView) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.2
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.layer.shadowRadius = 2
    }

    static func updatePath(for view: UIView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
        CATransaction.commit()
    }
}
