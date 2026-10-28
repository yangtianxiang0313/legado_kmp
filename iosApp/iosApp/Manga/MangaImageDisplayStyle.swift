import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum MangaImageDisplayStyle: Equatable, Hashable, Sendable {
    case original
    case grayscale
    case eInk(threshold: Int)

    var normalized: Self {
        if case .eInk(let threshold) = self {
            return .eInk(threshold: min(255, max(0, threshold)))
        }
        return self
    }
}

enum MangaImageDisplayRenderer {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    // Match Android's encoded RGB arithmetic, including strips beyond GPU texture limits.
    private static let context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .workingFormat: CIFormat.RGBA8.rawValue,
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])

    static func render(
        _ image: CGImage, displayStyle: MangaImageDisplayStyle, colorFilter: MangaColorFilter = .init()
    ) throws -> CGImage {
        // Android filters the already transformed bitmap, after its 8-bit gray/eInk quantization.
        let styled = try renderDisplayStyle(image, displayStyle: displayStyle)
        try Task.checkCancellation()
        if colorFilter.identityPixel { return styled }
        guard styled.width <= 32768, styled.height <= 32768, styled.width * styled.height <= 10_000_000 else {
            throw failure()
        }
        let input = CIImage(cgImage: styled)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = input
        // Scale straight RGBA, including source transparency; l is window brightness, not a bias.
        matrix.rVector = CIVector(x: CGFloat(Float(255 - colorFilter.r) / 255), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(Float(255 - colorFilter.g) / 255), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(Float(255 - colorFilter.b) / 255), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(Float(255 - colorFilter.a) / 255))
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let output = matrix.outputImage else { throw failure() }
        try Task.checkCancellation()
        guard let rendered = context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw failure()
        }
        try Task.checkCancellation()
        return rendered
    }

    private static func renderDisplayStyle(_ image: CGImage, displayStyle: MangaImageDisplayStyle) throws -> CGImage {
        try Task.checkCancellation()
        let style = displayStyle.normalized
        if style == .original { return image }
        guard image.width <= 32768, image.height <= 32768, image.width * image.height <= 10_000_000 else {
            throw failure()
        }
        let input = CIImage(cgImage: image)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = input
        let weights: CIVector
        switch style {
        case .original:
            return image
        case .grayscale:
            weights = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        case .eInk:
            // Android ColorMatrix.setSaturation(0), not GrayscaleTransformation's weights.
            weights = CIVector(x: 0.213, y: 0.715, z: 0.072, w: 0)
        }
        matrix.rVector = weights
        matrix.gVector = weights
        matrix.bVector = weights
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard var output = matrix.outputImage else { throw failure() }
        if case .eInk(let threshold) = style {
            if threshold == 0 {
                matrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
                matrix.gVector = matrix.rVector
                matrix.bVector = matrix.rVector
                matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
                guard let white = matrix.outputImage else { throw failure() }
                output = white
            } else {
                let binarize = CIFilter.colorThreshold()
                binarize.inputImage = output
                // Android compares the rounded 8-bit gray value using gray < threshold.
                binarize.threshold = (Float(threshold) - 0.5) / 255
                guard let binary = binarize.outputImage else { throw failure() }
                output = binary
            }
        }
        try Task.checkCancellation()
        // Both filters preserve alpha; never composite transparent pixels onto black/white.
        guard let rendered = context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw failure()
        }
        try Task.checkCancellation()
        return rendered
    }

    private static func failure() -> NSError {
        NSError(domain: "io.legado.manga.image", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片显示效果处理失败"])
    }
}
