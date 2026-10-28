import UIKit
import shared

struct ReaderThemeController {
    var font: UIFont = .systemFont(ofSize: 20)
    var titleFont: UIFont = .boldSystemFont(ofSize: 20)
    var tipFont: UIFont = .systemFont(ofSize: 12)
    var chromeDisplayScale: CGFloat = 1
    var bodyStrokeWidth: CGFloat = 0
    var titleStrokeWidth: CGFloat = 0
    var textColor: UIColor = .init(hex: "#3E3D3B") ?? .label
    var backgroundColor: UIColor = .init(hex: "#EEEEEE") ?? AndroidReplicaTheme.background
    var tipColor: UIColor = .init(hex: "#3E3D3B") ?? .label
    var tipDividerColor: UIColor = UIColor(hex: "#66666666") ?? .separator
    var selectionColor: UIColor = UIColor(red: 133 / 255, green: 133 / 255, blue: 133 / 255, alpha: 99 / 255)
    var lineSpacing: CGFloat = 5
    var bodyLineHeight: CGFloat = 29
    var titleLineHeight: CGFloat = 29
    var letterSpacing: CGFloat = 0.1
    var paragraphSpacing: CGFloat = 5.8
    var headingParagraphSpacing: CGFloat = 5.8
    var paragraphIndentCount: Int = 2
    var underline: Bool = false
    var contentInsets: UIEdgeInsets = .init(top: 6, left: 16, bottom: 6, right: 16)
    var headerInsets: UIEdgeInsets = .init(top: 0, left: 16, bottom: 0, right: 16)
    var footerInsets: UIEdgeInsets = .init(top: 6, left: 16, bottom: 6, right: 16)
    var textAlignment: NSTextAlignment = .justified
    var prefersBottomAlignedContent = true
    var titleMode: Int = 0
    var titleTopSpacing: CGFloat = 0
    var titleBottomSpacing: CGFloat = 0
    var showHeaderLine = false
    var showFooterLine = true
    var tipHeaderLeft = 2
    var tipHeaderMiddle = 0
    var tipHeaderRight = 3
    var tipFooterLeft = 1
    var tipFooterMiddle = 0
    var tipFooterRight = 6
    var headerMode = 0
    var footerMode = 0
    var backgroundAlpha: CGFloat = 1
    var backgroundImagePath: String?
    var visibleBackgroundColor: UIColor {
        guard backgroundImagePath?.isEmpty != false else { return backgroundColor }
        return backgroundColor.readerBlended(over: .systemBackground, alpha: backgroundAlpha)
    }
    var darkStatusIcon = true
    var chineseMode = 0
    var useZhLayout = false
    // Retained Android display-area preference, never a typography switch.
    var readBodyToLh = true
    var hideStatusBar = false
    var hideNavigationBar = false
    var readBarStyleFollowPage = false
    var rootInsets: UIEdgeInsets = .zero
    var statusBarSpacerHeight: CGFloat = 0
    var navigationBarSpacerHeight: CGFloat = 0
    var canReadBarStyleFollowPage: Bool {
        readBarStyleFollowPage && backgroundImagePath?.isEmpty != false
    }

    mutating func apply(preferences: AppUiPreferences, userInterfaceStyle: UIUserInterfaceStyle) {
        let style = preferences.effectiveReaderStyle(userInterfaceStyle: userInterfaceStyle)
        // ContentTextView.selectedPaint uses btn_bg_press_2, not the platform selection tint.
        let selectionGray: CGFloat = preferences.isNightReaderTheme(userInterfaceStyle: userInterfaceStyle) ? 104 : 133
        selectionColor = UIColor(
            red: selectionGray / 255, green: selectionGray / 255, blue: selectionGray / 255, alpha: 99 / 255)
        let weights: (body: Int, title: Int)
        switch Int(style.textBold) {
        case 1:
            weights = (700, 900)
        case 2:
            weights = (300, 400)
        default:
            weights = (400, 700)
        }
        let body = ReaderFontWeightResolver.resolve(name: style.fontName, size: CGFloat(style.fontSizeSp), weight: weights.body)
        font = body.font
        bodyStrokeWidth = body.strokeWidth
        let titleSize = CGFloat(style.fontSizeSp) + CGFloat(style.titleSize)
        let title = ReaderFontWeightResolver.resolve(name: style.fontName, size: titleSize, weight: weights.title)
        titleFont = title.font
        titleStrokeWidth = title.strokeWidth
        tipFont = ReaderThemeVisualStyle.tipFont(name: style.fontName)
        // ChapterProvider advances by the floating-point TextPaint metric, without per-line rounding.
        bodyLineHeight = font.lineHeight * CGFloat(max(style.lineSpacingMultiplier, 0.2))
        titleLineHeight = titleFont.lineHeight * CGFloat(max(style.lineSpacingMultiplier, 0.2))
        lineSpacing = max(bodyLineHeight - font.lineHeight, 0)
        letterSpacing = CGFloat(style.letterSpacing)
        paragraphSpacing = font.lineHeight * CGFloat(style.paragraphSpacing) / 10
        headingParagraphSpacing = titleFont.lineHeight * CGFloat(style.paragraphSpacing) / 10
        paragraphIndentCount = Int(style.paragraphIndent)
        underline = style.underline
        contentInsets = .init(
            top: CGFloat(style.paddingTop),
            left: CGFloat(style.paddingLeft),
            bottom: CGFloat(style.paddingBottom),
            right: CGFloat(style.paddingRight)
        )
        headerInsets = .init(
            top: CGFloat(style.headerPaddingTop),
            left: CGFloat(style.headerPaddingLeft),
            bottom: CGFloat(style.headerPaddingBottom),
            right: CGFloat(style.headerPaddingRight)
        )
        footerInsets = .init(
            top: CGFloat(style.footerPaddingTop),
            left: CGFloat(style.footerPaddingLeft),
            bottom: CGFloat(style.footerPaddingBottom),
            right: CGFloat(style.footerPaddingRight)
        )
        titleMode = Int(style.titleMode)
        titleTopSpacing = CGFloat(style.titleTopSpacing)
        titleBottomSpacing = CGFloat(style.titleBottomSpacing)
        showHeaderLine = style.showHeaderLine
        showFooterLine = style.showFooterLine
        tipHeaderLeft = Int(style.tipHeaderLeft)
        tipHeaderMiddle = Int(style.tipHeaderMiddle)
        tipHeaderRight = Int(style.tipHeaderRight)
        tipFooterLeft = Int(style.tipFooterLeft)
        tipFooterMiddle = Int(style.tipFooterMiddle)
        tipFooterRight = Int(style.tipFooterRight)
        headerMode = Int(style.headerMode)
        footerMode = Int(style.footerMode)
        backgroundAlpha = CGFloat(style.backgroundAlpha) / 100
        backgroundImagePath = style.backgroundImagePath
        darkStatusIcon = style.darkStatusIcon

        switch style.backgroundMode {
        case ReaderBackgroundMode.dark:
            backgroundColor = UIColor(hex: style.backgroundColorHex ?? "#111111") ?? .black
            textColor = UIColor(hex: style.textColorHex ?? "#D0D0D0") ?? .lightText
        case ReaderBackgroundMode.sepia:
            backgroundColor = UIColor(hex: style.backgroundColorHex ?? "#ffc0edc6") ?? UIColor(red: 192 / 255, green: 237 / 255, blue: 198 / 255, alpha: 1)
            textColor = UIColor(hex: style.textColorHex ?? "#3F2F1D") ?? .darkText
        default:
            backgroundColor = UIColor(hex: style.backgroundColorHex ?? "#EEEEEE") ?? UIColor(red: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1)
            textColor = UIColor(hex: style.textColorHex ?? "#3E3D3B") ?? .label
        }
        tipColor = UIColor(hex: style.tipColorHex ?? "") ?? textColor
        tipDividerColor =
            style.tipDividerColorHex == ReaderTipValues.followTextColor
            ? textColor : (UIColor(hex: style.tipDividerColorHex ?? "") ?? UIColor(hex: "#66666666") ?? .separator)
    }

    mutating func apply(runtimeConfig: AppRuntimeConfig) {
        textAlignment = runtimeConfig.reader.textFullJustify ? .justified : .natural
        prefersBottomAlignedContent = runtimeConfig.reader.textBottomJustify
        chineseMode = Int(runtimeConfig.reader.chineseMode)
        useZhLayout = runtimeConfig.reader.useZhLayout
        readBodyToLh = runtimeConfig.reader.readBodyToLh
        hideStatusBar = runtimeConfig.reader.hideStatusBar
        hideNavigationBar = runtimeConfig.reader.hideNavigationBar
        readBarStyleFollowPage = runtimeConfig.readBarStyleFollowPage
    }

    func isHeaderVisible() -> Bool {
        switch headerMode {
        case 1:
            return true
        case 2:
            return false
        default:
            return hideStatusBar
        }
    }

    func isFooterVisible() -> Bool {
        footerMode != 1
    }

    var headerRowHeight: CGFloat {
        headerRowHeight(displayScale: chromeDisplayScale)
    }

    func headerRowHeight(displayScale: CGFloat) -> CGFloat {
        guard isHeaderVisible() else { return 0 }
        let scale = displayScale.isFinite ? max(displayScale, 1) : 1
        return ReaderChromeMetrics.rowHeight(
            tips: [tipHeaderLeft, tipHeaderMiddle, tipHeaderRight], readingFont: tipFont, displayScale: scale)
    }

    var footerRowHeight: CGFloat {
        footerRowHeight(displayScale: chromeDisplayScale)
    }

    func footerRowHeight(displayScale: CGFloat) -> CGFloat {
        // Android keeps the left footer slot invisible, rather than gone, for `none`.
        guard isFooterVisible() else { return 0 }
        let scale = displayScale.isFinite ? max(displayScale, 1) : 1
        return ReaderChromeMetrics.rowHeight(
            tips: [tipFooterLeft, tipFooterMiddle, tipFooterRight], readingFont: tipFont,
            keepsLeftSlot: true, displayScale: scale)
    }

    func estimatedHeaderHeight(for width: CGFloat, displayScale: CGFloat? = nil) -> CGFloat {
        guard isHeaderVisible() else { return 0 }
        let contentWidth = max(width - headerInsets.left - headerInsets.right, 1)
        let tipHeight = headerRowHeight(displayScale: displayScale ?? chromeDisplayScale)
        let divider: CGFloat = showHeaderLine ? 0.5 : 0
        _ = contentWidth
        return headerInsets.top + tipHeight + headerInsets.bottom + divider
    }

    func estimatedFooterHeight(for width: CGFloat, displayScale: CGFloat? = nil) -> CGFloat {
        guard isFooterVisible() else { return 0 }
        let contentWidth = max(width - footerInsets.left - footerInsets.right, 1)
        let tipHeight = footerRowHeight(displayScale: displayScale ?? chromeDisplayScale)
        let divider: CGFloat = showFooterLine ? 0.5 : 0
        _ = contentWidth
        return footerInsets.top + tipHeight + footerInsets.bottom + divider
    }
}

extension AppUiPreferences {
    func effectiveReaderStyle(userInterfaceStyle: UIUserInterfaceStyle) -> ReaderStylePreferences {
        ReaderThemeVisualStyle.style(preferences: self, userInterfaceStyle: userInterfaceStyle)
    }

    func isNightReaderTheme(userInterfaceStyle: UIUserInterfaceStyle) -> Bool {
        ReaderThemeVisualStyle.variant(preferences: self, userInterfaceStyle: userInterfaceStyle) == .night
    }
}

extension UIColor {
    fileprivate func readerBlended(over backdrop: UIColor, alpha: CGFloat) -> UIColor {
        UIColor { traits in
            let foreground = self.resolvedColor(with: traits)
            let background = backdrop.resolvedColor(with: traits)
            var foregroundRed: CGFloat = 0
            var foregroundGreen: CGFloat = 0
            var foregroundBlue: CGFloat = 0
            var foregroundAlpha: CGFloat = 0
            var backgroundRed: CGFloat = 0
            var backgroundGreen: CGFloat = 0
            var backgroundBlue: CGFloat = 0
            var backgroundAlpha: CGFloat = 0
            guard foreground.getRed(&foregroundRed, green: &foregroundGreen, blue: &foregroundBlue, alpha: &foregroundAlpha),
                background.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha)
            else {
                return foreground.withAlphaComponent(alpha)
            }
            let clampedAlpha = min(max(alpha * foregroundAlpha, 0), 1)
            return UIColor(
                red: foregroundRed * clampedAlpha + backgroundRed * (1 - clampedAlpha),
                green: foregroundGreen * clampedAlpha + backgroundGreen * (1 - clampedAlpha),
                blue: foregroundBlue * clampedAlpha + backgroundBlue * (1 - clampedAlpha),
                alpha: 1
            )
        }
    }

}
