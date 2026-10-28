import UIKit

enum BookSourceGroupManagementTypography {
    static func font(_ size: CGFloat, style: UIFont.TextStyle = .body, traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size), compatibleWith: traits)
    }
}

final class BookSourceGroupManagementToolbar: UIView {
    let addButton = UIButton(type: .system)
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.text = BookSourceGroupManagementText.title
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceManagement.groupManage.title"
        titleLabel.adjustsFontForContentSizeCategory = true
        addButton.setImage(UIImage(named: "BookshelfAndroidAdd")?.withRenderingMode(.alwaysTemplate), for: .normal)
        addButton.tintColor = AndroidReplicaTheme.toolbarText
        addButton.accessibilityLabel = BookSourceGroupManagementText.add
        addButton.accessibilityIdentifier = "sourceManagement.groupManage.add"
        addButton.addInteraction(UIToolTipInteraction(defaultToolTip: BookSourceGroupManagementText.add))
        addSubview(titleLabel)
        addSubview(addButton)
        accessibilityElements = [titleLabel, addButton]
        refreshTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func refreshTypography() {
        titleLabel.font = BookSourceGroupManagementTypography.font(20, style: .headline, traits: traitCollection)
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleSize = titleLabel.sizeThatFits(
            CGSize(width: max(1, size.width - 80), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: max(56, ceil(titleSize.height) + 16))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        addButton.frame = CGRect(x: rtl ? 4 : bounds.width - 52, y: (bounds.height - 48) / 2, width: 48, height: 48)
        titleLabel.frame = CGRect(
            x: rtl ? 64 : 16, y: 8, width: max(0, bounds.width - 80), height: max(0, bounds.height - 16))
        addButton.imageView?.contentMode = .scaleAspectFit
    }
}

/// item_group_manage.xml: 8dp outer padding, 8dp action padding, 12dp delete end margin.
final class BookSourceGroupManagementCell: UITableViewCell {
    private let groupLabel = UILabel()
    private let editButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var onEdit: (() -> Void)?
    private var onDelete: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = AndroidReplicaTheme.background
        groupLabel.numberOfLines = 0
        groupLabel.lineBreakMode = .byWordWrapping
        groupLabel.textColor = AndroidReplicaTheme.primaryText
        groupLabel.adjustsFontForContentSizeCategory = true
        editButton.setTitle(L10n.Common.edit, for: .normal)
        deleteButton.setTitle(L10n.Common.delete, for: .normal)
        for button in [editButton, deleteButton] {
            button.configuration = nil
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            button.setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.textAlignment = .center
            button.isExclusiveTouch = true
            contentView.addSubview(button)
        }
        contentView.addSubview(groupLabel)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        accessibilityElements = [groupLabel, editButton, deleteButton]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onEdit = nil
        onDelete = nil
    }

    func configure(group: String, enabled: Bool, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.onEdit = onEdit
        self.onDelete = onDelete
        groupLabel.text = group
        let font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        groupLabel.font = font
        editButton.titleLabel?.font = font
        deleteButton.titleLabel?.font = font
        setActionsEnabled(enabled)
        editButton.accessibilityLabel = "\(L10n.Common.edit)，\(group)"
        deleteButton.accessibilityLabel = "\(L10n.Common.delete)，\(group)"
        editButton.accessibilityIdentifier = "sourceManagement.groupManage.edit.\(group)"
        deleteButton.accessibilityIdentifier = "sourceManagement.groupManage.delete.\(group)"
        groupLabel.accessibilityIdentifier = "sourceManagement.groupManage.name.\(group)"
        setNeedsLayout()
    }

    func setActionsEnabled(_ enabled: Bool) {
        editButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
    }

    static func height(group: String, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = BookSourceGroupManagementTypography.font(14, traits: traits)
        let actions = actionWidths(font: font)
        let stacked = actions.edit + actions.delete + max(44, font.pointSize * 2) > width - 28
        let textWidth = max(1, width - 28 - (stacked ? 0 : actions.edit + actions.delete))
        let nameHeight = ceil(
            (group as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
            ).height)
        let actionHeight = Self.actionHeight(font: font, width: width)
        return 16 + (stacked ? nameHeight + actionHeight : max(nameHeight, actionHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let font = groupLabel.font ?? .systemFont(ofSize: 14)
        let actions = Self.actionWidths(font: font)
        let stacked = actions.edit + actions.delete + max(44, font.pointSize * 2) > width - 28
        let actionHeight = Self.actionHeight(font: font, width: width)
        let actionY =
            stacked ? contentView.bounds.height - 8 - actionHeight : (contentView.bounds.height - actionHeight) / 2
        let actionSpace = max(1, width - 28)
        let total = actions.edit + actions.delete
        let editWidth = min(actions.edit, actionSpace * actions.edit / max(1, total))
        let deleteWidth = min(actions.delete, max(1, actionSpace - editWidth))
        let deleteX = width - 20 - deleteWidth
        let editX = deleteX - editWidth
        editButton.frame = CGRect(x: editX, y: actionY, width: editWidth, height: actionHeight)
        deleteButton.frame = CGRect(x: deleteX, y: actionY, width: deleteWidth, height: actionHeight)
        groupLabel.frame = CGRect(
            x: 8, y: 8, width: max(1, stacked ? width - 28 : editX - 8),
            height: max(0, stacked ? actionY - 8 : contentView.bounds.height - 16))
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            for item in [groupLabel, editButton, deleteButton] {
                item.frame.origin.x = width - item.frame.maxX
            }
        }
    }

    private static func actionWidths(font: UIFont) -> (edit: CGFloat, delete: CGFloat) {
        (
            ceil((L10n.Common.edit as NSString).size(withAttributes: [.font: font]).width) + 16,
            ceil((L10n.Common.delete as NSString).size(withAttributes: [.font: font]).width) + 16
        )
    }

    private static func actionHeight(font: UIFont, width: CGFloat) -> CGFloat {
        let actions = actionWidths(font: font)
        let space = max(1, width - 28)
        let total = actions.edit + actions.delete
        let editWidth = min(actions.edit, space * actions.edit / max(1, total))
        let deleteWidth = min(actions.delete, max(1, space - editWidth))
        func textHeight(_ text: String, width: CGFloat) -> CGFloat {
            ceil(
                (text as NSString).boundingRect(
                    with: CGSize(width: max(1, width - 16), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
                ).height)
        }
        return max(textHeight(L10n.Common.edit, width: editWidth), textHeight(L10n.Common.delete, width: deleteWidth))
            + 16
    }

    @objc private func editTapped() {
        guard editButton.isEnabled else { return }
        onEdit?()
    }
    @objc private func deleteTapped() {
        guard deleteButton.isEnabled else { return }
        onDelete?()
    }
}

final class BookSourceGroupManagementScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
