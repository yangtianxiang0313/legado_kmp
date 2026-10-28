import UIKit
import Kingfisher
import SnapKit
import Then
import shared

final class BookCoverCollectionViewCell: UICollectionViewCell {
    static let reuseIdentifier = "BookCoverCollectionViewCell"

    private let placeholderImage = UIImage(systemName: "book.closed")
    private let unreadBadgeLabel = PaddingLabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private let containerView = UIView().then {
        $0.backgroundColor = .secondarySystemBackground
        $0.layer.cornerRadius = 14
        $0.layer.cornerCurve = .continuous
    }

    private let coverImageView = UIImageView().then {
        $0.contentMode = .scaleAspectFill
        $0.clipsToBounds = true
        $0.layer.cornerRadius = 10
        $0.backgroundColor = .tertiarySystemBackground
        $0.tintColor = .tertiaryLabel
    }

    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.numberOfLines = 2
        $0.textColor = .label
    }

    private let authorIcon = UIImageView().then {
        $0.image = UIImage(systemName: "person")
        $0.tintColor = .tertiaryLabel
        $0.contentMode = .scaleAspectFit
        $0.snp.makeConstraints { $0.width.height.equalTo(14) }
    }

    private let authorLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.numberOfLines = 1
        $0.textColor = .secondaryLabel
    }

    private let latestUpdateTimeLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.numberOfLines = 1
        $0.textColor = .secondaryLabel
        $0.textAlignment = .right
    }

    private let progressIcon = UIImageView().then {
        $0.image = UIImage(systemName: "clock")
        $0.tintColor = .tertiaryLabel
        $0.contentMode = .scaleAspectFit
        $0.snp.makeConstraints { $0.width.height.equalTo(14) }
    }

    private let latestIcon = UIImageView().then {
        $0.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        $0.tintColor = .tertiaryLabel
        $0.contentMode = .scaleAspectFit
        $0.snp.makeConstraints { $0.width.height.equalTo(14) }
    }

    private let latestLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.numberOfLines = 2
        $0.textColor = .tertiaryLabel
    }

    private let progressLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption1)
        $0.numberOfLines = 2
        $0.textColor = .secondaryLabel
        $0.accessibilityIdentifier = UIIdentifiers.Bookshelf.bookCellProgress
    }

    private let authorRow = UIStackView().then { $0.axis = .horizontal; $0.spacing = 4; $0.alignment = .center }
    private let progressRow = UIStackView().then { $0.axis = .horizontal; $0.spacing = 4; $0.alignment = .center }
    private let latestRow = UIStackView().then { $0.axis = .horizontal; $0.spacing = 4; $0.alignment = .center }

    private let infoStack = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 4
    }

    private let rootStack = UIStackView().then {
        $0.spacing = 12
        $0.alignment = .top
    }

    private var isShowingGridLayout = false
    private var coverTask: Task<Void, Never>?
    private var coverLoadKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.addSubview(containerView)
        containerView.addSubview(rootStack)
        containerView.addSubview(unreadBadgeLabel)
        rootStack.addArrangedSubview(coverImageView)
        rootStack.addArrangedSubview(infoStack)

        authorRow.addArrangedSubview(authorIcon)
        authorRow.addArrangedSubview(authorLabel)
        authorRow.addArrangedSubview(latestUpdateTimeLabel)
        progressRow.addArrangedSubview(progressIcon)
        progressRow.addArrangedSubview(progressLabel)
        latestRow.addArrangedSubview(latestIcon)
        latestRow.addArrangedSubview(latestLabel)

        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        latestUpdateTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        infoStack.addArrangedSubview(titleLabel)
        infoStack.addArrangedSubview(authorRow)
        infoStack.addArrangedSubview(progressRow)
        infoStack.addArrangedSubview(latestRow)

        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        rootStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(10)
        }

        coverImageView.snp.makeConstraints { make in
            make.width.equalTo(84)
            make.height.equalTo(116)
        }

        unreadBadgeLabel.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview().inset(10)
        }
        unreadBadgeLabel.backgroundColor = tintColor
        unreadBadgeLabel.textColor = .white
        unreadBadgeLabel.font = .preferredFont(forTextStyle: .caption2)
        unreadBadgeLabel.layer.cornerRadius = 9
        unreadBadgeLabel.layer.masksToBounds = true
        unreadBadgeLabel.isHidden = true
        unreadBadgeLabel.contentInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        containerView.addSubview(loadingIndicator)
        loadingIndicator.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview().inset(10)
        }
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .systemBlue
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layoutIfNeeded()
        if isShowingGridLayout {
            let width = min(max(contentView.bounds.width - 12, 52), 82)
            coverImageView.snp.updateConstraints { make in
                make.width.equalTo(width)
                make.height.equalTo(width * 1.4)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverTask?.cancel()
        coverTask = nil
        coverLoadKey = nil
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = placeholderImage
        titleLabel.text = nil
        authorLabel.text = nil
        latestUpdateTimeLabel.text = nil
        latestUpdateTimeLabel.isHidden = true
        latestLabel.text = nil
        progressLabel.text = nil
        unreadBadgeLabel.text = nil
        unreadBadgeLabel.isHidden = true
        unreadBadgeLabel.backgroundColor = tintColor
        unreadBadgeLabel.font = .preferredFont(forTextStyle: .caption2)
        loadingIndicator.stopAnimating()
    }

    func configure(book: Book, layoutMode: BookshelfLayoutMode, preferences: AppUiPreferences? = nil, isUpdating: Bool = false) {
        let isGrid = layoutMode.isGrid
        isShowingGridLayout = isGrid
        rootStack.axis = isGrid ? .vertical : .horizontal
        rootStack.alignment = isGrid ? .fill : .top
        rootStack.spacing = isGrid ? 6 : 12
        infoStack.spacing = isGrid ? 2 : 3

        rootStack.snp.remakeConstraints { make in
            make.edges.equalToSuperview().inset(isGrid ? 6 : 10)
        }

        // U4: list items have no card background (legacy-aligned)
        containerView.backgroundColor = .clear
        containerView.layer.cornerRadius = 0
        coverImageView.layer.cornerRadius = isGrid ? 6 : 10

        coverImageView.snp.remakeConstraints { make in
            if isGrid {
                let width = min(max(contentView.bounds.width - 12, 52), 82)
                make.width.equalTo(width)
                make.height.equalTo(width * 1.4)
            } else {
                make.width.equalTo(66)
                make.height.equalTo(90)
            }
        }

        titleLabel.font = isGrid ? .systemFont(ofSize: 12, weight: .regular) : .preferredFont(forTextStyle: .subheadline)
        titleLabel.numberOfLines = isGrid ? 2 : 1
        titleLabel.textAlignment = isGrid ? .center : .left
        titleLabel.text = book.name
        progressLabel.numberOfLines = isGrid ? 2 : 1
        latestLabel.numberOfLines = isGrid ? 2 : 1

        let showUnread = preferences?.showUnread ?? true
        let showLastUpdateTime = preferences?.showLastUpdateTime ?? false

        // U3: row icons visible in list mode only
        authorIcon.isHidden = isGrid
        progressIcon.isHidden = isGrid
        latestIcon.isHidden = isGrid

        // U6: grid mode only shows cover + title (no author/progress/latest)
        authorRow.isHidden = isGrid
        progressRow.isHidden = isGrid
        latestRow.isHidden = isGrid

        authorLabel.text = book.author.sanitizedDisplayText
        latestUpdateTimeLabel.isHidden = isGrid || !showLastUpdateTime || book.isLocal
        latestUpdateTimeLabel.text = latestUpdateTimeLabel.isHidden ? nil : formattedLatestTime(book.latestChapterTime)
        progressLabel.text = book.durChapterTitle?.sanitizedDisplayText.nilIfEmpty
        accessibilityValue = progressLabel.text
        latestLabel.text = book.latestChapterTitle?.sanitizedDisplayText.nilIfEmpty

        // F16: per-book loading indicator during TOC update
        if isUpdating && !book.isLocal {
            loadingIndicator.startAnimating()
            unreadBadgeLabel.isHidden = true
        } else {
            loadingIndicator.stopAnimating()
        }

        if !isUpdating && showUnread && book.unreadChapterCount > 0 {
            unreadBadgeLabel.text = "\(book.unreadChapterCount)"
            let hasFreshChapters = book.lastCheckCount > 0
            unreadBadgeLabel.backgroundColor = hasFreshChapters ? tintColor : .systemGray
            unreadBadgeLabel.font = hasFreshChapters ? .systemFont(ofSize: 11, weight: .semibold) : .preferredFont(forTextStyle: .caption2)
            unreadBadgeLabel.isHidden = false
        } else {
            unreadBadgeLabel.isHidden = true
        }

        guard let cover = book.displayCoverUrl, let url = URL(string: cover) else {
            coverImageView.image = placeholderImage
            return
        }
        let requestKey = BookCoverImageLoader.coverCacheKey(for: book) as String
        coverLoadKey = requestKey
        coverTask?.cancel()
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = placeholderImage
        coverTask = Task { [weak self] in
            guard let self else { return }
            if let decoded = await BookCoverImageLoader.loadDecodedCover(book: book) {
                await MainActor.run {
                    guard self.coverLoadKey == requestKey else { return }
                    self.coverImageView.image = decoded
                }
                return
            }
            await MainActor.run {
                guard self.coverLoadKey == requestKey else { return }
                self.coverImageView.kf.setImage(
                    with: url,
                    placeholder: self.placeholderImage,
                    options: [
                        .transition(.fade(0.2)),
                        .cacheOriginalImage,
                    ]
                )
            }
        }
    }

    private func formattedLatestTime(_ timestamp: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let seconds = abs(now - timestamp) / 1000
        let suffix = timestamp < now ? "前" : "后"
        let value: Int64
        let unit: String
        switch seconds {
        case ..<60:
            value = seconds
            unit = "秒"
        case ..<3_600:
            value = seconds / 60
            unit = "分钟"
        case ..<86_400:
            value = seconds / 3_600
            unit = "小时"
        case ..<604_800:
            value = seconds / 86_400
            unit = "天"
        case ..<2_628_000:
            value = seconds / 604_800
            unit = "周"
        case ..<31_536_000:
            value = seconds / 2_628_000
            unit = "月"
        default:
            value = seconds / 31_536_000
            unit = "年"
        }
        return "\(value)\(unit)\(suffix)"
    }
}

private final class PaddingLabel: UILabel {
    var contentInsets = UIEdgeInsets.zero

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }
}
