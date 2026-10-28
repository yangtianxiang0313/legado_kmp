import SnapKit
import UIKit

final class ChangeCoverGridCell: UICollectionViewCell {
    static let reuseIdentifier = "ChangeCoverGridCell"
    // Android item_cover.xml at 5f5d314: 12dp padding, 100dp cover, 8dp gap, 16sp source.
    static let contentPadding: CGFloat = 12
    static let coverHeight: CGFloat = 100
    static let sourceSpacing: CGFloat = 8
    static var sourceFont: UIFont { sourceFont(compatibleWith: .current) }
    static var itemHeight: CGFloat { itemHeight(compatibleWith: .current) }

    static func itemHeight(compatibleWith traits: UITraitCollection) -> CGFloat {
        contentPadding * 2 + coverHeight + sourceSpacing + sourceHeight(compatibleWith: traits)
    }

    private static func sourceFont(compatibleWith traits: UITraitCollection) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traits)
    }

    private static func sourceHeight(compatibleWith traits: UITraitCollection) -> CGFloat {
        let font = sourceFont(compatibleWith: traits)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        let scale = max(1, traits.displayScale)
        return ceil((font.lineHeight + padding.top + padding.bottom) * scale) / scale
    }

    struct Placeholder {
        let bookName: String
        let bookAuthor: String
        var image: UIImage?
        var drawBookName = true
        var drawBookAuthor = true
    }

    private let imageView = UIImageView()
    private let coverMask = CAShapeLayer()
    private let nameLabel = ReaderTocSingleLineLabel()
    private let defaultTextView = ChangeCoverDefaultTextView()
    private var sourceHeightConstraint: Constraint?
    private static let defaultCoverImage = UIImage(named: "BookshelfAndroidCoverDefault")?
        .withRenderingMode(.alwaysOriginal)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.mask = coverMask
        contentView.addSubview(imageView)
        imageView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview().inset(Self.contentPadding)
            $0.height.equalTo(Self.coverHeight)
        }

        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(nameLabel)
        nameLabel.snp.makeConstraints {
            $0.top.equalTo(imageView.snp.bottom).offset(Self.sourceSpacing)
            $0.leading.trailing.equalToSuperview().inset(Self.contentPadding)
            sourceHeightConstraint = $0.height.equalTo(Self.sourceHeight(compatibleWith: traitCollection)).constraint
        }

        imageView.addSubview(defaultTextView)
        defaultTextView.snp.makeConstraints { $0.edges.equalToSuperview() }
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateTextMetrics()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTextMetrics()
        setNeedsLayout()
        applyTheme()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // CoverImageView clips with quadratic corners at 10 physical pixels, not a fixed dp radius.
        let radius = 10 / max(1, traitCollection.displayScale)
        let width = imageView.bounds.width
        let height = imageView.bounds.height
        guard width > radius, height > radius else {
            coverMask.path = UIBezierPath(rect: imageView.bounds).cgPath
            return
        }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: radius), controlPoint: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addQuadCurve(to: CGPoint(x: width - radius, y: height), controlPoint: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - radius), controlPoint: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), controlPoint: .zero)
        path.close()
        coverMask.path = path.cgPath
    }

    private func updateTextMetrics() {
        nameLabel.font = Self.sourceFont(compatibleWith: traitCollection)
        sourceHeightConstraint?.update(offset: Self.sourceHeight(compatibleWith: traitCollection))
    }

    private func applyTheme() {
        imageView.backgroundColor = AndroidReplicaTheme.coverBackground
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        defaultTextView.setNeedsDisplay()
        contentView.backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear
    }

    func configure(
        sourceName: String, image: UIImage?, isDefault: Bool, isLoading: Bool,
        placeholder: Placeholder
    ) {
        nameLabel.text = sourceName
        imageView.image = image ?? placeholder.image ?? Self.defaultCoverImage
        let showsDefault = isDefault || image == nil
        // CoverAdapter uses CoverImageView's book-name/author fallback, not a reset icon.
        defaultTextView.configure(placeholder)
        defaultTextView.isHidden = !showsDefault
        accessibilityLabel = sourceName
        accessibilityValue = isLoading ? L10n.BookDetail.changeCoverLoading : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        nameLabel.text = nil
        defaultTextView.isHidden = true
        accessibilityLabel = nil
        accessibilityValue = nil
        contentView.backgroundColor = .clear
    }
}

/// CoverImageView.drawNameAuthor uses canvas-relative sizes, not sp or TextView font padding.
private final class ChangeCoverDefaultTextView: UIView {
    private var placeholder = ChangeCoverGridCell.Placeholder(bookName: "", bookAuthor: "")
    private var configurationObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: CoverConfigurationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.setNeedsDisplay() }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(_ placeholder: ChangeCoverGridCell.Placeholder) {
        self.placeholder = placeholder
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let mode: CoverConfigurationMode = traitCollection.userInterfaceStyle == .dark ? .night : .day
        if placeholder.image == nil || CoverConfigurationStore.shared.configuration(for: mode).backgroundPath != nil {
            AndroidDefaultBookCoverRenderer.draw(
                name: placeholder.bookName, author: placeholder.bookAuthor, in: bounds,
                scale: contentScaleFactor, traitCollection: traitCollection)
        } else {
            AndroidDefaultBookCoverRenderer.drawText(
                name: placeholder.bookName, author: placeholder.bookAuthor, in: bounds, traitCollection: traitCollection,
                drawName: placeholder.drawBookName, drawAuthor: placeholder.drawBookAuthor)
        }
    }
}
