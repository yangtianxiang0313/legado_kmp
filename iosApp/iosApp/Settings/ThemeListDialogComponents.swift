import UIKit
import shared

/// Value snapshots include KMP-only metadata for stale-row checks, never for Android export.
struct ThemeListDialogRow {
    struct ID: Hashable {
        let name: String
        let occurrence: Int
    }

    struct Signature: Equatable {
        let themeName: String
        let isNightTheme: Bool
        let primaryColor: String
        let accentColor: String
        let backgroundColor: String
        let bottomBackground: String
        let pairedThemeName: String?

        init(_ preset: ThemePreset) {
            themeName = preset.themeName
            isNightTheme = preset.isNightTheme
            primaryColor = preset.primaryColor
            accentColor = preset.accentColor
            backgroundColor = preset.backgroundColor
            bottomBackground = preset.bottomBackground
            pairedThemeName = preset.pairedThemeName
        }
    }

    let id: ID
    let signature: Signature
    let preset: ThemePreset

    static func make(_ presets: [ThemePreset]) -> [Self] {
        var occurrences: [String: Int] = [:]
        return presets.map { preset in
            let occurrence = occurrences[preset.themeName, default: 0]
            occurrences[preset.themeName] = occurrence + 1
            return Self(
                id: ID(name: preset.themeName, occurrence: occurrence),
                signature: Signature(preset), preset: preset)
        }
    }
}

@MainActor
struct ThemeListDialogScrollAnchor {
    private let oldIDs: [ThemeListDialogRow.ID]
    private let index: Int
    private let relativeY: CGFloat

    init?(table: UITableView, rows: [ThemeListDialogRow]) {
        table.layoutIfNeeded()
        guard let path = table.indexPathsForVisibleRows?.min(by: { $0.row < $1.row }),
            rows.indices.contains(path.row)
        else { return nil }
        oldIDs = rows.map(\.id)
        index = path.row
        relativeY = table.rectForRow(at: path).minY - table.contentOffset.y
    }

    func restore(table: UITableView, rows: [ThemeListDialogRow]) {
        table.layoutIfNeeded()
        let indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        // A deleted anchor falls forward to its next surviving neighbour, then backward.
        let candidates = Array(oldIDs[index...]) + Array(oldIDs[..<index].reversed())
        let row = candidates.lazy.compactMap { indices[$0] }.first
        let desired =
            row.map {
                table.rectForRow(at: IndexPath(row: $0, section: 0)).minY - relativeY
            } ?? table.contentOffset.y
        let minimum = -table.adjustedContentInset.top
        let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(minimum, desired))), animated: false)
    }
}

@MainActor
final class ThemeListDialogIconButton: UIButton {
    override func imageRect(forContentRect contentRect: CGRect) -> CGRect { contentRect }
}

@MainActor
final class ThemeListDialogApplyButton: UIButton {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }
}

/// ActionButton's logical 12dp padding overrides the layout's left/right 8dp on API 21+.
/// abc_action_menu_item_layout supplies 4dp vertical padding; ActionButton allows two lines.
@MainActor
final class ThemeListDialogImportButton: UIButton {
    private let caption = AndroidExploreTextLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        caption.text = "剪贴板导入"
        caption.numberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        caption.textAlignment = .center
        caption.adjustsFontForContentSizeCategory = false
        caption.isAccessibilityElement = false
        caption.isUserInteractionEnabled = false
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear
        }
    }

    func applyAppearance(foreground: UIColor, traits: UITraitCollection) {
        caption.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traits)
        caption.textColor = foreground
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = caption.sizeThatFits(
            CGSize(width: max(1, size.width - 24), height: .greatestFiniteMagnitude))
        return CGSize(width: max(48, ceil(text.width) + 24), height: max(48, ceil(text.height) + 8))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        caption.frame = CGRect(
            x: min(12, bounds.width / 2), y: min(4, bounds.height / 2),
            width: max(0, bounds.width - 24), height: max(0, bounds.height - 8))
    }
}

/// item_theme_config.xml: 8dp row padding, two independent 36dp slots, 6dp icon padding.
@MainActor
final class ThemeListDialogCell: UITableViewCell {
    static let reuseID = "ThemeListDialogCell"
    let applyControl = ThemeListDialogApplyButton(type: .custom)
    let shareButton = ThemeListDialogIconButton(type: .custom)
    let deleteButton = ThemeListDialogIconButton(type: .custom)
    private let nameLabel = AndroidExploreTextLabel()
    private let divider = UIView()
    var onApply: (() -> Void)?
    var onShare: ((UIView) -> Void)?
    var onDelete: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        isAccessibilityElement = false
        contentView.addSubview(applyControl)
        applyControl.addSubview(nameLabel)
        for item in [shareButton, deleteButton, divider] { contentView.addSubview(item) }
        applyControl.isAccessibilityElement = true
        applyControl.accessibilityTraits = .button
        nameLabel.isAccessibilityElement = false
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.adjustsFontForContentSizeCategory = false
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.isUserInteractionEnabled = false
        shareButton.setImage(
            UIImage(named: "BookDetailAndroidShare")?.withRenderingMode(.alwaysTemplate), for: .normal)
        deleteButton.setImage(
            UIImage(named: "ReaderPresetAndroidDelete")?.withRenderingMode(.alwaysTemplate), for: .normal)
        for button in [shareButton, deleteButton] {
            button.tintColor = AndroidReplicaTheme.primaryText
            button.imageView?.contentMode = .scaleAspectFit
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            button.adjustsImageWhenDisabled = false
            button.isExclusiveTouch = true
        }
        shareButton.accessibilityLabel = "分享"
        deleteButton.accessibilityLabel = "删除"
        shareButton.addInteraction(UIToolTipInteraction(defaultToolTip: "分享"))
        deleteButton.addInteraction(UIToolTipInteraction(defaultToolTip: "删除"))
        applyControl.isExclusiveTouch = true
        applyControl.addTarget(self, action: #selector(apply), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deletePreset), for: .touchUpInside)
        contentView.accessibilityElements = [applyControl, shareButton, deleteButton]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onApply = nil
        onShare = nil
        onDelete = nil
        nameLabel.text = nil
        applyControl.accessibilityLabel = nil
        setActionsEnabled(false)
    }

    static func titleFont(_ traits: UITraitCollection) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
    }

    static func height(traits: UITraitCollection) -> CGFloat {
        let font = titleFont(traits)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        let titleHeight = font.lineHeight + padding.top + padding.bottom
        return ceil(max(36, titleHeight)) + 16 + 1 / max(1, traits.displayScale)
    }

    func configure(name: String, enabled: Bool) {
        // maxLines=1 is not singleLine=true: explicit newlines stop the visible first line.
        nameLabel.text = name.components(separatedBy: .newlines).first ?? ""
        nameLabel.font = Self.titleFont(traitCollection)
        applyControl.accessibilityLabel = name.isEmpty ? "未命名主题" : name
        setActionsEnabled(enabled)
        setNeedsLayout()
    }

    func setActionsEnabled(_ enabled: Bool) {
        applyControl.isEnabled = enabled
        shareButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
        applyControl.accessibilityTraits = enabled ? [.button] : [.button, .notEnabled]
        for button in [applyControl, shareButton, deleteButton] {
            button.alpha = enabled ? 1 : 0.38
            if !enabled {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, contentView.bounds.width)
        let pixel = 1 / max(1, traitCollection.displayScale)
        let height = max(0, contentView.bounds.height - pixel)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // Sibling controls never propagate share/delete touches into the apply control.
        applyControl.frame = CGRect(x: rtl ? 80 : 0, y: 0, width: max(0, width - 80), height: height)
        nameLabel.frame = CGRect(
            x: rtl ? 0 : 8, y: 8, width: max(0, applyControl.bounds.width - 8), height: max(0, height - 16))
        shareButton.frame = CGRect(x: rtl ? 44 : width - 80, y: (height - 36) / 2, width: 36, height: 36)
        deleteButton.frame = CGRect(x: rtl ? 8 : width - 44, y: (height - 36) / 2, width: 36, height: 36)
        divider.frame = CGRect(x: 0, y: height, width: width, height: pixel)
    }

    @objc private func apply() {
        guard applyControl.isEnabled else { return }
        onApply?()
    }

    @objc private func share() {
        guard shareButton.isEnabled else { return }
        onShare?(shareButton)
    }

    @objc private func deletePreset() {
        guard deleteButton.isEnabled else { return }
        onDelete?()
    }
}

@MainActor
final class ThemeListDialogBodyView: UIView {
    let table = UITableView(frame: .zero, style: .plain)
    let importButton = ThemeListDialogImportButton(frame: .zero)
    let titleLabel = AndroidExploreTextLabel()
    private let toolbar = UIView()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let errorText = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 2
        titleLabel.text = "主题列表"
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "settings.themeList.title"
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        importButton.accessibilityLabel = "剪贴板导入"
        importButton.accessibilityIdentifier = "settings.themeList.import"
        importButton.addInteraction(UIToolTipInteraction(defaultToolTip: "剪贴板导入"))
        importButton.isExclusiveTouch = true
        progress.hidesWhenStopped = true
        progress.accessibilityLabel = "处理中"
        errorText.isEditable = false
        errorText.isSelectable = true
        errorText.backgroundColor = .clear
        errorText.textColor = .systemRed
        errorText.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        errorText.textContainer.lineFragmentPadding = 0
        errorText.isHidden = true
        errorText.accessibilityIdentifier = "settings.themeList.error"
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.showsVerticalScrollIndicator = false
        table.showsHorizontalScrollIndicator = false
        table.scrollsToTop = false
        table.delaysContentTouches = false
        table.estimatedRowHeight = 0
        table.sectionHeaderHeight = 0
        table.sectionFooterHeight = 0
        table.sectionHeaderTopPadding = 0
        table.allowsSelection = false
        table.register(ThemeListDialogCell.self, forCellReuseIdentifier: ThemeListDialogCell.reuseID)
        table.accessibilityIdentifier = "settings.themeList.rows"
        for item in [toolbar, errorText, table, progress] { addSubview(item) }
        for item in [titleLabel, importButton] { toolbar.addSubview(item) }
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyAppearance() {
        backgroundColor = AndroidReplicaTheme.background
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        let foreground = AndroidReplicaTheme.toolbarText
        titleLabel.textColor = foreground
        importButton.applyAppearance(foreground: foreground, traits: traitCollection)
        progress.color = AndroidReplicaTheme.accent
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let errorFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        errorText.font = errorFont
        let padding = AndroidExploreTextMetrics.padding(font: errorFont, scale: traitCollection.displayScale)
        errorText.textContainerInset = UIEdgeInsets(
            top: 8 + padding.top, left: 8, bottom: 8 + padding.bottom, right: 8)
        setNeedsLayout()
    }

    func setInteraction(enabled: Bool, busy: Bool) {
        importButton.isEnabled = enabled
        importButton.alpha = enabled ? 1 : 0.38
        if !enabled {
            importButton.cancelTracking(with: nil)
            importButton.isHighlighted = false
        }
        if busy { progress.startAnimating() } else { progress.stopAnimating() }
        setNeedsLayout()
    }

    func showError(_ message: String?) {
        errorText.text = message
        errorText.isHidden = message == nil
        errorText.setContentOffset(.zero, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width)
        // Toolbar measures the always-visible action before its single-line, ellipsized title.
        let action = importButton.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let actionWidth = min(width, action.width)
        let titleInset = min(width, 20)  // contentInsetStart=16dp + titleMarginStart=4dp.
        let titleWidth = max(0, width - titleInset - actionWidth - 4)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        // AppCompat's actionBarSize is 56dp, or 48dp in values-land; wrap_content can grow for AX.
        let baseHeight: CGFloat = traitCollection.verticalSizeClass == .compact ? 48 : 56
        let toolbarHeight = min(max(baseHeight, titleHeight + 8, action.height), max(0, bounds.height))
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let actionHeight = min(toolbarHeight, action.height)
        importButton.frame = CGRect(
            x: rtl ? 0 : width - actionWidth, y: (toolbarHeight - actionHeight) / 2,
            width: actionWidth, height: actionHeight)
        titleLabel.frame = CGRect(
            x: rtl ? actionWidth + min(4, max(0, width - actionWidth)) : titleInset,
            y: 0, width: titleWidth, height: toolbarHeight)
        let remaining = max(0, bounds.height - toolbarHeight)
        let errorHeight =
            errorText.isHidden
            ? 0
            : min(
                remaining / 3,
                ceil(errorText.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        errorText.frame = CGRect(x: 0, y: toolbarHeight, width: width, height: errorHeight)
        table.frame = CGRect(x: 0, y: toolbarHeight + errorHeight, width: width, height: remaining - errorHeight)
        // dialog_recycler_view.xml has a centred 36dp loading slot, independent of menu width.
        let progressSize = min(36, width, table.bounds.height)
        progress.frame = CGRect(
            x: table.frame.midX - progressSize / 2, y: table.frame.midY - progressSize / 2,
            width: progressSize, height: progressSize)
    }
}

/// Keeps the original six ThemeConfig.Config keys; no KMP pairing or implicit transfer.
@MainActor
final class ThemeListDialogShareItem: NSObject, UIActivityItemSource {
    nonisolated private let json: String

    init(preset: ThemePreset) throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "themeName": preset.themeName,
                "isNightTheme": preset.isNightTheme,
                "primaryColor": preset.primaryColor,
                "accentColor": preset.accentColor,
                "backgroundColor": preset.backgroundColor,
                "bottomBackground": preset.bottomBackground,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
        json = String(decoding: data, as: UTF8.self)
        super.init()
    }

    nonisolated func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any { json }

    nonisolated func activityViewController(
        _: UIActivityViewController, itemForActivityType _: UIActivity.ActivityType?
    ) -> Any? { json }

    nonisolated func activityViewController(
        _: UIActivityViewController, subjectForActivityType _: UIActivity.ActivityType?
    ) -> String { "主题分享" }
}

/// A presentation is bound to one source hierarchy, window and scene, not the global key window.
@MainActor
final class ThemeListDialogPresentationContext {
    private weak var presenter: UIViewController?
    private weak var source: UIViewController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var root: UIViewController?

    func capture(dialog: UIViewController) {
        presenter = dialog.presentingViewController
        source = presenter.map(currentLeaf)
        window = dialog.viewIfLoaded?.window ?? presenter?.viewIfLoaded?.window
        scene = window?.windowScene
        root = window?.rootViewController
    }

    func isCurrent(dialog: UIViewController, allowing child: UIViewController?) -> Bool {
        guard let presenter, let source, let window, let scene, let root,
            !window.isHidden, window.alpha > 0, window.isKeyWindow,
            scene.activationState == .foregroundActive, window.windowScene === scene,
            window.rootViewController === root, currentLeaf(presenter) === source,
            dialog.presentingViewController === presenter, presenter.presentedViewController === dialog,
            dialog.viewIfLoaded?.window === window, presenter.viewIfLoaded?.window === window,
            source.viewIfLoaded?.window === window,
            !dialog.isBeingDismissed, !dialog.isBeingPresented,
            dialog.presentedViewController == nil || dialog.presentedViewController === child
        else { return false }
        var current: UIViewController? = source
        var expectedPresentation: UIViewController?
        var includesPresenter = false
        var last: UIViewController?
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== expectedPresentation, presented !== dialog
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController,
                tabs.selectedViewController !== controller
            {
                return false
            }
            last = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return includesPresenter && last === root
    }

    private func currentLeaf(_ controller: UIViewController) -> UIViewController {
        if let navigation = controller as? UINavigationController, let top = navigation.topViewController {
            return currentLeaf(top)
        }
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
            return currentLeaf(selected)
        }
        return controller
    }
}

final class ThemeListDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
