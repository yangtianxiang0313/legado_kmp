import CoreText
import UIKit

@MainActor
enum AndroidDefaultBookCoverRenderer {
    private static let bundledBackground = UIImage(named: "BookshelfAndroidCoverDefault")?
        .withRenderingMode(.alwaysOriginal)
    private static let customBackgrounds = NSCache<NSString, UIImage>()

    static func restoredVisibility(traits: UITraitCollection) -> (name: Bool, author: Bool) {
        let config = configuration(traits: traits)
        return (config.showsName, config.showsAuthor)
    }

    static func backgroundImage(
        traits: UITraitCollection, configuration: CoverConfiguration? = nil
    ) -> UIImage? {
        let config = configuration ?? Self.configuration(traits: traits)
        guard let path = config.backgroundPath, let url = CoverConfigurationImageFiles.resolve(path) else {
            return bundledBackground
        }
        let key = url.path as NSString
        if let cached = customBackgrounds.object(forKey: key) { return cached }
        guard let image = CoverConfigurationImageFiles.loadImage(at: url) else { return bundledBackground }
        customBackgrounds.totalCostLimit = 32 * 1024 * 1024
        customBackgrounds.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    private static func configuration(traits: UITraitCollection) -> CoverConfiguration {
        CoverConfigurationStore.shared.configuration(for: traits.userInterfaceStyle == .dark ? .night : .day)
    }

    static func image(
        name: String?, author: String?, size: CGSize, scale: CGFloat = 0,
        traitCollection: UITraitCollection = .current
    ) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            size.width <= 8192, size.height <= 8192
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = resolvedScale(scale, traits: traitCollection)
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(
                name: name, author: author, in: CGRect(origin: .zero, size: size),
                scale: format.scale, traitCollection: traitCollection
            )
        }
    }

    static func draw(
        name: String?, author: String?, in rect: CGRect, scale: CGFloat,
        traitCollection: UITraitCollection, configuration: CoverConfiguration? = nil
    ) {
        guard rect.width > 0, rect.height > 0,
            let backgroundImage = backgroundImage(traits: traitCollection, configuration: configuration),
            backgroundImage.size.width > 0, backgroundImage.size.height > 0,
            let context = UIGraphicsGetCurrentContext()
        else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        let bounds = CGRect(origin: .zero, size: rect.size)
        context.clip(to: bounds)
        clipCorners(in: bounds, scale: resolvedScale(scale, traits: traitCollection), context: context)

        let imageScale = max(bounds.width / backgroundImage.size.width, bounds.height / backgroundImage.size.height)
        let imageSize = CGSize(
            width: backgroundImage.size.width * imageScale, height: backgroundImage.size.height * imageScale
        )
        backgroundImage.draw(
            in: CGRect(
                origin: CGPoint(x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height) / 2),
                size: imageSize
            ))

        drawText(
            name: name, author: author, in: bounds, traitCollection: traitCollection,
            drawName: configuration?.showsName, drawAuthor: configuration?.showsAuthor)
    }

    static func drawText(
        name: String?, author: String?, in rect: CGRect, traitCollection: UITraitCollection,
        drawName: Bool? = nil, drawAuthor: Bool? = nil
    ) {
        guard rect.width > 0, rect.height > 0, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        let bounds = CGRect(origin: .zero, size: rect.size)
        context.clip(to: bounds)
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection).cgColor
        let visibility = restoredVisibility(traits: traitCollection)
        let showsName = drawName ?? visibility.name
        let showsAuthor = drawAuthor ?? visibility.author
        let nameCharacters = showsName ? characters(in: name) : []
        var x = bounds.width * 0.2
        var y = bounds.height * 0.2
        var nameFont = defaultFont(size: bounds.width / 6, weight: 700)
        // CoverImageView sets this once, before shrinking the font for subsequent columns.
        let nameStrokeWidth = nameFont.pointSize / 5
        for (index, character) in nameCharacters.enumerated() {
            drawCharacter(
                character, at: CGPoint(x: x, y: y), font: nameFont,
                strokeWidth: nameStrokeWidth, accent: accent, context: context
            )
            y += textHeight(nameFont)
            if y > bounds.height * 0.8 {
                x += nameFont.pointSize
                nameFont = defaultFont(size: bounds.width / 10, weight: 700)
                y = (bounds.height - CGFloat(nameCharacters.count - index - 1) * textHeight(nameFont)) / 2
            }
        }

        let authorCharacters = showsName && showsAuthor ? characters(in: author) : []
        let authorFont = defaultFont(size: bounds.width / 10, weight: 400)
        let authorHeight = textHeight(authorFont)
        x = bounds.width * 0.8
        y = max(bounds.height * 0.95 - CGFloat(authorCharacters.count) * authorHeight, bounds.height * 0.3)
        for character in authorCharacters {
            drawCharacter(
                character, at: CGPoint(x: x, y: y), font: authorFont,
                strokeWidth: authorFont.pointSize / 5, accent: accent, context: context
            )
            y += authorHeight
            if y > bounds.height * 0.95 { break }
        }
    }

    private static func defaultFont(size: CGFloat, weight: Int) -> UIFont {
        ReaderAndroidDefaultFont.font(size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: weight == 700 ? .bold : .regular)
    }

    private static func textHeight(_ font: UIFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    private static func drawCharacter(
        _ text: String, at baseline: CGPoint, font: UIFont,
        strokeWidth: CGFloat, accent: CGColor, context: CGContext
    ) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: baseline.x, y: baseline.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setShouldAntialias(true)
        context.setLineWidth(strokeWidth)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setTextDrawingMode(.stroke)
        context.textPosition = CGPoint(x: -advance / 2, y: 0)
        CTLineDraw(line, context)
        context.setFillColor(accent)
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: -advance / 2, y: 0)
        CTLineDraw(line, context)
    }

    private static func characters(in text: String?) -> [String] {
        // AppPattern.bdRegex = (\p{P})+; toStringArray splits code points, not grapheme clusters.
        let scalars = Array(
            (text ?? "").unicodeScalars.filter { scalar in
                switch scalar.properties.generalCategory {
                case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                    .initialPunctuation, .finalPunctuation, .otherPunctuation:
                    return false
                default:
                    return true
                }
            })
        var start = 0
        var end = scalars.count
        while start < end, isTrimWhitespace(scalars[start]) { start += 1 }
        while end > start, isTrimWhitespace(scalars[end - 1]) { end -= 1 }
        return scalars[start..<end].map { String($0) }
    }

    private static func isTrimWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        // Kotlin/JVM trim uses Character.isWhitespace || Character.isSpaceChar.
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return (0x09...0x0D).contains(scalar.value) || (0x1C...0x1F).contains(scalar.value)
        }
    }

    private static func resolvedScale(_ scale: CGFloat, traits: UITraitCollection) -> CGFloat {
        if scale.isFinite, scale > 0 { return scale }
        if traits.displayScale > 0 { return traits.displayScale }
        return UIScreen.main.scale
    }

    private static func clipCorners(in rect: CGRect, scale: CGFloat, context: CGContext) {
        // The original quadratic fillet is 10 physical pixels, not 10dp.
        let radius = 10 / scale
        guard rect.width > radius, rect.height > radius else { return }
        let width = rect.width
        let height = rect.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: radius), control: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addQuadCurve(to: CGPoint(x: width - radius, y: height), control: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - radius), control: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        context.addPath(path)
        context.clip()
    }
}

internal final class AndroidBookCoverClipView: UIView {
    private let clipMask = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.mask = clipMask
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // CoverImageView uses a 10px quadratic fillet, matching the default cover renderer.
        let scale =
            traitCollection.displayScale > 0
            ? traitCollection.displayScale : (window?.screen.scale ?? UIScreen.main.scale)
        let radius = 10 / scale
        let width = bounds.width
        let height = bounds.height
        let path = CGMutablePath()
        if width > radius, height > radius {
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: width - radius, y: 0))
            path.addQuadCurve(to: CGPoint(x: width, y: radius), control: CGPoint(x: width, y: 0))
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addQuadCurve(to: CGPoint(x: width - radius, y: height), control: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: radius, y: height))
            path.addQuadCurve(to: CGPoint(x: 0, y: height - radius), control: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
            path.closeSubpath()
        } else {
            path.addRect(CGRect(origin: .zero, size: bounds.size))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.contentsScale = scale
        clipMask.frame = bounds
        clipMask.path = path
        CATransaction.commit()
    }
}

final class AndroidDefaultBookCoverView: UIView {
    private var name: String?
    private var author: String?
    private var defaultsObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var requestedHidden = false
    private var policySignature = CoverConfigurationStore.shared.policySignature
    var onLoadingPolicyChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var followsLoadingPolicy = true
    var configurationOverride: CoverConfiguration? {
        didSet { setNeedsDisplay() }
    }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            requestedHidden = newValue
            updatePresentation()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.configurationChanged() }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: CoverConfigurationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.configurationChanged() }
        themeObserver = NotificationCenter.default.addObserver(
            forName: .androidReplicaThemeDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.setNeedsDisplay() }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(name: String?, author: String?) {
        guard self.name != name || self.author != author else { return }
        self.name = name
        self.author = author
        setNeedsDisplay()
    }

    private func configurationChanged() {
        setNeedsDisplay()
        updatePresentation()
        onAppearanceChange?()
        let signature = CoverConfigurationStore.shared.policySignature
        guard signature != policySignature else { return }
        policySignature = signature
        onLoadingPolicyChange?()
    }

    private func updatePresentation() {
        let forced = followsLoadingPolicy && CoverConfigurationStore.shared.usesDefaultCover
        super.isHidden = requestedHidden && !forced
        // Some consumers overlay the decoded image as a sibling; a forced default must cover that image too.
        layer.zPosition = forced ? 1 : 0
    }

    override func draw(_ rect: CGRect) {
        AndroidDefaultBookCoverRenderer.draw(
            name: name, author: author, in: bounds, scale: contentScaleFactor,
            traitCollection: traitCollection, configuration: configurationOverride
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            setNeedsDisplay()
        }
    }
}
