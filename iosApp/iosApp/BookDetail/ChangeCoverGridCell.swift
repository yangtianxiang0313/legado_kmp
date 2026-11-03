import SnapKit
import UIKit

final class ChangeCoverGridCell: UICollectionViewCell {
    static let reuseIdentifier = "ChangeCoverGridCell"
    static let contentPadding: CGFloat = 12
    static let sourceSpacing: CGFloat = 8
    static var sourceFont: UIFont { sourceFont(compatibleWith: .current) }

    static func itemHeight(width: CGFloat, compatibleWith traits: UITraitCollection) -> CGFloat {
        layoutMetrics(for: width, compatibleWith: traits).itemHeight
    }

    private static func sourceFont(compatibleWith traits: UITraitCollection) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traits)
    }

    private struct LayoutMetrics {
        let horizontalPadding: CGFloat
        let coverHeight: CGFloat
        let sourceFont: UIFont
        let sourceHeight: CGFloat

        var itemHeight: CGFloat {
            ChangeCoverGridCell.contentPadding * 2 + coverHeight
                + ChangeCoverGridCell.sourceSpacing + sourceHeight
        }
    }

    private static func layoutMetrics(for width: CGFloat, compatibleWith traits: UITraitCollection) -> LayoutMetrics {
        let scale = max(1, traits.displayScale)
        let font = sourceFont(compatibleWith: traits)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
        // CoverImageView.onMeasure overrides XML's 100dp with integer physical-pixel height.
        let coverWidth = max(0, width - contentPadding * 2)
        let coverPixelWidth = (coverWidth * scale).rounded()
        return LayoutMetrics(
            horizontalPadding: min(contentPadding, max(0, width) / 2),
            coverHeight: floor(coverPixelWidth * 7 / 5) / scale,
            sourceFont: font,
            sourceHeight: ceil((font.lineHeight + padding.top + padding.bottom) * scale) / scale)
    }

    struct Placeholder {
        let bookName: String
        let bookAuthor: String
        var image: UIImage?
        var drawBookName = true
        var drawBookAuthor = true
    }

    private let imageView = UIImageView()
    private let coverView = AndroidBookCoverClipView()
    private let nameLabel = ReaderTocSingleLineLabel()
    private let defaultTextView = ChangeCoverDefaultTextView()
    private var coverHorizontalConstraint: Constraint?
    private var sourceHorizontalConstraint: Constraint?
    private var coverHeightConstraint: Constraint?
    private var sourceHeightConstraint: Constraint?
    private var appliedWidth: CGFloat?
    private var appliedTraits: UITraitCollection?
    private var pressedAvailabilityObservations: [NSKeyValueObservation] = []
    private static let defaultCoverImage = UIImage(named: "BookshelfAndroidCoverDefault")?
        .withRenderingMode(.alwaysOriginal)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        backgroundView = nil
        selectedBackgroundView = nil
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        let metrics = Self.layoutMetrics(for: bounds.width, compatibleWith: traitCollection)
        contentView.addSubview(coverView)
        coverView.snp.makeConstraints {
            $0.top.equalToSuperview().offset(Self.contentPadding)
            coverHorizontalConstraint =
                $0.leading.trailing.equalToSuperview().inset(metrics.horizontalPadding).constraint
            coverHeightConstraint = $0.height.equalTo(metrics.coverHeight).constraint
        }
        coverView.addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview() }

        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.adjustsFontSizeToFitWidth = false
        nameLabel.clipsToBounds = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.isAccessibilityElement = false
        contentView.addSubview(nameLabel)
        nameLabel.snp.makeConstraints {
            $0.top.equalTo(coverView.snp.bottom).offset(Self.sourceSpacing)
            sourceHorizontalConstraint =
                $0.leading.trailing.equalToSuperview().inset(metrics.horizontalPadding).constraint
            sourceHeightConstraint = $0.height.equalTo(metrics.sourceHeight).constraint
        }

        coverView.addSubview(defaultTextView)
        defaultTextView.snp.makeConstraints { $0.edges.equalToSuperview() }
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateLayoutMetrics()
        applyTheme()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(applicationBecameUnavailable), name: name, object: nil)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(sceneBecameUnavailable(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted, isAvailableForInteraction else {
                resetPressedState()
                return
            }
            observePressedAvailability()
        }
    }

    override var isHidden: Bool {
        didSet { if isHidden { resetPressedState() } }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { resetPressedState() } }
    }

    override var alpha: CGFloat {
        didSet { if alpha <= 0.01 { resetPressedState() } }
    }

    override var bounds: CGRect {
        didSet {
            if oldValue.width != bounds.width {
                setNeedsUpdateConstraints()
                setNeedsLayout()
            }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        resetPressedState()
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        resetPressedState()
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLayoutMetrics()
        setNeedsLayout()
    }

    func resetPressedState() {
        pressedAvailabilityObservations.removeAll()
        if isHighlighted { isHighlighted = false }
    }

    private func observePressedAvailability() {
        guard pressedAvailabilityObservations.isEmpty else { return }
        // Observe ancestors only for the active press; the cell handles its own property changes.
        var ancestor = superview
        while let view = ancestor {
            let changed: () -> Void = { [weak self] in
                guard let self, !self.isAvailableForInteraction else { return }
                self.resetPressedState()
            }
            pressedAvailabilityObservations.append(
                view.observe(\.isUserInteractionEnabled, options: [.new]) { _, _ in changed() })
            pressedAvailabilityObservations.append(
                view.observe(\.isHidden, options: [.new]) { _, _ in changed() })
            pressedAvailabilityObservations.append(
                view.observe(\.alpha, options: [.new]) { _, _ in changed() })
            ancestor = view.superview
        }
    }

    private var isAvailableForInteraction: Bool {
        guard let window, UIApplication.shared.applicationState == .active else { return false }
        if let scene = window.windowScene, scene.activationState != .foregroundActive { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || !current.isUserInteractionEnabled || current.alpha <= 0.01 { return false }
            view = current.superview
        }
        return true
    }

    @objc private func applicationBecameUnavailable() {
        resetPressedState()
    }

    @objc private func sceneBecameUnavailable(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        resetPressedState()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateLayoutMetrics()
        setNeedsLayout()
        applyTheme()
    }

    override func updateConstraints() {
        updateLayoutMetrics()
        super.updateConstraints()
    }

    override func layoutSubviews() {
        updateLayoutMetrics()
        super.layoutSubviews()
        if !isAvailableForInteraction { resetPressedState() }
    }

    private func updateLayoutMetrics() {
        guard appliedWidth != bounds.width || appliedTraits?.isEqual(traitCollection) != true else { return }
        let metrics = Self.layoutMetrics(for: bounds.width, compatibleWith: traitCollection)
        coverHorizontalConstraint?.update(inset: metrics.horizontalPadding)
        sourceHorizontalConstraint?.update(inset: metrics.horizontalPadding)
        coverHeightConstraint?.update(offset: metrics.coverHeight)
        sourceHeightConstraint?.update(offset: metrics.sourceHeight)
        nameLabel.font = metrics.sourceFont
        appliedWidth = bounds.width
        appliedTraits = traitCollection
    }

    private func applyTheme() {
        imageView.backgroundColor = AndroidReplicaTheme.coverBackground
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        defaultTextView.setNeedsDisplay()
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    func configure(
        sourceName: String, image: UIImage?, isDefault: Bool, isLoading: Bool,
        placeholder: Placeholder, isCurrent: Bool = false
    ) {
        let source =
            sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.BookDetail.unknownSource : sourceName
        nameLabel.text = source
        imageView.image = image ?? placeholder.image ?? Self.defaultCoverImage
        let showsDefault = isDefault || image == nil
        // CoverAdapter uses CoverImageView's book-name/author fallback, not a reset icon.
        defaultTextView.configure(placeholder)
        defaultTextView.isHidden = !showsDefault
        // The fixed, single-line grid may truncate visually, never in its accessible source name.
        accessibilityLabel = isDefault ? source : String(format: L10n.BookDetail.sourceFormat, source)
        accessibilityHint = BookDetailCoverText.selectHint
        accessibilityUserInputLabels = [source]
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        var states: [String] = []
        if isCurrent { states.append(BookDetailCoverText.currentCover) }
        if isLoading {
            states.append(L10n.BookDetail.changeCoverLoading)
        } else if !isDefault, image == nil {
            states.append(BookDetailCoverText.imageUnavailable)
        }
        accessibilityValue = states.isEmpty ? nil : states.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetPressedState()
        imageView.image = nil
        nameLabel.text = nil
        defaultTextView.isHidden = true
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityUserInputLabels = nil
        accessibilityTraits = .button
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
                name: placeholder.bookName, author: placeholder.bookAuthor, in: bounds,
                traitCollection: traitCollection,
                drawName: placeholder.drawBookName, drawAuthor: placeholder.drawBookAuthor)
        }
    }
}
