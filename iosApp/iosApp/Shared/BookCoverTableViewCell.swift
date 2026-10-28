import UIKit
import Kingfisher
import SnapKit
import Then

final class BookCoverTableViewCell: UITableViewCell {
    static let reuseIdentifier = "BookCoverTableViewCell"

    private let placeholderImage = UIImage(systemName: "book.closed")
    var onActivate: (() -> Void)?

    private let coverImageView = UIImageView().then {
        $0.contentMode = .scaleAspectFill
        $0.clipsToBounds = true
        $0.layer.cornerRadius = 10
        $0.backgroundColor = .secondarySystemBackground
        $0.tintColor = .tertiaryLabel
    }

    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .headline)
        $0.textColor = .label
        $0.numberOfLines = 2
    }

    private let subtitleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 2
    }

    private let tertiaryLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.textColor = .tertiaryLabel
        $0.numberOfLines = 2
    }

    private let kindLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption1)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 1
        $0.isHidden = true
    }

    private let introLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption2)
        $0.textColor = .tertiaryLabel
        $0.numberOfLines = 2
        $0.isHidden = true
    }

    private let bookshelfDotView = UIView().then {
        $0.backgroundColor = .systemGreen
        $0.layer.cornerRadius = 4
        $0.isHidden = true
        $0.isAccessibilityElement = false
    }

    private let badgeLabel = UILabel().then {
        $0.font = .systemFont(ofSize: 11, weight: .semibold)
        $0.textColor = .white
        $0.backgroundColor = .systemRed
        $0.textAlignment = .center
        $0.clipsToBounds = true
        $0.layer.cornerRadius = 10
        $0.isHidden = true
        $0.isAccessibilityElement = false
    }

    private let textStack = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 6
        $0.alignment = .fill
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        accessoryType = .disclosureIndicator
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        shouldGroupAccessibilityChildren = true
        coverImageView.isAccessibilityElement = false
        titleLabel.isAccessibilityElement = false
        subtitleLabel.isAccessibilityElement = false
        tertiaryLabel.isAccessibilityElement = false

        contentView.addSubview(coverImageView)
        contentView.addSubview(textStack)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.addArrangedSubview(kindLabel)
        textStack.addArrangedSubview(tertiaryLabel)
        textStack.addArrangedSubview(introLabel)

        coverImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(AppUI.Spacing.medium)
            make.verticalEdges.equalToSuperview().inset(10)
            make.width.equalTo(54)
            make.height.equalTo(72)
        }

        textStack.snp.makeConstraints { make in
            make.leading.equalTo(coverImageView.snp.trailing).offset(AppUI.Spacing.small)
            make.trailing.equalToSuperview().inset(AppUI.Spacing.medium)
            make.centerY.equalToSuperview()
        }

        contentView.addSubview(badgeLabel)
        badgeLabel.snp.makeConstraints { make in
            make.top.equalTo(coverImageView).offset(-4)
            make.trailing.equalTo(coverImageView).offset(4)
            make.height.equalTo(20)
            make.width.greaterThanOrEqualTo(20)
        }

        contentView.addSubview(bookshelfDotView)
        bookshelfDotView.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.leading).offset(-12)
            make.centerY.equalTo(titleLabel)
            make.width.height.equalTo(8)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = placeholderImage
        titleLabel.text = nil
        subtitleLabel.text = nil
        tertiaryLabel.text = nil
        kindLabel.text = nil
        kindLabel.isHidden = true
        introLabel.text = nil
        introLabel.isHidden = true
        onActivate = nil
        accessibilityHint = nil
        accessibilityValue = nil
        badgeLabel.isHidden = true
        badgeLabel.text = nil
        bookshelfDotView.isHidden = true
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else {
            return super.accessibilityActivate()
        }
        onActivate()
        return true
    }

    func configure(
        title: String,
        subtitle: String?,
        tertiary: String?,
        coverURL: String?,
        kind: String? = nil,
        intro: String? = nil,
        isInBookshelf: Bool = false
    ) {
        bookshelfDotView.isHidden = !isInBookshelf
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        tertiaryLabel.text = tertiary
        tertiaryLabel.isHidden = tertiary?.isEmpty != false
        let kindTags = kind?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let kindTags, !kindTags.isEmpty {
            kindLabel.text = kindTags.joined(separator: " · ")
            kindLabel.isHidden = false
        } else {
            kindLabel.isHidden = true
        }
        let trimmedIntro = intro?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedIntro, !trimmedIntro.isEmpty {
            introLabel.text = trimmedIntro
            introLabel.isHidden = false
        } else {
            introLabel.isHidden = true
        }
        accessibilityLabel = title
        accessibilityValue = [subtitle, tertiary]
            .compactMap { value -> String? in
                guard let value, value.isEmpty == false else { return nil }
                return value
            }
            .joined(separator: ", ")
        accessibilityHint = L10n.Bookshelf.openDetailHint

        guard let coverURL, let url = URL(string: coverURL) else {
            coverImageView.image = placeholderImage
            return
        }

        coverImageView.kf.setImage(
            with: url,
            placeholder: placeholderImage,
            options: [
                .transition(.fade(0.2)),
                .cacheOriginalImage,
            ]
        )
    }

    func setBadgeCount(_ count: Int) {
        if count > 1 {
            badgeLabel.text = "\(count)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }
}
