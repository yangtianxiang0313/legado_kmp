import UIKit

@MainActor
final class RssArticleGridCell: UICollectionViewCell {
    static let reuseIdentifier = "RssArticleGridCell"
    let articleView = RssArticleMediaView()

    override var accessibilityLabel: String? {
        get { super.accessibilityLabel ?? articleView.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
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
