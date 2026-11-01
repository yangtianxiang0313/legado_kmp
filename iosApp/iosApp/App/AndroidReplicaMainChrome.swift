import UIKit
import shared

extension Notification.Name {
    static let androidReplicaThemeDidChange = Notification.Name("io.legado.themePaletteDidChange")
}

enum AndroidMainTabIcon: String, CaseIterable {
    case books = "Books"
    case explore = "Explore"
    case rss = "Rss"
    case person = "Person"

    func image(selected: Bool) -> UIImage? {
        UIImage(named: "MainTabAndroid\(rawValue)\(selected ? "Selected" : "Normal")")?
            .withRenderingMode(.alwaysTemplate)
    }
}

final class AndroidReplicaBottomTabButton: UIControl {
    private let iconView = UIImageView()
    private let icon: AndroidMainTabIcon
    private let updateBadge = BookshelfPendingUpdateBadgeView()
    private var isCurrentTab = false

    init(title: String, icon: AndroidMainTabIcon) {
        self.icon = icon
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isExclusiveTouch = true
        isAccessibilityElement = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false
        iconView.isAccessibilityElement = false
        accessibilityLabel = title
        addInteraction(UIToolTipInteraction(defaultToolTip: title))
        addSubview(iconView)
        // activity_main.xml uses unlabeled navigation with a transparent active indicator.
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
        ])
        addSubview(updateBadge)
        let badgeCenter = updateBadge.centerXAnchor.constraint(equalTo: iconView.centerXAnchor, constant: 12)
        badgeCenter.priority = .defaultHigh
        NSLayoutConstraint.activate([
            badgeCenter,
            updateBadge.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            updateBadge.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            updateBadge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHighlighted: Bool {
        didSet { applyPalette() }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
            applyPalette()
        }
    }

    func setSelected(_ selected: Bool) {
        isCurrentTab = selected
        isSelected = selected
        iconView.image = icon.image(selected: selected)
        accessibilityTraits = selected ? [.button, .selected] : .button
        applyPalette()
    }

    func setPendingUpdateCount(_ count: Int) {
        let visibleCount = icon == .books ? max(0, count) : 0
        updateBadge.setCount(visibleCount)
        accessibilityValue = visibleCount > 0 ? L10n.Bookshelf.waitUpdateCount(visibleCount) : nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyPalette()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelTracking(with: nil)
            isHighlighted = false
        }
        applyPalette()
    }

    @objc private func applyPalette() {
        // ThemeBottomNavigationVIew derives contrast from bottomBackground, not night mode.
        let surface = AndroidReplicaTheme.bottomBackground.resolvedColor(with: traitCollection)
        let lightSurface = ReaderPaletteColor.isLight(surface)
        let resourceTraits = UITraitCollection(userInterfaceStyle: lightSurface ? .light : .dark)
        let normalColor = lightSurface ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
        iconView.tintColor = isCurrentTab
            ? AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
            : normalColor.resolvedColor(with: resourceTraits)
        backgroundColor = isHighlighted && isEnabled && !ReaderPaletteColor.isEInk
            ? AndroidReplicaTheme.activeIndicator.resolvedColor(with: resourceTraits) : .clear
    }
}

enum AndroidReplicaTheme {
    // ThemeConfig.applyTheme defaults; resource text/menu colors use values[-night]/colors.xml.
    static let background = dynamic(light: 0xFFF5_F5F5, dark: 0xFF21_2121, presetField: "backgroundColor")
    static let toolbarBackground = dynamic(light: 0xFF79_5548, dark: 0xFF54_6E7A, presetField: "primaryColor")
    static let toolbarText = UIColor { traits in
        let color = toolbarBackground.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.5 ? UIColor(white: 0, alpha: 222 / 255.0) : .white
    }
    static let bottomBackground = dynamic(light: 0xFFEE_EEEE, dark: 0xFF30_3030, presetField: "bottomBackground")
    static let menuBackground = dynamic(light: 0xFFE0_E0E0, dark: 0xFF42_4242)
    static let primaryText = dynamic(light: 0xDE00_0000, dark: 0xFFFF_FFFF)
    static let secondaryText = dynamic(light: 0x8A00_0000, dark: 0xB3FF_FFFF)
    static let summaryText = dynamic(light: 0x8A2C_2C2C, dark: 0xFFB3_B3B3)
    static let divider = dynamic(light: 0x8FE0_E0E0, dark: 0xFF36_3636)
    static let activeIndicator = dynamic(light: 0x1F00_0000, dark: 0x33FF_FFFF)
    static let accent = dynamic(light: 0xFFE5_3935, dark: 0xFFD8_4315, presetField: "accentColor")
    static let coverBackground = dynamic(light: 0xFFE0_E0E0, dark: 0xFF42_4242)

    private static func dynamic(light: UInt32, dark: UInt32, presetField: String? = nil) -> UIColor {
        UIColor { traits in
            if let presetField, let color = AndroidReplicaThemePalette.shared.color(for: presetField, traits: traits) {
                return color
            }
            let argb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((argb >> 16) & 255) / 255,
                green: CGFloat((argb >> 8) & 255) / 255,
                blue: CGFloat(argb & 255) / 255,
                alpha: CGFloat((argb >> 24) & 255) / 255)
        }
    }
}

final class AndroidReplicaTitleBar: NavigationToolbarView {
    private let titleLabel = UILabel()
    private let actionStack = UIStackView()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        titleLabel.accessibilityTraits = [.header, .staticText]
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.spacing = 6
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: AndroidToolbarLayout.titleVerticalMargins),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -AndroidToolbarLayout.titleVerticalMargins),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        updateTypography()
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false {
            applyPalette()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPalette()
    }

    func addAction(systemName: String, accessibilityLabel: String, target: Any?, action: Selector) {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.accessibilityLabel = accessibilityLabel
        button.addInteraction(UIToolTipInteraction(defaultToolTip: accessibilityLabel))
        button.addTarget(target, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        actionStack.addArrangedSubview(button)
        applyPalette()
    }

    private func updateTypography() {
        // Keep the fixed 56-point toolbar, as AndroidEditorTitleBar does.
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 20), maximumPointSize: 32, compatibleWith: traitCollection)
    }

    @objc private func applyPalette() {
        let color = AndroidReplicaTheme.toolbarText.resolvedColor(with: traitCollection)
        titleLabel.textColor = color
        for case let button as UIButton in actionStack.arrangedSubviews {
            button.tintColor = color
            if button.configuration == nil {
                button.setTitleColor(color, for: .normal)
            }
        }
    }
}

final class AndroidReplicaSearchPill: UIControl {
    private let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let label = UILabel()
    private lazy var surfaceHeightConstraint = heightAnchor.constraint(equalToConstant: 30)

    init(placeholder: String = "搜索") {
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.menuBackground
        layer.cornerRadius = 15
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityLabel = placeholder
        accessibilityTraits = .button

        icon.tintColor = AndroidReplicaTheme.secondaryText
        icon.isAccessibilityElement = false
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.text = placeholder
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        label.textColor = AndroidReplicaTheme.secondaryText
        label.isAccessibilityElement = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        surfaceHeightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            surfaceHeightConstraint,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            updateTypography()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let alignment: NSTextAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        if label.textAlignment != alignment { label.textAlignment = alignment }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Use the existing 10-point outer margins, without growing the 30-point surface.
        bounds.insetBy(dx: -max(0, (44 - bounds.width) / 2), dy: -max(0, (44 - bounds.height) / 2))
            .contains(point)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, isUserInteractionEnabled, !isHidden, window != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func updateTypography() {
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: traitCollection)
        surfaceHeightConstraint.constant = max(
            AndroidToolbarLayout.searchSurfaceHeight(font: label.font, displayScale: traitCollection.displayScale),
            ceil(label.font.lineHeight) + 8)
    }
}

/// Keeps existing chrome colors live when a backup or the theme picker changes defaults.
final class AndroidReplicaThemePalette {
    static let shared = AndroidReplicaThemePalette()
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var selected: ThemePreset?
    private var paired: ThemePreset?
    private var colors: [String: UInt32] = [:]
    private var themeMode = "SYSTEM"
    private var lastSignature: [String] = []
    private static let fields = [
        "primaryColor": "colorPrimary", "accentColor": "colorAccent",
        "backgroundColor": "colorBackground", "bottomBackground": "colorBottomBackground",
    ]

    init(defaults: UserDefaults = .standard, observe: Bool = true) {
        self.defaults = defaults
        reload()
        guard observe else { return }
        lastSignature = []
        DispatchQueue.main.async { [weak self] in self?.refreshWindowsIfNeeded() }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshWindowsIfNeeded() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func color(for field: String, traits: UITraitCollection, followsTraits: Bool = false) -> UIColor? {
        let desiredNight: Bool
        if followsTraits {
            desiredNight = traits.userInterfaceStyle == .dark
        } else {
            switch themeMode {
            case "LIGHT", "E_INK": desiredNight = false
            case "DARK": desiredNight = true
            default: desiredNight = traits.userInterfaceStyle == .dark
            }
        }
        guard let key = Self.fields[field] else { return nil }
        if themeMode == "E_INK" { return field == "accentColor" ? .black : .white }
        let palette = selected?.isNightTheme == desiredNight ? selected : paired
        let fallback: [String: UInt32] =
            desiredNight
            ? [
                "primaryColor": 0x546E7A, "accentColor": 0xD84315, "backgroundColor": 0x212121,
                "bottomBackground": 0x303030,
            ]
            : [
                "primaryColor": 0x795548, "accentColor": 0xE53935, "backgroundColor": 0xF5F5F5,
                "bottomBackground": 0xEEEEEE,
            ]
        var number =
            colors[key + (desiredNight ? "Night" : "")]
            ?? palette.flatMap { Self.value(field: field, preset: $0) }.flatMap(Self.parse)
            ?? fallback[field]!
        if field == "backgroundColor", Self.isLight(number) == desiredNight { number = fallback[field]! }
        return UIColor(
            red: CGFloat((number >> 16) & 255) / 255,
            green: CGFloat((number >> 8) & 255) / 255,
            blue: CGFloat(number & 255) / 255,
            alpha: 1)
    }

    private func reload() {
        let name = defaults.string(forKey: "theme_preset_name") ?? ""
        var presets = DefaultUiPresets.shared.themePresets
        if let raw = defaults.string(forKey: "backup_theme_presets"), let data = raw.data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            presets = values.compactMap { value in
                guard let name = value["themeName"] as? String,
                    let primary = value["primaryColor"] as? String, let accent = value["accentColor"] as? String,
                    let background = value["backgroundColor"] as? String,
                    let bottom = value["bottomBackground"] as? String
                else { return nil }
                return ThemePreset(
                    themeName: name, isNightTheme: value["isNightTheme"] as? Bool ?? false,
                    primaryColor: primary, accentColor: accent, backgroundColor: background,
                    bottomBackground: bottom, pairedThemeName: value["pairedThemeName"] as? String)
            }
        }
        selected =
            presets.first { $0.themeName == name }
            ?? DefaultUiPresets.shared.legacyThemePresets.first { $0.themeName == name }
        paired = nil
        themeMode = defaults.string(forKey: "theme_mode") ?? "SYSTEM"
        if let selected, let pairName = selected.pairedThemeName {
            paired = presets.first {
                $0.themeName == pairName && $0.pairedThemeName == name && $0.isNightTheme != selected.isNightTheme
            }
        }
        colors = [:]
        for key in Self.fields.values {
            for suffix in ["", "Night"] {
                let name = key + suffix
                if let value = defaults.object(forKey: name) as? NSNumber {
                    colors[name] = UInt32(truncatingIfNeeded: value.int64Value)
                } else if let raw = defaults.string(forKey: name) {
                    colors[name] = Self.parse(raw)
                }
            }
        }
        lastSignature = signature()
    }

    private func signature() -> [String] {
        ["backup_theme_presets", "theme_preset_name", "theme_mode"]
            .map { defaults.string(forKey: $0) ?? "" }
            + Self.fields.values.sorted().flatMap { key in
                ["", "Night"].map {
                    defaults.object(forKey: key + $0).map { String(describing: $0) } ?? ""
                }
            }
    }

    private static func value(field: String, preset: ThemePreset) -> String? {
        switch field {
        case "primaryColor": return preset.primaryColor
        case "accentColor": return preset.accentColor
        case "backgroundColor": return preset.backgroundColor
        case "bottomBackground": return preset.bottomBackground
        default: return nil
        }
    }

    private static func parse(_ raw: String) -> UInt32? {
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if hex.count == 6 || hex.count == 8, let number = UInt32(hex, radix: 16) { return number }
        // Older Android backups may retain an unnormalized named Color.parseColor value.
        return [
            "black": 0x000000, "darkgray": 0x444444, "darkgrey": 0x444444,
            "gray": 0x888888, "grey": 0x888888, "lightgray": 0xCCCCCC, "lightgrey": 0xCCCCCC,
            "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x00FF00, "lime": 0x00FF00,
            "blue": 0x0000FF, "yellow": 0xFFFF00, "cyan": 0x00FFFF, "aqua": 0x00FFFF,
            "magenta": 0xFF00FF, "fuchsia": 0xFF00FF, "maroon": 0x800000, "navy": 0x000080,
            "olive": 0x808000, "purple": 0x800080, "silver": 0xC0C0C0, "teal": 0x008080,
        ][raw.lowercased()]
    }

    private static func isLight(_ argb: UInt32) -> Bool {
        func linear(_ shift: UInt32) -> Double {
            let channel = Double((argb >> shift) & 255) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return linear(16) * 0.2126 + linear(8) * 0.7152 + linear(0) * 0.0722 >= 0.5
    }

    private func refreshWindowsIfNeeded() {
        guard signature() != lastSignature else { return }
        reload()
        let style: UIUserInterfaceStyle
        switch defaults.string(forKey: "theme_mode") {
        case "LIGHT", "E_INK": style = .light
        case "DARK": style = .dark
        default: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
                refreshColors(in: window)
            }
        }
        NotificationCenter.default.post(name: .androidReplicaThemeDidChange, object: self)
    }

    private func refreshColors(in view: UIView) {
        // Reassign the original dynamic UIColor so UIKit resolves its provider again.
        if let color = view.backgroundColor {
            view.backgroundColor = nil
            view.backgroundColor = color
        }
        let tint = view.tintColor
        view.tintColor = nil
        view.tintColor = tint
        if let label = view as? UILabel {
            let color = label.textColor
            label.textColor = nil
            label.textColor = color
        }
        if let text = view as? UITextView {
            let color = text.textColor
            text.textColor = nil
            text.textColor = color
        }
        if let table = view as? UITableView {
            let color = table.separatorColor
            table.separatorColor = nil
            table.separatorColor = color
        }
        view.setNeedsDisplay()
        view.setNeedsLayout()
        for child in view.subviews { refreshColors(in: child) }
    }
}
