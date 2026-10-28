import shared
import UIKit

class AndroidReplicaBaseListCell: UITableViewCell {
    let iconContainer = UIView()
    let iconView = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    let dividerView = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        let selectedView = UIView()
        selectedView.backgroundColor = AndroidReplicaTheme.activeIndicator
        selectedBackgroundView = selectedView

        iconContainer.backgroundColor = AndroidReplicaTheme.menuBackground
        iconContainer.layer.cornerRadius = 18
        iconContainer.layer.cornerCurve = .continuous

        iconView.tintColor = AndroidReplicaTheme.primaryText
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.numberOfLines = 1

        chevronView.tintColor = AndroidReplicaTheme.secondaryText
        chevronView.contentMode = .scaleAspectFit

        dividerView.backgroundColor = AndroidReplicaTheme.divider

        for item in [iconContainer, titleLabel, detailLabel, chevronView, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 36),
            iconContainer.heightAnchor.constraint(equalToConstant: 36),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 15),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }
}

final class AndroidReplicaMyCell: AndroidReplicaBaseListCell {
    static let reuseIdentifier = "AndroidReplicaMyCell"

    func configure(title: String, detail: String, iconName: String) {
        titleLabel.text = title
        detailLabel.text = detail
        iconView.image = UIImage(systemName: iconName)
    }
}

final class AndroidReplicaExploreCell: AndroidReplicaBaseListCell {
    static let reuseIdentifier = "AndroidReplicaExploreCell"

    func configure(source: BookSourcePart) {
        titleLabel.text = source.bookSourceName
        detailLabel.text = [source.bookSourceGroup, source.bookSourceUrl].compactMap { value in
            guard let value, value.isEmpty == false else { return nil }
            return value
        }.joined(separator: "  ")
        iconView.image = UIImage(systemName: "tag")
    }
}

final class AndroidReplicaRssCell: UICollectionViewCell {
    static let reuseIdentifier = "AndroidReplicaRssCell"
    private let iconView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.tintColor = AndroidReplicaTheme.primaryText
        iconView.backgroundColor = AndroidReplicaTheme.coverBackground
        iconView.contentMode = .center
        iconView.layer.cornerRadius = 25
        iconView.clipsToBounds = true
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        for item in [iconView, nameLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 50),
            iconView.heightAnchor.constraint(equalToConstant: 50),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(source: RssSource) {
        nameLabel.text = source.sourceName
        iconView.image = UIImage(systemName: "dot.radiowaves.left.and.right")
    }
}
