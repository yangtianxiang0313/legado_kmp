import UIKit
import shared

@MainActor
final class AndroidReplicaRssArticleCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaRssArticleCell"

    var onSizeChange: ((AndroidReplicaRssArticleCell) -> Void)?

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let thumbnailView = UIImageView()
    private let dividerView = UIView()
    private var trailingWithoutImage: NSLayoutConstraint!
    private var trailingWithImage: NSLayoutConstraint!
    private var detailSpacing: NSLayoutConstraint!
    private var emptyDetailHeight: NSLayoutConstraint!
    private var thumbnailArticle: RssArticle?
    private var thumbnailIdentity: ThumbnailIdentity?
    private var thumbnailGeneration = UUID()
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailState = ThumbnailState.idle

    private enum ThumbnailState {
        case idle
        case loading
        case finished
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        thumbnailTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailLoading()
        thumbnailArticle = nil
        thumbnailIdentity = nil
        thumbnailState = .idle
        onSizeChange = nil
        accessibilityCustomActions = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        titleLabel.text = nil
        detailLabel.text = nil
        detailLabel.isHidden = true
        emptyDetailHeight.isActive = true
        detailSpacing.constant = 0
        setThumbnail(nil, notifySizeChange: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if updateWrappingWidth() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onSizeChange?(self)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
            onSizeChange?(self)
        }
    }

    func configure(title: String, detail: String?) {
        resetThumbnail(article: nil)
        configureText(title: title, detail: detail, isRead: false)
    }

    func configure(article: RssArticle, isRead: Bool? = nil) {
        resetThumbnail(article: article)
        configureText(title: article.title, detail: article.pubDate, isRead: isRead ?? article.read)
    }

    func configure(favorite: RssStar) {
        configure(article: favorite.toRssArticle(read: false))
    }

    func updateReadState(_ isRead: Bool) {
        titleLabel.textColor = isRead ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
    }

    func cancelThumbnailLoading() {
        thumbnailGeneration = UUID()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        if thumbnailState == .loading {
            thumbnailState = .idle
        }
    }

    func resumeThumbnailLoading() {
        guard thumbnailTask == nil, thumbnailState == .idle, thumbnailView.image == nil,
            let article = thumbnailArticle, let identity = thumbnailIdentity,
            RssArticleThumbnailLoader.hasNonBlankImage(article.image)
        else { return }

        let generation = UUID()
        thumbnailGeneration = generation
        thumbnailState = .loading
        thumbnailTask = Task { @MainActor [weak self] in
            do {
                let image = try await RssArticleThumbnailLoader.loadImage(article: article)
                try Task.checkCancellation()
                guard let self, self.isCurrentThumbnail(identity, generation: generation) else { return }
                self.thumbnailTask = nil
                self.thumbnailState = .finished
                self.setThumbnail(image, notifySizeChange: true)
            } catch is CancellationError {
                guard let self, self.isCurrentThumbnail(identity, generation: generation) else { return }
                self.thumbnailTask = nil
                self.thumbnailState = .idle
            } catch {
                guard let self, self.isCurrentThumbnail(identity, generation: generation) else { return }
                self.thumbnailTask = nil
                self.thumbnailState = .finished
                self.setThumbnail(nil, notifySizeChange: true)
            }
        }
    }

    private func resetThumbnail(article: RssArticle?) {
        cancelThumbnailLoading()
        thumbnailArticle = article
        thumbnailIdentity = article.map(ThumbnailIdentity.init)
        thumbnailState = .idle
        setThumbnail(nil, notifySizeChange: false)
    }

    private func isCurrentThumbnail(_ identity: ThumbnailIdentity, generation: UUID) -> Bool {
        guard thumbnailGeneration == generation, let article = thumbnailArticle else { return false }
        return identity.matches(article)
    }

    private func configureText(title: String, detail: String?, isRead: Bool) {
        accessibilityCustomActions = nil
        titleLabel.text = title
        titleLabel.textColor = isRead ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
        detailLabel.text = detail
        let hasDetail = detail?.isEmpty == false
        detailLabel.isHidden = !hasDetail
        emptyDetailHeight.isActive = !hasDetail
        detailSpacing.constant = hasDetail ? 8 : 0
        accessibilityLabel = title
        accessibilityValue = hasDetail ? detail : nil
        setNeedsLayout()
        onSizeChange?(self)
    }

    private func setThumbnail(_ image: UIImage?, notifySizeChange: Bool) {
        let wasVisible = !thumbnailView.isHidden
        let isVisible = image != nil
        let visibilityChanged = wasVisible != isVisible
        let oldHeight = notifySizeChange && visibilityChanged ? fittingContentHeight() : nil
        thumbnailView.image = image
        guard visibilityChanged else { return }

        thumbnailView.isHidden = !isVisible
        NSLayoutConstraint.deactivate([trailingWithoutImage, trailingWithImage])
        NSLayoutConstraint.activate([isVisible ? trailingWithImage! : trailingWithoutImage!])
        setNeedsLayout()
        // The controller batches table updates only when the new text width changes row height.
        if let oldHeight, let newHeight = fittingContentHeight() {
            let scale = max(traitCollection.displayScale, 1)
            if ceil(oldHeight * scale) != ceil(newHeight * scale) {
                onSizeChange?(self)
            }
        }
    }

    private func fittingContentHeight() -> CGFloat? {
        let width = contentView.bounds.width
        guard width > 0 else { return nil }
        updateWrappingWidth()
        return contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    @discardableResult
    private func updateWrappingWidth() -> Bool {
        let width = contentView.bounds.width - 32 - (thumbnailView.isHidden ? 0 : 110)
        guard width > 0,
            abs(titleLabel.preferredMaxLayoutWidth - width) > 0.1
                || abs(detailLabel.preferredMaxLayoutWidth - width) > 0.1
        else { return false }
        titleLabel.preferredMaxLayoutWidth = width
        detailLabel.preferredMaxLayoutWidth = width
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
        accessoryType = .none
        editingAccessoryType = .none
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        titleLabel.textAlignment = .natural
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.textAlignment = .natural
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.isHidden = true
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.isHidden = true
        thumbnailView.isAccessibilityElement = false
        dividerView.backgroundColor = AndroidReplicaTheme.divider
        for view in [titleLabel, detailLabel, thumbnailView, dividerView] {
            view.isAccessibilityElement = false
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        updateTypography()

        trailingWithoutImage = titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        trailingWithImage = titleLabel.trailingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: -16)
        detailSpacing = detailLabel.topAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor)
        emptyDetailHeight = detailLabel.heightAnchor.constraint(equalToConstant: 0)
        let minimumHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        minimumHeight.priority = UILayoutPriority(999)
        let preferredHeight = contentView.heightAnchor.constraint(equalToConstant: 100)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            minimumHeight,
            preferredHeight,
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            trailingWithoutImage,
            detailSpacing,
            emptyDetailHeight,
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            thumbnailView.widthAnchor.constraint(equalToConstant: 94),
            thumbnailView.heightAnchor.constraint(equalToConstant: 68),
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
    }

    private func updateTypography() {
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 16, weight: .bold), compatibleWith: traitCollection)
        detailLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .italicSystemFont(ofSize: 12), compatibleWith: traitCollection)
        let expandsText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = expandsText ? 0 : 2
        detailLabel.numberOfLines = expandsText ? 0 : 1
        titleLabel.lineBreakMode = expandsText ? .byWordWrapping : .byTruncatingTail
        detailLabel.lineBreakMode = expandsText ? .byWordWrapping : .byTruncatingTail
        setNeedsLayout()
    }

    private struct ThumbnailIdentity {
        let origin: String
        let link: String
        let image: String?
        let variable: String?

        init(_ article: RssArticle) {
            origin = article.origin
            link = article.link
            image = article.image
            variable = article.variable
        }

        func matches(_ article: RssArticle) -> Bool {
            // Match Kotlin's exact UTF-16 strings, not Swift's canonical Unicode equality.
            origin.utf16.elementsEqual(article.origin.utf16)
                && link.utf16.elementsEqual(article.link.utf16)
                && Self.exactlyEqual(image, article.image)
                && Self.exactlyEqual(variable, article.variable)
        }

        private static func exactlyEqual(_ lhs: String?, _ rhs: String?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return lhs.utf16.elementsEqual(rhs.utf16)
            default: return false
            }
        }
    }
}
