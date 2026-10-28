import UIKit
import shared

/// item_read_style.xml / CircleImageView at Legado 5f5d314.
final class ReaderStylePresetChip: UIButton {
    var onSelect: ((String) -> Void)?
    var onEdit: ((String) -> Void)?

    private(set) var presetName = ""
    private let previewImageView = UIImageView()
    private let previewBorderView = UIView()
    private let previewTitleView = ReaderStylePresetTitleView()
    private var previewKey: String?
    private var consumedLongPress = false

    private final class CachedPreview {
        let image: UIImage?

        init(image: UIImage?) {
            self.image = image
        }
    }

    private static let previewCache: NSCache<NSString, CachedPreview> = {
        let cache = NSCache<NSString, CachedPreview>()
        cache.countLimit = 64
        return cache
    }()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        layer.cornerRadius = 24
        clipsToBounds = false
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center

        previewImageView.contentMode = .scaleAspectFill
        previewImageView.isUserInteractionEnabled = false
        previewImageView.isAccessibilityElement = false
        previewImageView.clipsToBounds = true
        previewImageView.layer.cornerRadius = 24
        previewImageView.frame = bounds
        previewImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(previewImageView, at: 0)

        // CircleImageView draws its border after the image but before the text.
        previewBorderView.frame = bounds
        previewBorderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewBorderView.layer.cornerRadius = 24
        previewBorderView.layer.borderWidth = 1
        previewBorderView.isUserInteractionEnabled = false
        previewBorderView.isAccessibilityElement = false
        addSubview(previewBorderView)

        previewTitleView.frame = bounds
        previewTitleView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewTitleView.backgroundColor = .clear
        previewTitleView.isOpaque = false
        previewTitleView.isUserInteractionEnabled = false
        previewTitleView.isAccessibilityElement = false
        previewTitleView.contentMode = .redraw
        addSubview(previewTitleView)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.Common.edit) { [weak self] _ in
                guard let self, self.isEnabled, let onEdit = self.onEdit else { return false }
                onEdit(self.presetName)
                return true
            }
        ]
        addTarget(self, action: #selector(selectPreset), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(editPreset(_:)))
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(
        preset: ReaderPreset, selected: Bool, palette: ReaderMenuPalette, isNight: Bool
    ) {
        configure(preset: preset, selected: selected, palette: palette, variant: isNight ? .night : .day)
    }

    func configure(
        preset: ReaderPreset, selected: Bool, palette: ReaderMenuPalette, variant: ReaderVisualVariant
    ) {
        presetName = preset.name
        let title =
            preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "文字" : preset.name
        accessibilityLabel = title

        let style = preset.styleForVariant(variant: variant)
        let foreground = UIColor(hex: style.textColorHex ?? "") ?? palette.bodyText
        let imagePath = Self.nonempty(style.backgroundImagePath)
        backgroundColor = UIColor(hex: style.backgroundColorHex ?? "") ?? palette.bottomBackground
        isSelected = selected
        previewTitleView.configure(text: title, foreground: foreground, selected: selected)
        previewBorderView.layer.borderColor =
            (selected ? palette.accent : foreground)
            .resolvedColor(with: traitCollection).cgColor
        if selected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }

        let scale = max(traitCollection.displayScale, 1)
        let key = imagePath.map { "\(scale):\($0)" }
        if key != previewKey {
            previewKey = key
            previewImageView.image = imagePath.flatMap {
                Self.preview(forStoredPath: $0, scale: scale)
            }
        }
        // StyleAdapter uses curBgDrawable directly, without applying page bgAlpha.
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard point(inside: touch.location(in: self), with: event) else { return false }
        consumedLongPress = false
        return super.beginTracking(touch, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        // CircleImageView.isInView uses the border's radius, not the square item bounds.
        let radius = max(0, (min(bounds.width, bounds.height) - previewBorderView.layer.borderWidth) / 2)
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, let onSelect else { return false }
        onSelect(presetName)
        return true
    }

    @objc private func selectPreset() {
        guard isEnabled, !consumedLongPress else { return }
        onSelect?(presetName)
    }

    @objc private func editPreset(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, isEnabled, !consumedLongPress else { return }
        // Keep suppression through cancellation/release; only a new touch resets it.
        consumedLongPress = true
        onEdit?(presetName)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func preview(forStoredPath path: String, scale: CGFloat) -> UIImage? {
        let key = "\(scale):\(path)" as NSString
        if let cached = previewCache.object(forKey: key) { return cached.image }

        let preview: UIImage?
        if let source = ReaderBackgroundImageCatalog.image(forStoredPath: path),
            source.size.width > 0, source.size.height > 0
        {
            // StyleAdapter requests curBgDrawable(100, 150), which resizes the
            // bitmap before CircleImageView center-crops it into the square cell.
            let size = CGSize(width: 48, height: 48)
            let backgroundSize = CGSize(width: 100, height: 150)
            let factor = max(size.width / backgroundSize.width, size.height / backgroundSize.height)
            let drawnSize = CGSize(width: backgroundSize.width * factor, height: backgroundSize.height * factor)
            let rect = CGRect(
                x: (size.width - drawnSize.width) / 2,
                y: (size.height - drawnSize.height) / 2,
                width: drawnSize.width, height: drawnSize.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                source.withRenderingMode(.alwaysOriginal).draw(in: rect)
            }
        } else {
            preview = nil
        }
        // Cache misses as well, so an unresolved stored path is not retried on every update.
        previewCache.setObject(CachedPreview(image: preview), forKey: key)
        return preview
    }
}

private final class ReaderStylePresetTitleView: UIView {
    private var text = ""
    private var foreground = UIColor.label
    private var selected = false

    func configure(text: String, foreground: UIColor, selected: Bool) {
        self.text = text
        self.foreground = foreground
        self.selected = selected
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        // CircleImageView.drawText: centered 15sp, selected bold, no fitting or ellipsis.
        // Clip to the square canvas; only the background image is circularly cropped.
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 15, textStyle: .subheadline, weight: selected ? 700 : 400, compatibleWith: traitCollection)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: foreground, .kern: CGFloat(0),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        UIGraphicsGetCurrentContext()?.clip(to: bounds)
        (text as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}
