import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import UIKit

enum MangaImageTileStore {
    private static let sourceByteLimit = 64 * 1024 * 1024
    private static let sourcePixelLimit = 64_000_000
    private static let bitmapPixelLimit = 10_000_000
    private static let bitmapEdgeLimit = 32768
    private static let tilePixelLimit = 4_000_000
    private static let diskLimit = 256 * 1024 * 1024
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let processDirectory: URL = {
        let temporary = FileManager.default.temporaryDirectory
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let candidates =
            (try? FileManager.default.contentsOfDirectory(
                at: temporary, includingPropertiesForKeys: Array(keys))) ?? []
        for candidate in candidates where candidate.lastPathComponent.hasPrefix("legado-manga-") {
            let suffix = candidate.lastPathComponent.dropFirst("legado-manga-".count)
            guard let separator = suffix.firstIndex(of: "-"),
                let pid = Int32(suffix[..<separator]), pid > 0,
                UUID(uuidString: String(suffix[suffix.index(after: separator)...])) != nil,
                let values = try? candidate.resourceValues(forKeys: keys),
                values.isDirectory == true, values.isSymbolicLink != true,
                kill(pid, 0) != 0, errno == ESRCH
            else { continue }
            // Only this implementation's orphaned directories from dead processes are removed.
            try? FileManager.default.removeItem(at: candidate)
        }
        return temporary.appendingPathComponent(
            "legado-manga-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    }()

    static func prepare(
        _ data: Data, pixelWidth: Int,
        displayStyle: MangaImageDisplayStyle, colorFilter: MangaColorFilter
    ) throws -> MangaImagePresentation {
        try autoreleasepool {
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= sourceByteLimit else {
                throw failure("原图片为空或超过 64 MiB")
            }
            guard pixelWidth > 0 else { throw failure("图片显示宽度无效") }
            guard
                let source = CGImageSourceCreateWithData(
                    data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetStatus(source) == .statusComplete
            else { throw failure("图片加载或解码失败") }
            let geometry = try inspect(source)
            try Task.checkCancellation()
            let width = min(4096, min(pixelWidth, geometry.orientedWidth))
            let height = max(
                1,
                Int(
                    (Double(geometry.orientedHeight) * Double(width)
                        / Double(geometry.orientedWidth)).rounded(.up)))
            let style = displayStyle.normalized
            let filter = colorFilter.pixelVariant
            if width > bitmapPixelLimit / height || max(width, height) > bitmapEdgeLimit {
                return try prepareTiles(
                    source, geometry: geometry, width: width, height: height,
                    displayStyle: style, colorFilter: filter)
            }
            return try prepareBitmap(
                source, geometry: geometry, pixelWidth: width, displayStyle: style, colorFilter: filter)
        }
    }

    private struct Geometry {
        let width: Int
        let height: Int
        let orientation: Int32

        var orientedWidth: Int { orientation >= 5 ? height : width }
        var orientedHeight: Int { orientation >= 5 ? width : height }
    }

    private static func inspect(_ source: CGImageSource) throws -> Geometry {
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 512 else { throw failure("图片帧数量无效或超过上限") }
        var totalPixels = 0
        var first: Geometry?
        for index in 0..<count {
            try Task.checkCancellation()
            guard
                CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            else { throw failure("图片帧不完整") }
            let width = try dimension(properties[kCGImagePropertyPixelWidth])
            let height = try dimension(properties[kCGImagePropertyPixelHeight])
            guard width <= sourcePixelLimit / height else { throw failure("原图片超过 64 MP") }
            let pixels = width * height
            guard totalPixels <= sourcePixelLimit - pixels else { throw failure("原图片各帧像素总量超过 64 MP") }
            totalPixels += pixels
            if index == 0 {
                let orientation: Int32
                if let value = properties[kCGImagePropertyOrientation] {
                    guard let number = value as? NSNumber,
                        number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                        (1...8).contains(number.intValue)
                    else { throw failure("原图片方向信息无效") }
                    orientation = number.int32Value
                } else {
                    orientation = 1
                }
                first = Geometry(width: width, height: height, orientation: orientation)
            }
        }
        guard let first else { throw failure("图片没有可显示的帧") }
        return first
    }

    private static func dimension(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber else { throw failure("图片缺少尺寸信息") }
        let value = number.doubleValue
        guard value.isFinite, value >= 1, value <= Double(sourcePixelLimit), value.rounded() == value else {
            throw failure("图片尺寸无效")
        }
        return Int(value)
    }

    private static func prepareBitmap(
        _ source: CGImageSource, geometry: Geometry, pixelWidth: Int,
        displayStyle: MangaImageDisplayStyle, colorFilter: MangaColorFilter
    ) throws -> MangaImagePresentation {
        try Task.checkCancellation()
        let longest = Double(max(geometry.orientedWidth, geometry.orientedHeight))
        let widthScale = min(1, Double(pixelWidth) / Double(geometry.orientedWidth))
        let budgetScale = sqrt((Double(bitmapPixelLimit) * 0.99) / Double(geometry.width * geometry.height))
        let scale = min(widthScale, min(Double(bitmapEdgeLimit) / longest, budgetScale))
        guard
            let decoded = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(floor(longest * scale))),
                ] as CFDictionary),
            decoded.width <= bitmapEdgeLimit, decoded.height <= bitmapEdgeLimit,
            decoded.width <= bitmapPixelLimit / decoded.height,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { throw failure("图片加载或解码失败") }
        try Task.checkCancellation()
        let rendered = try MangaImageDisplayRenderer.render(decoded, displayStyle: displayStyle, colorFilter: colorFilter)
        try Task.checkCancellation()
        return MangaImagePresentation(bitmap: UIImage(cgImage: rendered), sourcePixelWidth: geometry.orientedWidth)
    }

    private static func prepareTiles(
        _ source: CGImageSource, geometry: Geometry, width: Int, height: Int,
        displayStyle: MangaImageDisplayStyle, colorFilter: MangaColorFilter
    ) throws -> MangaImagePresentation {
        try Task.checkCancellation()
        let tileHeight = min(2048, max(1, tilePixelLimit / width))
        guard (height - 1) / tileHeight < 4096 else { throw failure("长图分片数量超过 4096 片上限") }
        // ImageIO may decode the complete source here. No region-decode guarantee is made.
        guard
            let decoded = CGImageSourceCreateImageAtIndex(
                source, 0,
                [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldAllowFloat: false,
                ] as CFDictionary),
            decoded.width == geometry.width, decoded.height == geometry.height,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { throw failure("长图解码失败") }
        defer { CGImageSourceRemoveCacheAtIndex(source, 0) }
        try Task.checkCancellation()
        let oriented = CIImage(cgImage: decoded).oriented(forExifOrientation: geometry.orientation)
        let extent = oriented.extent
        guard extent.width == CGFloat(geometry.orientedWidth), extent.height == CGFloat(geometry.orientedHeight),
            extent.minX.isFinite, extent.minY.isFinite
        else { throw failure("长图方向归一化失败") }
        let normalized = oriented.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let canvas = normalized.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(geometry.orientedWidth),
                y: CGFloat(height) / CGFloat(geometry.orientedHeight)))
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBA8.rawValue,
            .cacheIntermediates: false,
            .useSoftwareRenderer: true,
        ])
        defer { context.clearCaches() }
        try Task.checkCancellation()
        let directory = processDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: directory) }
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        let preview = try makePreview(
            normalized, context: context, geometry: geometry, width: width, height: height,
            displayStyle: displayStyle, colorFilter: colorFilter)
        var tiles: [MangaImageTile] = []
        tiles.reserveCapacity((height + tileHeight - 1) / tileHeight)
        var diskCost = 0
        var y = 0
        while y < height {
            try Task.checkCancellation()
            let frame = CGRect(
                x: 0, y: CGFloat(y), width: CGFloat(width), height: CGFloat(min(tileHeight, height - y)))
            let fileURL = directory.appendingPathComponent("\(tiles.count).png", isDirectory: false)
            let directoryCost = try allocatedSize(directory)
            guard directoryCost <= diskLimit - diskCost else { throw failure("长图分片超过 256 MiB 临时存储上限") }
            let remaining = diskLimit - diskCost - directoryCost
            let charge: Int = try autoreleasepool {
                try Task.checkCancellation()
                // Core Image uses a bottom-left origin; the public frames use a top-left origin.
                // A single global transform keeps sampling phase continuous across tile boundaries.
                let region = CGRect(x: frame.minX, y: CGFloat(height) - frame.maxY, width: frame.width, height: frame.height)
                guard
                    let tile = context.createCGImage(
                        canvas.cropped(to: region), from: region, format: .RGBA8, colorSpace: colorSpace),
                    tile.width == Int(frame.width), tile.height == Int(frame.height)
                else { throw failure("长图分片生成失败") }
                try Task.checkCancellation()
                let rendered = try MangaImageDisplayRenderer.render(
                    tile, displayStyle: displayStyle, colorFilter: colorFilter)
                try Task.checkCancellation()
                return try writePNG(rendered, to: fileURL, remaining: remaining)
            }
            diskCost += charge
            try Task.checkCancellation()
            guard try allocatedSize(directory) <= diskLimit - diskCost else {
                throw failure("长图分片超过 256 MiB 临时存储上限")
            }
            tiles.append(MangaImageTile(index: tiles.count, frame: frame, fileURL: fileURL))
            y += Int(frame.height)
        }
        try Task.checkCancellation()
        let directoryCost = try allocatedSize(directory)
        guard directoryCost <= diskLimit - diskCost else { throw failure("长图分片超过 256 MiB 临时存储上限") }
        let asset = MangaTiledImage(
            pixelSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            preview: preview, tiles: tiles, directory: directory, diskCost: diskCost + directoryCost)
        try Task.checkCancellation()
        let presentation = MangaImagePresentation(tiled: asset, sourcePixelWidth: geometry.orientedWidth)
        published = true
        return presentation
    }

    private static func makePreview(
        _ normalized: CIImage, context: CIContext, geometry: Geometry, width: Int, height: Int,
        displayStyle: MangaImageDisplayStyle, colorFilter: MangaColorFilter
    ) throws -> UIImage {
        try autoreleasepool {
            try Task.checkCancellation()
            let scale = min(1, min(2048 / Double(max(width, height)), sqrt(1_000_000 / Double(width * height))))
            let previewWidth = max(1, Int(floor(Double(width) * scale)))
            let previewHeight = max(1, Int(floor(Double(height) * scale)))
            let preview = normalized.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(previewWidth) / CGFloat(geometry.orientedWidth),
                    y: CGFloat(previewHeight) / CGFloat(geometry.orientedHeight)))
            guard
                let image = context.createCGImage(
                    preview, from: CGRect(x: 0, y: 0, width: CGFloat(previewWidth), height: CGFloat(previewHeight)),
                    format: .RGBA8, colorSpace: colorSpace)
            else { throw failure("长图概览生成失败") }
            try Task.checkCancellation()
            let rendered = try MangaImageDisplayRenderer.render(image, displayStyle: displayStyle, colorFilter: colorFilter)
            try Task.checkCancellation()
            return UIImage(cgImage: rendered)
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL, remaining: Int) throws -> Int {
        try Task.checkCancellation()
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw failure("长图分片编码失败")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw failure("长图分片编码失败") }
        try Task.checkCancellation()
        // Reserve allocation slack before writing; account for actual allocation after writing.
        guard encoded.length > 0, remaining >= 65536, encoded.length <= remaining - 65536 else {
            throw failure("长图分片超过 256 MiB 临时存储上限")
        }
        try (encoded as Data).write(to: url, options: .withoutOverwriting)
        try Task.checkCancellation()
        let charge = max(encoded.length, try allocatedSize(url))
        guard charge <= remaining else { throw failure("长图分片超过 256 MiB 临时存储上限") }
        return charge
    }

    private static func allocatedSize(_ url: URL) throws -> Int {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        return max(0, max(values.fileSize ?? 0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.manga.image", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
