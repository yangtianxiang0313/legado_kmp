import Kingfisher
import UIKit

final class AndroidReplicaLoadMoreCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaLoadMoreCell"
    private let titleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .default
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = AndroidReplicaTheme.secondaryText
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(title: String) {
        titleLabel.text = title
    }
}

final class AndroidReplicaBookResultCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaBookResultCell"
    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let tertiaryLabel = UILabel()
    private let tagLabel = UILabel()
    private let dividerView = UIView()
    private let placeholderImage = UIImage(systemName: "book.closed")
    var onActivate: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = placeholderImage
        titleLabel.text = nil
        subtitleLabel.text = nil
        tertiaryLabel.text = nil
        tagLabel.text = nil
        tagLabel.isHidden = true
        onActivate = nil
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectedBackgroundView = {
            let view = UIView()
            view.backgroundColor = AndroidReplicaTheme.activeIndicator
            return view
        }()
        selectionStyle = .default
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerRadius = 4
        coverImageView.backgroundColor = AndroidReplicaTheme.coverBackground
        coverImageView.tintColor = AndroidReplicaTheme.secondaryText
        coverImageView.image = placeholderImage

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 2

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = AndroidReplicaTheme.secondaryText
        subtitleLabel.numberOfLines = 1

        tertiaryLabel.font = .systemFont(ofSize: 12)
        tertiaryLabel.textColor = AndroidReplicaTheme.secondaryText
        tertiaryLabel.numberOfLines = 2

        tagLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tagLabel.textColor = AndroidReplicaTheme.accent
        tagLabel.backgroundColor = AndroidReplicaTheme.activeIndicator
        tagLabel.layer.cornerRadius = 8
        tagLabel.layer.masksToBounds = true
        tagLabel.textAlignment = .center
        tagLabel.isHidden = true

        dividerView.backgroundColor = AndroidReplicaTheme.divider

        for item in [coverImageView, titleLabel, subtitleLabel, tertiaryLabel, tagLabel, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        NSLayoutConstraint.activate([
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            coverImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            coverImageView.widthAnchor.constraint(equalToConstant: 52),
            coverImageView.heightAnchor.constraint(equalToConstant: 70),
            coverImageView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(equalTo: coverImageView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: coverImageView.topAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            tagLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tagLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 6),
            tagLabel.heightAnchor.constraint(equalToConstant: 20),
            tagLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),

            tertiaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tertiaryLabel.topAnchor.constraint(equalTo: tagLabel.bottomAnchor, constant: 6),
            tertiaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            tertiaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),

            dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    func configure(title: String, subtitle: String?, tertiary: String?, coverURL: String?, tag: String? = nil) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        tertiaryLabel.text = tertiary?.replacingOccurrences(of: "\n", with: " ")
        tertiaryLabel.isHidden = tertiaryLabel.text?.isEmpty != false
        tagLabel.text = "  \(tag ?? "")  "
        tagLabel.isHidden = tag?.isEmpty != false
        accessibilityLabel = title
        accessibilityValue = [subtitle, tertiary].compactMap { $0 }.joined(separator: ", ")

        guard let coverURL, let url = URL(string: coverURL) else {
            coverImageView.image = placeholderImage
            return
        }
        coverImageView.kf.setImage(with: url, placeholder: placeholderImage, options: [.transition(.fade(0.2)), .cacheOriginalImage])
    }
}

final class AndroidReplicaRssArticleCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaRssArticleCell"
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let dividerView = UIView()

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
        selectedBackgroundView = {
            let view = UIView()
            view.backgroundColor = AndroidReplicaTheme.activeIndicator
            return view
        }()
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 2
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.numberOfLines = 2
        chevronView.tintColor = AndroidReplicaTheme.secondaryText
        dividerView.backgroundColor = AndroidReplicaTheme.divider

        for item in [titleLabel, detailLabel, chevronView, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -16),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),

            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 18),

            dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    func configure(title: String, detail: String?) {
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail?.isEmpty != false
        accessibilityLabel = title
        accessibilityValue = detail
    }
}
