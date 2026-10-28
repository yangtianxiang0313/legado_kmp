import UIKit

final class RssSourceManagementSelectionBar: UIView {
    private let selectAllButton = UIButton(type: .system)
    private let invertButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private let deleteButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    var onSelectAll: (() -> Void)?
    var onInvert: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        configure(selectAllButton, image: "checkmark.circle", title: "全选当前列表", identifier: "selectAll") { [weak self] in
            self?.onSelectAll?()
        }
        configure(invertButton, image: "arrow.triangle.2.circlepath", title: "反选当前列表", identifier: "invertSelection") {
            [weak self] in self?.onInvert?()
        }
        configure(deleteButton, image: "trash", title: "删除所选", identifier: "deleteSelected") { [weak self] in self?.onDelete?() }
        configure(cancelButton, image: "xmark", title: "取消选择", identifier: "cancelSelection") { [weak self] in self?.onCancel?() }
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.toolbarText
        moreButton.accessibilityLabel = "所选订阅源操作"
        moreButton.accessibilityIdentifier = "rss.sourceManagement.selectionActions"
        moreButton.showsMenuAsPrimaryAction = true
        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = AndroidReplicaTheme.toolbarText
        countLabel.textAlignment = .center
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.7
        countLabel.accessibilityIdentifier = "rss.sourceManagement.selectionCount"
        let stack = UIStackView(arrangedSubviews: [
            selectAllButton, invertButton, countLabel, deleteButton, moreButton, cancelButton,
        ])
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 48),
        ])
        for button in [selectAllButton, invertButton, deleteButton, moreButton, cancelButton] {
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func update(selected: Int, allVisibleSelected: Bool, hasVisible: Bool, busy: Bool, menu: UIMenu) {
        countLabel.text = "已选 \(selected) 项"
        selectAllButton.setImage(
            UIImage(systemName: allVisibleSelected ? "checkmark.circle.fill" : "checkmark.circle"), for: .normal)
        selectAllButton.accessibilityLabel = allVisibleSelected ? "取消选择当前列表" : "全选当前列表"
        selectAllButton.isEnabled = !busy && hasVisible
        invertButton.isEnabled = !busy && hasVisible
        deleteButton.isEnabled = !busy && selected > 0
        moreButton.isEnabled = !busy && selected > 0
        cancelButton.isEnabled = !busy
        moreButton.menu = menu
    }

    private func configure(_ button: UIButton, image: String, title: String, identifier: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.accessibilityLabel = title
        button.accessibilityIdentifier = "rss.sourceManagement.\(identifier)"
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
}
