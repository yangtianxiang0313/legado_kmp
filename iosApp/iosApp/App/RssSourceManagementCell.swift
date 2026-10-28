import shared
import UIKit

final class RssSourceManagementCell: UITableViewCell {
    static let reuseIdentifier = "RssSourceManagementCell"
    private let selectionButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let enabledSwitch = UISwitch()
    private let editButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let dividerView = UIView()
    private let controls = UIStackView()
    private var selectionWidth: NSLayoutConstraint!
    private var controlsWidth: NSLayoutConstraint!
    var onSelection: (() -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onEdit: (() -> Void)?
    var onMore: ((UIView?) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none
        nameLabel.font = .systemFont(ofSize: 16)
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.numberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.numberOfLines = 2
        selectionButton.tintColor = AndroidReplicaTheme.accent
        selectionButton.addTarget(self, action: #selector(handleSelection), for: .touchUpInside)
        editButton.setImage(UIImage(systemName: "pencil"), for: .normal)
        editButton.tintColor = AndroidReplicaTheme.primaryText
        editButton.accessibilityLabel = "编辑订阅源"
        editButton.addTarget(self, action: #selector(handleEdit), for: .touchUpInside)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.primaryText
        moreButton.accessibilityLabel = "订阅源操作"
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
        enabledSwitch.addTarget(self, action: #selector(enabledChanged), for: .valueChanged)
        enabledSwitch.onTintColor = AndroidReplicaTheme.accent
        dividerView.backgroundColor = AndroidReplicaTheme.divider
        controls.alignment = .center
        controls.spacing = 4
        [enabledSwitch, editButton, moreButton].forEach { controls.addArrangedSubview($0) }
        for item in [selectionButton, nameLabel, detailLabel, controls, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        selectionWidth = selectionButton.widthAnchor.constraint(equalToConstant: 0)
        controlsWidth = controls.widthAnchor.constraint(equalToConstant: 155)
        let editWidth = editButton.widthAnchor.constraint(equalToConstant: 44)
        let moreWidth = moreButton.widthAnchor.constraint(equalToConstant: 44)
        editWidth.priority = .defaultHigh
        moreWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            selectionButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            selectionButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            selectionButton.heightAnchor.constraint(equalToConstant: 48),
            selectionWidth,
            nameLabel.leadingAnchor.constraint(equalTo: selectionButton.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            controlsWidth,
            editWidth,
            editButton.heightAnchor.constraint(equalToConstant: 48),
            moreWidth,
            moreButton.heightAnchor.constraint(equalToConstant: 48),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            dividerView.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSelection = nil
        onEnabledChange = nil
        onEdit = nil
        onMore = nil
    }

    func configure(source: RssSource, selecting: Bool, selected: Bool, busy: Bool) {
        let group = source.sourceGroup?.nilIfEmpty
        let state = source.enabled ? L10n.RSS.sourceManagementEnabledBadge : L10n.RSS.sourceManagementDisabledBadge
        nameLabel.text = source.sourceName
        detailLabel.text = "\([group, state].compactMap { $0 }.joined(separator: " · "))\n\(source.sourceUrl)"
        nameLabel.textColor = source.enabled ? AndroidReplicaTheme.primaryText : AndroidReplicaTheme.secondaryText
        enabledSwitch.setOn(source.enabled, animated: false)
        enabledSwitch.isEnabled = !busy && !selecting
        enabledSwitch.accessibilityLabel = source.sourceName
        editButton.isEnabled = !busy
        moreButton.isEnabled = !busy
        selectionButton.isHidden = !selecting
        selectionButton.isEnabled = !busy
        selectionButton.setImage(UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"), for: .normal)
        selectionButton.accessibilityLabel = "\(selected ? "取消选择" : "选择") \(source.sourceName)"
        selectionButton.accessibilityIdentifier = "rss.sourceManagement.selectSource"
        selectionWidth.constant = selecting ? 36 : 0
        // Hiding arranged controls also removes their intrinsic widths in selection mode.
        controls.arrangedSubviews.forEach { $0.isHidden = selecting }
        controlsWidth.constant = selecting ? 0 : 155
        accessibilityValue = selecting ? (selected ? "已选择" : "未选择") : state
    }

    @objc private func handleSelection() { onSelection?() }
    @objc private func enabledChanged() { onEnabledChange?(enabledSwitch.isOn) }
    @objc private func handleEdit() { onEdit?() }
    @objc private func handleMore() { onMore?(moreButton) }
}
