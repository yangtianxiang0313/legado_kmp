import Accelerate
import CoreImage
import UIKit

final class AndroidReplicaBookDetailPageView: UIView {
    let shelfButton: UIButton = BookDetailActionButton(type: .system)
    let readButton: UIButton = BookDetailActionButton(type: .system)
    let spinner = UIActivityIndicatorView(style: .medium)

    private static let minimumActionBarHeight: CGFloat = 50
    private static let minimumColumnsWidth: CGFloat = 560
    private let backgroundImageView = UIImageView()
    private let dimView = UIView()
    private let actionBarBackground = UIView()
    private let bottomBar = UIView()
    private let actionBarDivider = UIView()
    private var actionBarHeightConstraint: NSLayoutConstraint!
    private var actionBarDividerHeightConstraint: NSLayoutConstraint!
    private let topBar: AndroidReplicaDetailBar
    private let contentView: AndroidReplicaBookDetailContentView
    private var usesColumns = false
    private var backdropImage: UIImage?
    private var renderedBackdropImage: UIImage?
    private var renderedBackdropTarget: BookDetailBackdropRenderer.Target?
    private var requestedBackdropTarget: BookDetailBackdropRenderer.Target?
    private var animatesBackdrop = false
    private var isBackdropRenderingSuspended = false
    private var backdropGeneration = 0
    private var backdropTask: Task<Void, Never>?

    init(topBar: AndroidReplicaDetailBar, contentView: AndroidReplicaBookDetailContentView) {
        self.topBar = topBar
        self.contentView = contentView
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        contentView.reservedActionBarHeight = Self.minimumActionBarHeight
        contentView.setUsesColumns(false)
        configureBackground()
        configureActionBar()
        configureLayout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        backdropTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelBackdropRendering()
        } else {
            isBackdropRenderingSuspended = false
            renderBackdropIfNeeded()
        }
    }

    override func layoutSubviews() {
        topBar.updateLayout(availableSize: bounds.size)
        updateLayoutMode()
        updateActionBarHeight()
        super.layoutSubviews()
        renderBackdropIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateActionBarTypography()
        }
        setNeedsLayout()
    }

    func updateBackdropImage(_ image: UIImage?, animated: Bool = false) {
        let image = image?.isSymbolImage == false ? image : nil
        isBackdropRenderingSuspended = false
        // Returning to the same cover must resume cancellation without discarding a completed blur.
        if backdropImage === image {
            renderBackdropIfNeeded(retryFailed: true)
            return
        }
        invalidateBackdropRendering()
        backdropImage = image
        animatesBackdrop = animated
        if image == nil {
            renderedBackdropImage = nil
            renderedBackdropTarget = nil
            backgroundImageView.image = nil
        }
        renderBackdropIfNeeded()
    }

    func cancelBackdropRendering() {
        isBackdropRenderingSuspended = true
        invalidateBackdropRendering()
    }

    private func invalidateBackdropRendering() {
        backdropGeneration &+= 1
        backdropTask?.cancel()
        backdropTask = nil
        requestedBackdropTarget = nil
        backgroundImageView.layer.removeAllAnimations()
    }

    private var currentBackdropTarget: BookDetailBackdropRenderer.Target? {
        guard let window else { return nil }
        return BookDetailBackdropRenderer.Target(size: bounds.size, scale: window.screen.scale)
    }

    private func renderBackdropIfNeeded(retryFailed: Bool = false) {
        guard !isBackdropRenderingSuspended, window != nil, !ReaderPaletteColor.isEInk,
            let image = backdropImage
        else { return }
        guard let target = currentBackdropTarget else {
            if backdropTask != nil { invalidateBackdropRendering() }
            return
        }
        if let requestedBackdropTarget, requestedBackdropTarget != target {
            invalidateBackdropRendering()
        }
        guard renderedBackdropImage !== image || renderedBackdropTarget != target else { return }
        // Keep an unchanged task, and do not retry a failed render on every layout pass.
        guard backdropTask == nil, retryFailed || requestedBackdropTarget != target else { return }
        requestedBackdropTarget = target
        let generation = backdropGeneration
        backdropTask = Task { @MainActor [weak self] in
            let blurred = await BookDetailBackdropRenderer.render(image, target: target)
            guard !Task.isCancelled, let self, self.backdropGeneration == generation,
                self.backdropImage === image, self.window != nil, !ReaderPaletteColor.isEInk
            else { return }
            self.backdropTask = nil
            guard self.currentBackdropTarget == target else {
                self.requestedBackdropTarget = nil
                self.renderBackdropIfNeeded()
                return
            }
            guard let blurred else { return }
            self.renderedBackdropImage = image
            self.renderedBackdropTarget = target
            // BookCover.loadBlur keeps its default thumbnail until the real blur cross-fades in.
            if self.animatesBackdrop, !UIAccessibility.isReduceMotionEnabled,
                self.window?.windowScene?.activationState == .foregroundActive
            {
                UIView.transition(
                    with: self.backgroundImageView, duration: 1.5,
                    options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent]
                ) {
                    self.backgroundImageView.image = blurred
                }
            } else {
                self.backgroundImageView.image = blurred
            }
        }
    }

    private func updateLayoutMode() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let shouldUseColumns = bounds.width > bounds.height && bounds.width >= Self.minimumColumnsWidth
        guard shouldUseColumns != usesColumns else { return }
        usesColumns = shouldUseColumns
        contentView.setUsesColumns(usesColumns)
    }

    private func configureBackground() {
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.backgroundColor = .clear
        dimView.backgroundColor = UIColor.black.withAlphaComponent(80.0 / 255.0)
    }

    private func configureActionBar() {
        // BookInfoActivity applies navigation-bar padding to fl_action itself.
        // Keep the controls above the safe area while its background continues below them.
        actionBarBackground.backgroundColor = AndroidReplicaTheme.bottomBackground
        actionBarBackground.isUserInteractionEnabled = false
        bottomBar.backgroundColor = AndroidReplicaTheme.bottomBackground
        actionBarDivider.backgroundColor = AndroidReplicaTheme.divider
        actionBarDivider.isUserInteractionEnabled = false

        var shelfConfig = UIButton.Configuration.plain()
        shelfConfig.baseForegroundColor = BookDetailActionPalette.shelfText
        // Both original 50dp TextViews explicitly disable includeFontPadding.
        shelfConfig.contentInsets = .zero
        shelfConfig.titleAlignment = .center
        shelfConfig.titleLineBreakMode = .byCharWrapping
        shelfConfig.cornerStyle = .fixed
        shelfConfig.background.cornerRadius = 0
        shelfButton.configuration = shelfConfig
        shelfButton.tintColor = BookDetailActionPalette.shelfText

        var readConfig = UIButton.Configuration.filled()
        readConfig.title = L10n.BookDetail.primaryActionRead
        readConfig.baseBackgroundColor = AndroidReplicaTheme.accent
        readConfig.baseForegroundColor = BookDetailActionPalette.accentText
        readConfig.cornerStyle = .fixed
        readConfig.background.cornerRadius = 0
        readConfig.contentInsets = shelfConfig.contentInsets
        readConfig.titleAlignment = .center
        readConfig.titleLineBreakMode = .byCharWrapping
        readButton.configuration = readConfig
        readButton.configurationUpdateHandler = { button in
            var configuration = button.configuration
            let highlighted = button.isHighlighted
            configuration?.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in
                highlighted ? BookDetailActionPalette.pressedAccent : AndroidReplicaTheme.accent
            }
            button.configuration = configuration
        }
        for button in [shelfButton, readButton] {
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byCharWrapping
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.adjustsFontSizeToFitWidth = false
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            (button as? BookDetailActionButton)?.onLayoutChange = { [weak self] in
                self?.setNeedsLayout()
            }
        }
        updateActionBarTypography()
    }

    @objc private func refreshPalette() {
        actionBarBackground.backgroundColor = AndroidReplicaTheme.bottomBackground
        bottomBar.backgroundColor = AndroidReplicaTheme.bottomBackground
        shelfButton.tintColor = BookDetailActionPalette.shelfText
        var shelfConfiguration = shelfButton.configuration
        shelfConfiguration?.baseForegroundColor = BookDetailActionPalette.shelfText
        shelfButton.configuration = shelfConfiguration
        var readConfiguration = readButton.configuration
        readConfiguration?.baseBackgroundColor = AndroidReplicaTheme.accent
        readConfiguration?.baseForegroundColor = BookDetailActionPalette.accentText
        readButton.configuration = readConfiguration
        readButton.setNeedsUpdateConfiguration()
        if ReaderPaletteColor.isEInk {
            cancelBackdropRendering()
            renderedBackdropImage = nil
            renderedBackdropTarget = nil
            backgroundImageView.image = nil
        } else {
            isBackdropRenderingSuspended = false
            renderBackdropIfNeeded()
        }
    }

    private func updateActionBarTypography() {
        let font = AndroidReplicaBookDetailTypography.font(size: 15, compatibleWith: traitCollection)
        for button in [shelfButton, readButton] {
            var configuration = button.configuration
            configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming
                attributes.font = font
                return attributes
            }
            button.configuration = configuration
        }
        setNeedsLayout()
    }

    private func updateActionBarHeight() {
        let columnWidth = safeAreaLayoutGuide.layoutFrame.width / (usesColumns ? 2 : 1)
        guard columnWidth > 0 else { return }
        let font = AndroidReplicaBookDetailTypography.font(size: 15, compatibleWith: traitCollection)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        var height = Self.minimumActionBarHeight
        for button in [shelfButton, readButton] {
            let configuration = button.configuration
            let title: String
            if let attributedTitle = configuration?.attributedTitle {
                title = String(attributedTitle.characters)
            } else {
                title = configuration?.title ?? button.currentAttributedTitle?.string ?? button.currentTitle ?? ""
            }
            let insets = configuration?.contentInsets ?? .zero
            let textWidth = max(1, columnWidth / 2 - insets.leading - insets.trailing)
            let textHeight = (title as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph], context: nil
            ).height
            height = max(height, ceil(textHeight) + insets.top + insets.bottom)
        }
        if actionBarHeightConstraint.constant != height {
            actionBarHeightConstraint.constant = height
        }
        // Only the portrait XML has a separate 1px divider above the 50dp controls.
        let dividerHeight = usesColumns ? 0 : 1 / max(1, traitCollection.displayScale)
        actionBarDivider.isHidden = usesColumns
        if actionBarDividerHeightConstraint.constant != dividerHeight {
            actionBarDividerHeightConstraint.constant = dividerHeight
        }
        let reservedHeight = height + dividerHeight
        if contentView.reservedActionBarHeight != reservedHeight {
            contentView.reservedActionBarHeight = reservedHeight
        }
    }

    private func configureLayout() {
        for item in [
            backgroundImageView, dimView, topBar, contentView,
            actionBarBackground, bottomBar, actionBarDivider, spinner,
        ] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        for item in [shelfButton, readButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(item)
        }
        actionBarHeightConstraint = bottomBar.heightAnchor.constraint(equalToConstant: Self.minimumActionBarHeight)
        actionBarDividerHeightConstraint = actionBarDivider.heightAnchor.constraint(
            equalToConstant: 1 / max(1, traitCollection.displayScale))

        NSLayoutConstraint.activate([
            backgroundImageView.topAnchor.constraint(equalTo: topAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
            topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: contentView.actionColumnGuide.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.actionColumnGuide.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            actionBarHeightConstraint,
            actionBarBackground.topAnchor.constraint(equalTo: actionBarDivider.topAnchor),
            actionBarBackground.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            actionBarBackground.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            actionBarBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionBarDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            actionBarDivider.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            actionBarDivider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            actionBarDividerHeightConstraint,
            shelfButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            shelfButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            shelfButton.widthAnchor.constraint(equalTo: bottomBar.widthAnchor, multiplier: 0.5),
            shelfButton.heightAnchor.constraint(equalTo: bottomBar.heightAnchor),
            readButton.leadingAnchor.constraint(equalTo: shelfButton.trailingAnchor),
            readButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            readButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            readButton.heightAnchor.constraint(equalTo: bottomBar.heightAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class BookDetailActionButton: UIButton {
    var onLayoutChange: (() -> Void)?

    override func updateConfiguration() {
        super.updateConfiguration()
        onLayoutChange?()
    }

    override func setTitle(_ title: String?, for state: UIControl.State) {
        super.setTitle(title, for: state)
        onLayoutChange?()
    }

    override func setAttributedTitle(_ title: NSAttributedString?, for state: UIControl.State) {
        super.setAttributedTitle(title, for: state)
        onLayoutChange?()
    }
}

private enum BookDetailBackdropRenderer {
    struct Target: Equatable, Sendable {
        let pixelSize: CGSize
        let scale: CGFloat

        init?(size: CGSize, scale: CGFloat) {
            let width = ceil(size.width * scale)
            let height = ceil(size.height * scale)
            guard scale.isFinite, scale > 0, width.isFinite, height.isFinite, width > 0, height > 0
            else { return nil }
            pixelSize = CGSize(width: width, height: height)
            self.scale = scale
        }
    }

    // Only one bounded raster/convolution may allocate working storage at a time.
    private actor Worker {
        func render(_ image: UIImage, target: Target) -> UIImage? {
            autoreleasepool { BookDetailBackdropRenderer.makeBackdrop(image, target: target) }
        }
    }

    private static let worker = Worker()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .cacheIntermediates: false, .workingColorSpace: colorSpace,
    ])
    private static let maximumPixelDimension: CGFloat = 768
    private static let referenceBlurRadius: CGFloat = 25
    private static let referenceSigma: CGFloat = 0.4 * referenceBlurRadius + 0.6

    static func render(_ image: UIImage, target: Target) async -> UIImage? {
        let task = Task.detached(priority: .utility) {
            await worker.render(image, target: target)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func makeBackdrop(_ image: UIImage, target: Target) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let source: CIImage
        if let cgImage = image.cgImage {
            source = CIImage(cgImage: cgImage)
        } else if let ciImage = image.ciImage {
            source = ciImage
        } else {
            return nil
        }
        let oriented = source.oriented(forExifOrientation: exifOrientation(image.imageOrientation))
        let extent = oriented.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
            extent.origin.x.isFinite, extent.origin.y.isFinite,
            extent.width.isFinite, extent.height.isFinite
        else { return nil }
        // Glide CENTER_OUTSIDE decodes the whole cover at target pixels, including upscaling.
        // Never materialize that possibly large intermediate, or crop before the blur.
        let decodeScale = max(target.pixelSize.width / extent.width, target.pixelSize.height / extent.height)
        let decodedSize = CGSize(width: extent.width * decodeScale, height: extent.height * decodeScale)
        guard decodeScale.isFinite, decodeScale > 0,
            decodedSize.width.isFinite, decodedSize.height.isFinite,
            decodedSize.width > 0, decodedSize.height > 0
        else { return nil }
        let workingScale = min(1, maximumPixelDimension / max(decodedSize.width, decodedSize.height))
        let outputBounds = CGRect(
            x: 0, y: 0,
            width: min(maximumPixelDimension, max(1, floor(decodedSize.width * workingScale))),
            height: min(maximumPixelDimension, max(1, floor(decodedSize.height * workingScale))))
        let sampleScaleX = outputBounds.width / extent.width
        let sampleScaleY = outputBounds.height / extent.height
        let sampleAspectRatio = sampleScaleX / sampleScaleY
        guard sampleScaleX.isFinite, sampleScaleY.isFinite, sampleScaleX > 0, sampleScaleY > 0,
            sampleAspectRatio.isFinite, sampleAspectRatio > 0
        else { return nil }
        let sampled = oriented.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .clampedToExtent()
            .applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: sampleScaleY, kCIInputAspectRatioKey: sampleAspectRatio,
                ])
        // Both sampling and the materialized bytes use encoded sRGB, not CI's default linear space.
        guard !Task.isCancelled,
            let reduced = context.createCGImage(sampled, from: outputBounds, format: .RGBA8, colorSpace: colorSpace),
            !Task.isCancelled
        else { return nil }
        return convolve(
            reduced, horizontalScale: outputBounds.width / decodedSize.width,
            verticalScale: outputBounds.height / decodedSize.height)
    }

    private static func convolve(_ image: CGImage, horizontalScale: CGFloat, verticalScale: CGFloat) -> UIImage? {
        let width = image.width
        let height = image.height
        guard !Task.isCancelled,
            horizontalScale.isFinite, verticalScale.isFinite,
            horizontalScale > 0, horizontalScale <= 1, verticalScale > 0, verticalScale <= 1,
            width > 0, height > 0,
            width <= Int(maximumPixelDimension), height <= Int(maximumPixelDimension),
            let bytes = calloc(height, width * 4)
        else { return nil }
        defer { free(bytes) }
        guard
            let bitmap = CGContext(
                data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        bitmap.setBlendMode(.copy)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let floatRowBytes = width * 4 * MemoryLayout<Float>.stride
        guard !Task.isCancelled, let floatData = malloc(height * floatRowBytes) else { return nil }
        defer { free(floatData) }
        guard let scratchData = malloc(height * floatRowBytes) else { return nil }
        defer { free(scratchData) }
        let flags = vImage_Flags(kvImageNoFlags)
        // Treat the interleaved channels as a wider planar row only for numeric conversion.
        // Preserve byte-domain, premultiplied ARGB (including alpha) throughout both float passes.
        var byteChannels = vImage_Buffer(
            data: bytes, height: vImagePixelCount(height), width: vImagePixelCount(width * 4), rowBytes: width * 4)
        var floatChannels = vImage_Buffer(
            data: floatData, height: vImagePixelCount(height), width: vImagePixelCount(width * 4),
            rowBytes: floatRowBytes)
        guard vImageConvert_Planar8toPlanarF(&byteChannels, &floatChannels, 255, 0, flags) == kvImageNoError,
            !Task.isCancelled
        else { return nil }
        var source = vImage_Buffer(
            data: floatData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)
        var scratch = vImage_Buffer(
            data: scratchData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)
        let verticalKernel = gaussianKernel(scale: verticalScale)
        let horizontalKernel = gaussianKernel(scale: horizontalScale)
        let edgeFlags = vImage_Flags(kvImageEdgeExtend)
        guard
            vImageConvolve_ARGBFFFF(
                &source, &scratch, nil, 0, 0, verticalKernel, UInt32(verticalKernel.count), 1, nil, edgeFlags
            ) == kvImageNoError, !Task.isCancelled
        else { return nil }
        guard
            vImageConvolve_ARGBFFFF(
                &scratch, &source, nil, 0, 0, horizontalKernel, 1, UInt32(horizontalKernel.count), nil, edgeFlags
            ) == kvImageNoError, !Task.isCancelled
        else { return nil }
        guard vImageConvert_PlanarFtoPlanar8(&floatChannels, &byteChannels, 255, 0, flags) == kvImageNoError,
            !Task.isCancelled, let result = bitmap.makeImage(), !Task.isCancelled
        else { return nil }
        return UIImage(cgImage: result)
    }

    private static func gaussianKernel(scale: CGFloat) -> [Float] {
        // Toolkit 8eaa829ddd: radius 25, sigma 10.6, normalized finite 51-tap kernel at native target size.
        // Scale both support and sigma; the 0.6 term must not be re-added after downsampling.
        let radius = Int(ceil(referenceBlurRadius * scale))
        let sigma = Double(referenceSigma * scale)
        guard radius > 0, sigma > 0 else { return [1] }
        let weights = (-radius...radius).map { offset -> Float in
            let distance = Double(offset) / sigma
            return Float(exp(-0.5 * distance * distance))
        }
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }

    private static func exifOrientation(_ orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }
}
