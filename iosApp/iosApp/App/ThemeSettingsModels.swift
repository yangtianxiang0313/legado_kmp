import UIKit
import shared

enum ThemeBackgroundChannel: CaseIterable, Sendable {
    case day, night

    init(isNight: Bool) { self = isNight ? .night : .day }

    var isNight: Bool { self == .night }
    var title: String {
        isNight
            ? NSLocalizedString("settings.theme_background_night_title", value: "夜间背景图片", comment: "Night background picker title")
            : NSLocalizedString("settings.theme_background_day_title", value: "白天背景图片", comment: "Day background picker title")
    }
    var imageKey: String { isNight ? "backgroundImageNight" : "backgroundImage" }
    var blurringKey: String { isNight ? "backgroundImageNightBlurring" : "backgroundImageBlurring" }
    var identifier: String { isNight ? "settings.theme.background.night" : "settings.theme.background.day" }
}

struct ThemeBackgroundConfiguration: Equatable, Sendable {
    let channel: ThemeBackgroundChannel
    let imagePath: String?
    let blurring: Int

    init(channel: ThemeBackgroundChannel, imagePath: String?, blurring: Int) {
        self.channel = channel
        self.imagePath = imagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? imagePath : nil
        self.blurring = min(25, max(0, blurring))
    }

    static func read(channel: ThemeBackgroundChannel, defaults: UserDefaults = .standard) -> Self {
        let raw = defaults.string(forKey: "backup_android_config") ?? "{}"
        let values =
            raw.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
        let blur =
            (values[channel.blurringKey] as? NSNumber)?.intValue
            ?? (values[channel.blurringKey] as? String).flatMap(Int.init) ?? 0
        return Self(channel: channel, imagePath: values[channel.imageKey] as? String, blurring: blur)
    }

    var summary: String {
        guard let imagePath else {
            return NSLocalizedString("settings.theme_background_select", value: "选择图片", comment: "Theme background selection")
        }
        guard ThemeBackgroundImageStore.fileURL(for: imagePath) != nil else {
            return NSLocalizedString(
                "settings.theme_background_unavailable", value: "图片不可用，请重新选择", comment: "Unavailable theme background")
        }
        return blurring == 0
            ? NSLocalizedString("settings.theme_background_selected", value: "已选择背景图片", comment: "Selected theme background")
            : String(
                format: NSLocalizedString(
                    "settings.theme_background_selected_blur", value: "已选择背景图片，模糊度 %ld",
                    comment: "Selected theme background; Int blur radius"), blurring)
    }
}

enum ThemeColorSetting: CaseIterable {
    case primary, accent, background, bottomBackground

    var title: String {
        switch self {
        case .primary:
            return NSLocalizedString("settings.theme_primary_color_title", value: "主色调", comment: "Legado primary")
        case .accent:
            return NSLocalizedString("settings.theme_accent_color_title", value: "强调色", comment: "Legado accent")
        case .background:
            return NSLocalizedString("settings.theme_background_color_title", value: "背景色", comment: "Legado background_color")
        case .bottomBackground:
            return NSLocalizedString(
                "settings.theme_bottom_background_title", value: "底部操作栏颜色", comment: "Legado navbar_color")
        }
    }

    func summary(isNight: Bool) -> String {
        let field =
            self == .bottomBackground
            ? NSLocalizedString("settings.theme_bottom_background_summary", value: "底栏色", comment: "Legado navbar_color summary")
            : title
        let channel =
            isNight
            ? NSLocalizedString("settings.theme_night", value: "夜间", comment: "Legado night")
            : NSLocalizedString("settings.theme_day", value: "白天", comment: "Legado day")
        return String(
            format: NSLocalizedString(
                "settings.theme_color_summary", value: "%@，%@", comment: "Theme channel, then color field"), channel, field)
    }

    var sharedField: ThemeColorField {
        switch self {
        case .primary: return .primary
        case .accent: return .accent
        case .background: return .background
        case .bottomBackground: return .bottomBackground
        }
    }

    func hex(in palette: ThemeColorPalette) -> String {
        switch self {
        case .primary: return palette.primaryColor
        case .accent: return palette.accentColor
        case .background: return palette.backgroundColor
        case .bottomBackground: return palette.bottomBackground
        }
    }

    func color(in palette: ThemeColorPalette) -> UIColor? {
        guard let value = UInt32(hex(in: palette).dropFirst(), radix: 16) else { return nil }
        return ReaderPaletteColor.argb(value)
    }

    static func hex(_ color: UIColor) -> String {
        "#FF" + ReaderColorHex.hexString(color: color, traits: .current)
    }
}

final class ThemeSettingsModeButton: UIButton {
    var onToggle: (() -> Void)?
    var onChoose: (() -> Void)?
    private var measuredTitle = CGSize.zero
    private var fontPadding = UIEdgeInsets.zero
    private var textFont = UIFont.systemFont(ofSize: 14)
    private let localizedTitle = L10n.Settings.themeModeTitle

    init() {
        super.init(frame: .zero)
        setTitle(localizedTitle, for: .normal)
        setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        accessibilityIdentifier = "settings.theme.mode"
        accessibilityLabel = localizedTitle
        contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        titleLabel?.numberOfLines = 2
        titleLabel?.lineBreakMode = .byWordWrapping
        titleLabel?.adjustsFontSizeToFitWidth = false
        addInteraction(UIToolTipInteraction(defaultToolTip: localizedTitle))
        addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(chooseMode(_:))))
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.Settings.themeModeRootDetail) { [weak self] _ in
                guard let self, self.isEnabled else { return false }
                self.onChoose?()
                return true
            }
        ]
        refreshTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func apply(modeText: String, enabled: Bool) {
        refreshTypography()
        setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        accessibilityValue = modeText
        isEnabled = enabled
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: max(48, ceil(measuredTitle.width) + 16),
            height: max(48, ceil(measuredTitle.height + fontPadding.top + fontPadding.bottom) + 8))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(size.width, intrinsicContentSize.width)
        return CGSize(
            width: width,
            height: max(48, ceil(textHeight(width: max(1, width - 16)) + fontPadding.top + fontPadding.bottom) + 8))
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        let height = textHeight(width: contentRect.width)
        let paddedHeight = height + fontPadding.top + fontPadding.bottom
        return CGRect(
            x: contentRect.minX, y: contentRect.midY - paddedHeight / 2 + fontPadding.top,
            width: contentRect.width, height: height)
    }

    private func textHeight(width: CGFloat) -> CGFloat {
        let rect = (localizedTitle as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: textFont], context: nil)
        let height = max(textFont.lineHeight, rect.height)
        return traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? height : min(textFont.lineHeight * 2, height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshTypography()
    }

    private func refreshTypography() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        textFont = font
        measuredTitle = CGSize(
            width: (localizedTitle as NSString).size(withAttributes: [.font: font]).width, height: font.lineHeight)
        fontPadding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        titleLabel?.font = font
        titleLabel?.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 2
        titleLabel?.adjustsFontForContentSizeCategory = false
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func toggleMode() { if isEnabled { onToggle?() } }

    @objc private func chooseMode(_ recognizer: UILongPressGestureRecognizer) {
        if isEnabled, recognizer.state == .began { onChoose?() }
    }
}
