import UIKit
import shared

enum ThemeBackgroundChannel: CaseIterable, Sendable {
    case day, night

    init(isNight: Bool) { self = isNight ? .night : .day }

    var isNight: Bool { self == .night }
    var title: String { isNight ? "夜间背景图片" : "白天背景图片" }
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
        guard let imagePath else { return "选择图片" }
        guard ThemeBackgroundImageStore.fileURL(for: imagePath) != nil else { return "图片不可用，请重新选择" }
        return blurring == 0 ? "已选择背景图片" : "已选择背景图片，模糊度 \(blurring)"
    }
}

enum ThemeColorSetting: CaseIterable {
    case primary, accent, background, bottomBackground

    var title: String {
        switch self {
        case .primary: return "主色调"
        case .accent: return "强调色"
        case .background: return "背景色"
        case .bottomBackground: return "底部操作栏颜色"
        }
    }

    func summary(isNight: Bool) -> String {
        let field = self == .bottomBackground ? "底栏色" : title
        return "\(isNight ? "夜间" : "白天")，\(field)"
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

    init() {
        super.init(frame: .zero)
        setTitle("主题模式", for: .normal)
        setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        accessibilityIdentifier = "settings.theme.mode"
        contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        titleLabel?.numberOfLines = 2
        titleLabel?.lineBreakMode = .byWordWrapping
        titleLabel?.adjustsFontSizeToFitWidth = false
        addInteraction(UIToolTipInteraction(defaultToolTip: "主题模式"))
        addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(chooseMode(_:))))
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "选择主题模式") { [weak self] _ in
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
        let rect = ("主题模式" as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: textFont], context: nil)
        return min(textFont.lineHeight * 2, max(textFont.lineHeight, rect.height))
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
            width: ("主题模式" as NSString).size(withAttributes: [.font: font]).width, height: font.lineHeight)
        fontPadding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        titleLabel?.font = font
        titleLabel?.adjustsFontForContentSizeCategory = false
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func toggleMode() { if isEnabled { onToggle?() } }

    @objc private func chooseMode(_ recognizer: UILongPressGestureRecognizer) {
        if isEnabled, recognizer.state == .began { onChoose?() }
    }
}
