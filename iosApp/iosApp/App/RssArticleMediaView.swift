import UIKit
import shared

@MainActor
final class RssArticleMediaView: UIView {
    var onSizeChange: (() -> Void)?
    private(set) var representedArticle: RssArticle?

    private let imageBlock = UIView()
    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let dividerView = UIView()
    private var imageBlockHeight: NSLayoutConstraint!
    private var imageTop: NSLayoutConstraint!
    private var imageLeading: NSLayoutConstraint!
    private var imageTrailing: NSLayoutConstraint!
    private var titleSpacing: NSLayoutConstraint!
    private var dateSpacing: NSLayoutConstraint!
    private var bottomSpacing: NSLayoutConstraint!
    private var dividerHeight: NSLayoutConstraint!
    private var minimumTitleHeight: NSLayoutConstraint!
    private var minimumDateHeight: NSLayoutConstraint!

    private var layoutStyle = RssArticlePresentationStyle.largeImage
    private var loadedImage: UIImage?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailGeneration = UUID()
    private var thumbnailLoadingEnabled = false
    private var activePixelSize = 0
    private var completedPixelSize = 0
    private var sizeNotificationGeneration = UUID()
    private var sizeNotificationPending = false
    private static let gridPlaceholder = UIImage(named: "RssArticlePlaceholder")

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        thumbnailTask?.cancel()
    }

    func configure(article: RssArticle, style: RssArticlePresentationStyle, isRead: Bool) {
        cancelThumbnailLoading()
        invalidateSizeNotification()
        representedArticle = article
        layoutStyle = style
        loadedImage = nil
        completedPixelSize = 0
        titleLabel.text = article.title
        dateLabel.text = article.pubDate
        accessibilityLabel = [article.title, article.pubDate ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityCustomActions = nil
        updateReadState(isRead)
        updateTypography()
        updateGeometry()
        updateWrappingWidth(bounds.width)
        scheduleSizeChange()
    }

    func resumeThumbnailLoading() {
        thumbnailLoadingEnabled = true
        requestThumbnailIfNeeded()
        setNeedsLayout()
    }

    func cancelThumbnailLoading() {
        thumbnailLoadingEnabled = false
        cancelCurrentRequest()
    }

    func prepareForReuse() {
        cancelThumbnailLoading()
        invalidateSizeNotification()
        onSizeChange = nil
        representedArticle = nil
        loadedImage = nil
        completedPixelSize = 0
        layoutStyle = .largeImage
        titleLabel.text = nil
        dateLabel.text = nil
        titleLabel.preferredMaxLayoutWidth = 0
        dateLabel.preferredMaxLayoutWidth = 0
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityCustomActions = nil
        updateReadState(false)
        updateTypography()
        updateGeometry()
    }

    func updateReadState(_ isRead: Bool) {
        titleLabel.textColor = isRead ? AndroidReplicaTheme.summaryText : AndroidReplicaTheme.primaryText
    }

    static func preferredGridHeight(article: RssArticle, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let metrics = LayoutMetrics(style: .grid)
        let typography = Typography(style: .grid, traits: traits)
        let textWidth = max(width - 2 * metrics.sideInset, 1)
        let titleHeight = textHeight(
            article.title, width: textWidth, font: typography.titleFont,
            lines: typography.titleLines, lineBreakMode: typography.lineBreakMode)
        let dateHeight = textHeight(
            article.pubDate, width: textWidth, font: typography.dateFont,
            lines: typography.dateLines, lineBreakMode: typography.lineBreakMode)
        let height =
            metrics.imageTopInset + metrics.imageHeight + metrics.titleSpacing
            + titleHeight + metrics.dateSpacing + dateHeight + metrics.bottomSpacing
        let scale = max(traits.displayScale, 1)
        return ceil(height * scale) / scale
    }

    override func layoutSubviews() {
        let wrappingChanged = updateWrappingWidth(bounds.width)
        super.layoutSubviews()
        if wrappingChanged { scheduleSizeChange() }
        requestThumbnailIfNeeded()
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        updateWrappingWidth(targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateImageBorder()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
            updateWrappingWidth(bounds.width)
            scheduleSizeChange()
        }
        requestThumbnailIfNeeded()
    }

    private func configureViews() {
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        dividerView.backgroundColor = AndroidReplicaTheme.divider
        dateLabel.textColor = AndroidReplicaTheme.secondaryText

        for label in [titleLabel, dateLabel] {
            label.textAlignment = .natural
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        for view in [imageBlock, titleLabel, dateLabel, dividerView] {
            view.isAccessibilityElement = false
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        thumbnailView.isAccessibilityElement = false
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        imageBlock.addSubview(thumbnailView)

        imageBlockHeight = imageBlock.heightAnchor.constraint(equalToConstant: 0)
        imageBlockHeight.priority = UILayoutPriority(999)
        imageTop = thumbnailView.topAnchor.constraint(equalTo: imageBlock.topAnchor)
        imageLeading = thumbnailView.leadingAnchor.constraint(equalTo: imageBlock.leadingAnchor)
        imageTrailing = thumbnailView.trailingAnchor.constraint(equalTo: imageBlock.trailingAnchor)
        titleSpacing = titleLabel.topAnchor.constraint(equalTo: imageBlock.bottomAnchor)
        dateSpacing = dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor)
        bottomSpacing = dividerView.topAnchor.constraint(equalTo: dateLabel.bottomAnchor)
        dividerHeight = dividerView.heightAnchor.constraint(equalToConstant: 0)
        minimumTitleHeight = titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minimumDateHeight = dateLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([
            imageBlock.topAnchor.constraint(equalTo: topAnchor),
            imageBlock.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageBlock.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageBlockHeight,
            imageTop,
            imageLeading,
            imageTrailing,
            thumbnailView.bottomAnchor.constraint(equalTo: imageBlock.bottomAnchor),
            titleSpacing,
            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            minimumTitleHeight,
            dateSpacing,
            dateLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            minimumDateHeight,
            bottomSpacing,
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerHeight,
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateReadState(false)
        updateTypography()
        updateGeometry()
    }

    private func updateTypography() {
        let typography = Typography(style: layoutStyle, traits: traitCollection)
        Self.applyTypography(
            to: titleLabel, font: typography.titleFont, lines: typography.titleLines,
            lineBreakMode: typography.lineBreakMode)
        Self.applyTypography(
            to: dateLabel, font: typography.dateFont, lines: typography.dateLines,
            lineBreakMode: typography.lineBreakMode)
        minimumTitleHeight.constant = typography.titleFont.lineHeight
        minimumDateHeight.constant = typography.dateFont.lineHeight
        setNeedsLayout()
    }

    private func updateGeometry() {
        let metrics = LayoutMetrics(style: layoutStyle)
        imageLeading.constant = metrics.sideInset
        imageTrailing.constant = -metrics.sideInset
        titleSpacing.constant = metrics.titleSpacing
        dateSpacing.constant = metrics.dateSpacing
        bottomSpacing.constant = metrics.bottomSpacing
        dividerHeight.constant = metrics.dividerHeight
        dividerView.isHidden = layoutStyle == .grid
        updateImageBorder()
        updateMediaPresentation(notifySizeChange: false)
    }

    private func updateImageBorder() {
        let isGrid = layoutStyle == .grid
        thumbnailView.backgroundColor = isGrid ? AndroidReplicaTheme.background : .clear
        thumbnailView.layer.borderWidth = isGrid ? 1 : 0
        thumbnailView.layer.cornerRadius = isGrid ? 1 : 0
        thumbnailView.layer.borderColor = AndroidReplicaTheme.divider.resolvedColor(with: traitCollection).cgColor
    }

    private func updateMediaPresentation(notifySizeChange: Bool) {
        let metrics = LayoutMetrics(style: layoutStyle)
        let hasImageBlock = layoutStyle == .grid || (layoutStyle == .largeImage && loadedImage != nil)
        let previousHeight = imageBlockHeight.constant
        imageBlockHeight.constant = hasImageBlock ? metrics.imageTopInset + metrics.imageHeight : 0
        imageTop.constant = hasImageBlock ? metrics.imageTopInset : 0
        imageBlock.isHidden = !hasImageBlock
        thumbnailView.image = loadedImage ?? (layoutStyle == .grid ? Self.gridPlaceholder : nil)
        setNeedsLayout()
        if notifySizeChange, previousHeight != imageBlockHeight.constant {
            scheduleSizeChange()
        }
    }

    @discardableResult
    private func updateWrappingWidth(_ width: CGFloat) -> Bool {
        let textWidth = width - 2 * LayoutMetrics(style: layoutStyle).sideInset
        guard textWidth.isFinite, textWidth > 0,
            titleLabel.preferredMaxLayoutWidth != textWidth
                || dateLabel.preferredMaxLayoutWidth != textWidth
        else { return false }
        titleLabel.preferredMaxLayoutWidth = textWidth
        dateLabel.preferredMaxLayoutWidth = textWidth
        return true
    }

    private func scheduleSizeChange() {
        guard representedArticle != nil, !sizeNotificationPending else { return }
        sizeNotificationPending = true
        let generation = sizeNotificationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sizeNotificationGeneration == generation else { return }
            self.sizeNotificationPending = false
            self.onSizeChange?()
        }
    }

    private func invalidateSizeNotification() {
        sizeNotificationGeneration = UUID()
        sizeNotificationPending = false
    }

    private func cancelCurrentRequest() {
        thumbnailGeneration = UUID()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        activePixelSize = 0
    }

    private func requestThumbnailIfNeeded() {
        guard thumbnailLoadingEnabled, layoutStyle != .compact,
            let article = representedArticle,
            RssArticleThumbnailLoader.hasNonBlankImage(article.image),
            let pixelSize = preferredThumbnailPixelSize(), pixelSize > completedPixelSize
        else { return }
        if thumbnailTask != nil, pixelSize <= activePixelSize { return }

        cancelCurrentRequest()
        let generation = thumbnailGeneration
        activePixelSize = pixelSize
        thumbnailTask = Task { @MainActor [weak self] in
            do {
                let image = try await RssArticleThumbnailLoader.loadImage(
                    article: article, maximumPixelSize: pixelSize)
                try Task.checkCancellation()
                self?.finishThumbnailLoad(image, pixelSize: pixelSize, generation: generation)
            } catch is CancellationError {
                guard let self, self.thumbnailGeneration == generation else { return }
                self.thumbnailTask = nil
                self.activePixelSize = 0
            } catch {
                self?.finishThumbnailLoad(nil, pixelSize: pixelSize, generation: generation)
            }
        }
    }

    private func finishThumbnailLoad(_ image: UIImage?, pixelSize: Int, generation: UUID) {
        guard thumbnailLoadingEnabled, thumbnailGeneration == generation else { return }
        thumbnailTask = nil
        activePixelSize = 0
        completedPixelSize = max(completedPixelSize, pixelSize)
        // A failed resolution upgrade must not discard an already displayed real image.
        if let image { loadedImage = image }
        updateMediaPresentation(notifySizeChange: true)
        requestThumbnailIfNeeded()
    }

    private func preferredThumbnailPixelSize() -> Int? {
        let metrics = LayoutMetrics(style: layoutStyle)
        let width = bounds.width - 2 * metrics.sideInset
        guard width.isFinite, width > 0 else { return nil }
        let height = metrics.imageHeight
        let scale = max(traitCollection.displayScale, 1)
        var pixels = max(width, height) * scale
        if let image = loadedImage, image.size.width > 0, image.size.height > 0 {
            // Account for center-crop: the shorter source edge must also fill the view.
            let fillScale = max(width / image.size.width, height / image.size.height)
            pixels = max(pixels, max(image.size.width, image.size.height) * fillScale * scale)
        }
        return Int(min(max(ceil(pixels), 330), 2048))
    }

    private static func applyTypography(
        to label: UILabel, font: UIFont, lines: Int, lineBreakMode: NSLineBreakMode
    ) {
        label.font = font
        label.numberOfLines = lines
        label.lineBreakMode = lineBreakMode
    }

    private static func textHeight(
        _ text: String?, width: CGFloat, font: UIFont, lines: Int, lineBreakMode: NSLineBreakMode
    ) -> CGFloat {
        let label = UILabel()
        applyTypography(to: label, font: font, lines: lines, lineBreakMode: lineBreakMode)
        label.text = text
        label.preferredMaxLayoutWidth = width
        return max(font.lineHeight, label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private struct Typography {
        let titleFont: UIFont
        let dateFont: UIFont
        let titleLines: Int
        let dateLines: Int
        let lineBreakMode: NSLineBreakMode

        init(style: RssArticlePresentationStyle, traits: UITraitCollection) {
            let isGrid = style == .grid
            titleFont = UIFontMetrics(forTextStyle: isGrid ? .body : .headline).scaledFont(
                for: .systemFont(ofSize: isGrid ? 13 : 15, weight: isGrid ? .regular : .bold),
                compatibleWith: traits)
            dateFont = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .systemFont(ofSize: 11, weight: .regular), compatibleWith: traits)
            let expandsText = traits.preferredContentSizeCategory.isAccessibilityCategory
            titleLines = expandsText ? 0 : 2
            dateLines = expandsText ? 0 : 1
            lineBreakMode = expandsText ? .byWordWrapping : .byTruncatingTail
        }
    }

    private struct LayoutMetrics {
        let sideInset: CGFloat
        let imageTopInset: CGFloat
        let imageHeight: CGFloat
        let titleSpacing: CGFloat
        let dateSpacing: CGFloat
        let bottomSpacing: CGFloat
        let dividerHeight: CGFloat

        init(style: RssArticlePresentationStyle) {
            let isGrid = style == .grid
            sideInset = isGrid ? 4 : 12
            imageTopInset = isGrid ? 8 : 12
            imageHeight = isGrid ? 272 : 208
            titleSpacing = isGrid ? 10 : 12
            dateSpacing = isGrid ? 8 : 10
            bottomSpacing = isGrid ? 8 : 12
            dividerHeight = isGrid ? 0 : 8
        }
    }
}
