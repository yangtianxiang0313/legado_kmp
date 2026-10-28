import Then
import UIKit

private enum ReaderMenuCompactTextMetrics {
    static func roundUp(_ value: CGFloat, traits: UITraitCollection) -> CGFloat {
        let scale = max(1, traits.displayScale)
        return ceil(value * scale) / scale
    }
}

final class ReaderMenuChapterButton: UIButton {
    private var textFont = ReaderAndroidDefaultFont.font(size: 14) ?? .systemFont(ofSize: 14)

    var preferredHeight: CGFloat {
        let padding = AndroidExploreTextMetrics.padding(font: textFont, scale: traitCollection.displayScale)
        return ReaderMenuCompactTextMetrics.roundUp(
            textFont.lineHeight + padding.top + padding.bottom + 20, traits: traitCollection)
    }

    func applyFont(compatibleWith traits: UITraitCollection) {
        textFont = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
        titleLabel?.font = textFont
        titleLabel?.adjustsFontForContentSizeCategory = false
        let padding = AndroidExploreTextMetrics.padding(font: textFont, scale: traits.displayScale)
        // tv_pre/tv_next: natural TextView padding plus 10dp vertical padding.
        contentEdgeInsets = UIEdgeInsets(top: 10 + padding.top, left: 10, bottom: 10 + padding.bottom, right: 10)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        let verticalInset = max(44 - bounds.height, 0) / 2
        return bounds.insetBy(dx: 0, dy: -verticalInset).contains(point)
    }
}

class ReaderMenuActionButton: UIButton {
    var onTap: (() -> Void)?

    private var onSecondaryAction: (() -> Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configureSecondaryAction(name: String, action: @escaping () -> Bool) {
        guard onSecondaryAction == nil else { return }
        onSecondaryAction = action
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        // Cancel only this press; a later, independent tap must remain available.
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.performSecondaryAction() ?? false
            }
        ]
    }

    @objc private func handleTap() {
        guard ReaderMenuToolbarInteraction.isAvailable(self) else { return }
        onTap?()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        performSecondaryAction()
    }

    @discardableResult
    private func performSecondaryAction() -> Bool {
        guard ReaderMenuToolbarInteraction.isAvailable(self) else { return false }
        return onSecondaryAction?() ?? false
    }
}

final class ReaderMenuBottomActionButton: ReaderMenuActionButton {
    private enum Metrics {
        static let iconSize: CGFloat = 20
        static let imagePadding: CGFloat = 3
        static let bottomPadding: CGFloat = 7
    }

    private var textFont = ReaderAndroidDefaultFont.font(size: 12) ?? .systemFont(ofSize: 12)
    private var fontPadding = UIEdgeInsets.zero

    var preferredHeight: CGFloat {
        ReaderMenuCompactTextMetrics.roundUp(
            Metrics.iconSize + Metrics.imagePadding + textFont.lineHeight
                + fontPadding.top + fontPadding.bottom + Metrics.bottomPadding,
            traits: traitCollection)
    }

    init(title: String, icon: ReaderMenuAndroidIcon) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setImage(icon.image(size: Metrics.iconSize), for: .normal)
        applyFont(compatibleWith: traitCollection)
        titleLabel?.numberOfLines = 1
        titleLabel?.adjustsFontForContentSizeCategory = false
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.textAlignment = .center
        titleLabel?.lineBreakMode = .byTruncatingMiddle
        imageView?.contentMode = .scaleAspectFit
        accessibilityLabel = title
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFont(compatibleWith traits: UITraitCollection) {
        textFont = ReaderAndroidDefaultFont.scaledFont(size: 12, textStyle: .caption1, compatibleWith: traits)
        fontPadding = AndroidExploreTextMetrics.padding(font: textFont, scale: traits.displayScale)
        titleLabel?.font = textFont
        titleLabel?.adjustsFontForContentSizeCategory = false
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // view_read_menu.xml: fixed icon, 3dp text margin, then 7dp bottom padding.
        imageView?.frame = CGRect(
            x: bounds.midX - Metrics.iconSize / 2, y: bounds.minY,
            width: Metrics.iconSize, height: Metrics.iconSize)
        let titleTop = bounds.minY + Metrics.iconSize + Metrics.imagePadding
        titleLabel?.frame = CGRect(
            x: bounds.minX, y: titleTop + fontPadding.top, width: bounds.width,
            height: max(bounds.maxY - Metrics.bottomPadding - titleTop - fontPadding.top - fontPadding.bottom, 0))
    }
}

final class ReaderMenuFloatingButton: UIButton {
    private var restingBackground = UIColor.clear
    private var pressedBackground = UIColor.clear

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    func apply(background: UIColor, pressedBackground: UIColor) {
        restingBackground = background
        self.pressedBackground = pressedBackground
        updateBackground()
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    private func updateBackground() {
        backgroundColor = isHighlighted ? pressedBackground : restingBackground
    }
}

final class ReaderMenuBrightnessSliderHost: UIView {
    let slider = UISlider()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Android VerticalSeekBar explicitly forces LTR before its CW270 rotation.
        slider.semanticContentAttribute = .forceLeftToRight
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 40, height: 44) }

    override func layoutSubviews() {
        super.layoutSubviews()
        slider.transform = .identity
        slider.bounds = CGRect(x: 0, y: 0, width: max(bounds.height - 16, 1), height: 32)
        slider.center = CGPoint(x: bounds.midX, y: bounds.midY)
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
    }
}

final class ReaderCompactActionButton: UIButton {
    enum Style {
        case compact
        case prominent
        case iconOnly
    }

    init(
        title: String,
        systemImage: String,
        identifier: String? = nil,
        isEnabled: Bool = true,
        style: Style = .compact,
        handler: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        var configuration: UIButton.Configuration = style == .prominent ? .filled() : .plain()
        configuration.title = title.isEmpty ? nil : title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePlacement = .top
        configuration.imagePadding = style == .prominent ? 8 : 5
        configuration.baseForegroundColor = isEnabled ? .label : .tertiaryLabel
        configuration.baseBackgroundColor = style == .prominent ? AndroidReplicaTheme.accent.withAlphaComponent(0.14) : nil
        configuration.cornerStyle = .medium
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = {
            switch style {
            case .compact:
                return NSDirectionalEdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5)
            case .prominent:
                return NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
            case .iconOnly:
                return NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
            }
        }()
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: style == .prominent ? 12 : 11, weight: .medium)
            )
            return outgoing
        }
        self.configuration = configuration
        self.isEnabled = isEnabled
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.82
        titleLabel?.textAlignment = .center
        titleLabel?.numberOfLines = 2
        imageView?.contentMode = .scaleAspectFit
        accessibilityIdentifier = identifier
        accessibilityLabel = title.isEmpty ? nil : title
        addAction(UIAction { _ in handler() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension UIStackView {
    static func readerCompactRow(_ views: [UIView], spacing: CGFloat = AppUI.Spacing.small) -> UIStackView {
        UIStackView(arrangedSubviews: views).then {
            $0.axis = .horizontal
            $0.alignment = .fill
            $0.distribution = .fillEqually
            $0.spacing = spacing
        }
    }
}
