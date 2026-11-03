import UIKit

@MainActor
final class RssArticleWideCell: UITableViewCell {
    static let reuseIdentifier = "RssArticleWideCell"
    let articleView = RssArticleMediaView()

    override var accessibilityLabel: String? {
        get { super.accessibilityLabel ?? articleView.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        selectionStyle = .default
        accessoryType = .none
        editingAccessoryType = .none
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        let selectionView = UIView()
        selectionView.backgroundColor = AndroidReplicaTheme.activeIndicator
        selectedBackgroundView = selectionView

        articleView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(articleView)
        NSLayoutConstraint.activate([
            articleView.topAnchor.constraint(equalTo: contentView.topAnchor),
            articleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            articleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            articleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let size = articleView.systemLayoutSizeFitting(
            targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority)
        let scale = max(traitCollection.displayScale, 1)
        return CGSize(width: size.width, height: ceil(size.height * scale) / scale)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        articleView.prepareForReuse()
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityCustomActions = nil
        accessibilityTraits = [.button]
    }
}
