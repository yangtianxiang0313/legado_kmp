import Kingfisher
import UIKit
import shared

final class BookshelfFolderGroupCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfFolderGroupCell"

    static func preferredSize(
        width: CGFloat, isGrid: Bool, contentSizeCategory: UIContentSizeCategory
    ) -> CGSize {
        let metrics = LayoutMetrics(contentSizeCategory: contentSizeCategory)
        let height: CGFloat
        if isGrid {
            height =
                16 + max(0, width - 32) * LayoutMetrics.coverAspectRatio + 14 + metrics.gridTitleHeight
        } else {
            height = max(16 + LayoutMetrics.listCoverHeight + 12, 12 + metrics.listTitleHeight + 8)
        }
        return CGSize(width: width, height: ceil(height))
    }

    var onEdit: (() -> Void)? {
        didSet {
            accessibilityCustomActions =
                onEdit == nil
                ? nil
                : [
                    UIAccessibilityCustomAction(
                        name: "编辑分组", target: self, selector: #selector(editFromAccessibility(_:)))
                ]
        }
    }

    private static let defaultCover = UIImage(named: "BookshelfAndroidCoverDefault")?
        .withRenderingMode(.alwaysOriginal)

    private let coverView = UIImageView()
    private let nameLabel = UILabel()
    private let feedbackView = BookshelfItemFeedbackView()
    private var gridConstraints: [NSLayoutConstraint] = []
    private var listConstraints: [NSLayoutConstraint] = []
    private var isGridLayout: Bool?
    private lazy var titleHeightConstraint = nameLabel.heightAnchor.constraint(
        lessThanOrEqualToConstant: 0)
    private var coverTask: DownloadTask?
    private var coverGeneration = UUID()
    private var representedGroupId: Int64?
    private var representedCover: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        contentView.isAccessibilityElement = false

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 2
        coverView.image = Self.defaultCover
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.adjustsFontSizeToFitWidth = false
        for view in [coverView, nameLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleHeightConstraint,
        ])
        gridConstraints = [
            coverView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            coverView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            coverView.heightAnchor.constraint(
                equalTo: coverView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            nameLabel.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ]
        listConstraints = [
            coverView.widthAnchor.constraint(equalToConstant: LayoutMetrics.listCoverWidth),
            coverView.heightAnchor.constraint(
                equalTo: coverView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            coverView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
            coverView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            coverView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.centerYAnchor.constraint(equalTo: coverView.centerYAnchor),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
        ]
        applyLayout(isGrid: true)
        contentView.addSubview(feedbackView)
    }

    override var isHighlighted: Bool {
        didSet { feedbackView.isHidden = !isHighlighted }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        feedbackView.frame = contentView.bounds
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        coverTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelCover()
        representedGroupId = nil
        representedCover = nil
        nameLabel.text = nil
        accessibilityLabel = nil
        accessibilityIdentifier = nil
        onEdit = nil
    }

    func configure(group: BookGroup, isGrid: Bool) {
        let coverChanged = representedGroupId != group.groupId || representedCover != group.cover
        if coverChanged { cancelCover() }
        representedGroupId = group.groupId
        representedCover = group.cover
        nameLabel.text = group.groupName
        accessibilityLabel = group.groupName
        accessibilityIdentifier = "bookshelf.folderGroup.\(group.groupId)"
        applyLayout(isGrid: isGrid)
        if coverChanged { loadCover(group) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        {
            updateTypography()
        }
    }

    private func applyLayout(isGrid: Bool) {
        guard isGridLayout != isGrid else { return }
        if let previousIsGrid = isGridLayout {
            NSLayoutConstraint.deactivate(previousIsGrid ? gridConstraints : listConstraints)
        }
        isGridLayout = isGrid
        nameLabel.numberOfLines = isGrid ? 2 : 1
        nameLabel.textAlignment = isGrid ? .center : .natural
        NSLayoutConstraint.activate(isGrid ? gridConstraints : listConstraints)
        updateTypography()
    }

    private func updateTypography() {
        let metrics = LayoutMetrics(contentSizeCategory: traitCollection.preferredContentSizeCategory)
        let isGrid = isGridLayout ?? true
        nameLabel.font = isGrid ? metrics.gridTitleFont : metrics.listTitleFont
        titleHeightConstraint.constant = isGrid ? metrics.gridTitleHeight : metrics.listTitleHeight
    }

    private func loadCover(_ group: BookGroup) {
        let path = group.cover?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, path != "use_default_cover" else { return }

        let source: Source
        if let url = BookCoverImageLoader.localImageURL(path) {
            source = .provider(LocalFileImageDataProvider(fileURL: url))
        } else if let url = URL(string: path),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        {
            source = .network(Kingfisher.ImageResource(downloadURL: url))
        } else {
            return
        }

        let generation = coverGeneration
        let groupId = group.groupId
        coverTask = coverView.kf.setImage(
            with: source, placeholder: Self.defaultCover,
            options: [
                .processor(DownsamplingImageProcessor(size: CGSize(width: 300, height: 420))),
                .scaleFactor(max(1, traitCollection.displayScale)),
                .backgroundDecode,
                .onFailureImage(Self.defaultCover),
            ]
        ) { [weak self] _ in
            guard let self, self.coverGeneration == generation, self.representedGroupId == groupId else {
                return
            }
            self.coverTask = nil
        }
    }

    private func cancelCover() {
        coverGeneration = UUID()
        coverTask?.cancel()
        coverTask = nil
        coverView.kf.cancelDownloadTask()
        // Clearing the source also invalidates Kingfisher's identity for an in-flight local-file read.
        coverView.kf.setImage(with: nil as Source?, placeholder: Self.defaultCover)
    }

    @objc private func editFromAccessibility(_: UIAccessibilityCustomAction) -> Bool {
        guard representedGroupId != nil, let onEdit else { return false }
        onEdit()
        return true
    }

    private struct LayoutMetrics {
        static let coverAspectRatio: CGFloat = 7.0 / 5.0
        static let listCoverWidth: CGFloat = 66
        // CoverImageView.onMeasure overrides the XML height with width * 7 / 5.
        static let listCoverHeight = listCoverWidth * coverAspectRatio

        let gridTitleFont: UIFont
        let listTitleFont: UIFont

        var gridTitleHeight: CGFloat { ceil(gridTitleFont.lineHeight * 2) }
        var listTitleHeight: CGFloat { ceil(listTitleFont.lineHeight) + 4 }

        init(contentSizeCategory: UIContentSizeCategory) {
            let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
            gridTitleFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: 12), compatibleWith: traits)
            listTitleFont = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: 16), compatibleWith: traits)
        }
    }
}
