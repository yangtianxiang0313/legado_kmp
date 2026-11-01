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
            height = max(16 + LayoutMetrics.listCoverHeight + 12, 12 + metrics.listTitleHeight)
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

    private let coverClipView = AndroidBookCoverClipView()
    private let coverView = UIImageView()
    private let nameLabel = BookshelfFolderGroupNameLabel()
    private let feedbackView = BookshelfItemFeedbackView()
    private var gridConstraints: [NSLayoutConstraint] = []
    private var listConstraints: [NSLayoutConstraint] = []
    private var isGridLayout: Bool?
    private lazy var coverLeftConstraint = coverClipView.leftAnchor.constraint(
        equalTo: contentView.leftAnchor, constant: 16)
    private lazy var titleHeightConstraint = nameLabel.heightAnchor.constraint(
        equalToConstant: 0)
    private var coverTask: DownloadTask?
    private var coverGeneration = UUID()
    private var representedGroupId: Int64?
    private var representedCover: String?
    private var feedbackObservations: [NSKeyValueObservation] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        contentView.isAccessibilityElement = false

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.image = Self.defaultCover
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.adjustsFontSizeToFitWidth = false
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.isAccessibilityElement = false
        coverClipView.addSubview(coverView)
        for view in [coverClipView, nameLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
            view.accessibilityElementsHidden = true
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            coverLeftConstraint,
            coverView.leftAnchor.constraint(equalTo: coverClipView.leftAnchor),
            coverView.rightAnchor.constraint(equalTo: coverClipView.rightAnchor),
            coverView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
            coverView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
            nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleHeightConstraint,
        ])
        gridConstraints = [
            coverClipView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            coverClipView.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -16),
            coverClipView.heightAnchor.constraint(
                equalTo: coverClipView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            nameLabel.topAnchor.constraint(equalTo: coverClipView.bottomAnchor, constant: 14),
            nameLabel.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 8),
            nameLabel.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ]
        listConstraints = [
            coverClipView.widthAnchor.constraint(equalToConstant: LayoutMetrics.listCoverWidth),
            coverClipView.heightAnchor.constraint(
                equalTo: coverClipView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            coverClipView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
            coverClipView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            coverClipView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 2),
            // tv_name has physical marginLeft=10 + paddingLeft=2. fl_has_new is GONE,
            // so its End=16 margin is zero and its left/right anchors coincide at parent.right.
            nameLabel.leftAnchor.constraint(equalTo: coverClipView.rightAnchor, constant: 12),
            nameLabel.rightAnchor.constraint(equalTo: contentView.rightAnchor),
            // Only tv_name remains visible in the spread chain. tv_last's Bottom=8
            // belongs to a GONE node, so the surviving chain has Top=12 / Bottom=0.
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 6),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ]
        applyLayout(isGrid: true)
        contentView.addSubview(feedbackView)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted, canShowPressedFeedback else {
                clearHighlight()
                return
            }
            feedbackView.isHidden = false
            observePressedAvailability()
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            if !isUserInteractionEnabled { clearHighlight() }
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { clearHighlight() }
        }
    }

    override var alpha: CGFloat {
        didSet {
            if alpha <= 0.01 { clearHighlight() }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { clearHighlight() }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { clearHighlight() }
        super.willMove(toSuperview: newSuperview)
    }

    override func layoutSubviews() {
        updateCoverInset()
        super.layoutSubviews()
        feedbackView.frame = contentView.bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearHighlight() }
        setNeedsLayout()
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
        clearHighlight()
        cancelCover()
        representedGroupId = nil
        representedCover = nil
        nameLabel.text = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        onEdit = nil
    }

    func configure(group: BookGroup, isGrid: Bool) {
        let path = group.cover?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coverChanged = representedCover != path
        if coverChanged { cancelCover() }
        if representedGroupId != group.groupId { clearHighlight() }
        representedGroupId = group.groupId
        representedCover = path
        accessibilityLabel = group.groupName
        accessibilityValue = "分组"
        accessibilityHint = "打开分组"
        accessibilityIdentifier = "bookshelf.folderGroup.\(group.groupId)"
        applyLayout(isGrid: isGrid)
        let title =
            isGrid
            ? group.groupName
            : group.groupName.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = isGrid ? .center : .natural
        paragraph.baseWritingDirection = .natural
        paragraph.lineBreakMode = .byTruncatingTail
        nameLabel.attributedText = NSAttributedString(string: title, attributes: [.paragraphStyle: paragraph])
        if coverChanged { loadCover(path) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        {
            updateTypography()
        }
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
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
        updateCoverInset()
        updateTypography()
    }

    private func updateCoverInset() {
        // marginStart resolves onto the physical right in RTL, but the XML constrains
        // the cover only to physical Left. Grid's symmetric margin=8 is not directional.
        let inset: CGFloat =
            isGridLayout == false && effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : 16
        if coverLeftConstraint.constant != inset { coverLeftConstraint.constant = inset }
    }

    private var canShowPressedFeedback: Bool {
        guard window != nil else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01 else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func clearHighlight() {
        feedbackObservations.removeAll()
        super.isHighlighted = false
        feedbackView.isHidden = true
    }

    private func observePressedAvailability() {
        guard feedbackObservations.isEmpty else { return }
        // Observe only for the active press; ordinary layout/reconfiguration installs no KVO.
        var ancestor: UIView? = self
        while let view = ancestor {
            let changed: () -> Void = { [weak self] in
                guard let self, !self.canShowPressedFeedback else { return }
                self.clearHighlight()
            }
            feedbackObservations.append(view.observe(\.isUserInteractionEnabled, options: [.new]) { _, _ in changed() })
            feedbackObservations.append(view.observe(\.isHidden, options: [.new]) { _, _ in changed() })
            feedbackObservations.append(view.observe(\.alpha, options: [.new]) { _, _ in changed() })
            ancestor = view.superview
        }
    }

    private func updateTypography() {
        let metrics = LayoutMetrics(contentSizeCategory: traitCollection.preferredContentSizeCategory)
        let isGrid = isGridLayout ?? true
        nameLabel.font = isGrid ? metrics.gridTitleFont : metrics.listTitleFont
        titleHeightConstraint.constant = isGrid ? metrics.gridTitleHeight : metrics.listTitleHeight
    }

    private func loadCover(_ path: String) {
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
        coverTask = coverView.kf.setImage(
            with: source, placeholder: Self.defaultCover,
            options: [
                .processor(DownsamplingImageProcessor(size: CGSize(width: 300, height: 420))),
                .scaleFactor(max(1, traitCollection.displayScale)),
                .backgroundDecode,
                .onFailureImage(Self.defaultCover),
            ]
        ) { [weak self] _ in
            guard let self, self.coverGeneration == generation, self.representedCover == path else {
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
            gridTitleFont = ReaderAndroidDefaultFont.scaledFont(
                size: 12, textStyle: .caption1, compatibleWith: traits)
            listTitleFont = ReaderAndroidDefaultFont.scaledFont(
                size: 16, textStyle: .body, compatibleWith: traits)
        }
    }
}

private final class BookshelfFolderGroupNameLabel: UILabel {
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        var rect = super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        rect.origin.y = bounds.minY
        return rect
    }

    override func drawText(in rect: CGRect) {
        // Grid is gravity=top|center_horizontal; list leaves its 4dp padding below
        // the single text line, rather than centering the glyphs in the padded height.
        super.drawText(in: textRect(forBounds: rect, limitedToNumberOfLines: numberOfLines))
    }
}
