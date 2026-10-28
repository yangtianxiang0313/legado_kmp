import Foundation
import ImageIO
import UIKit

final class MangaImagePresentation: NSObject, @unchecked Sendable {
    let bitmap: UIImage?
    let tiled: MangaTiledImage?
    let sourcePixelWidth: Int

    var pixelSize: CGSize {
        if let tiled { return tiled.pixelSize }
        guard let bitmap else { return .zero }
        if let image = bitmap.cgImage {
            return CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        }
        return CGSize(width: bitmap.size.width * bitmap.scale, height: bitmap.size.height * bitmap.scale)
    }

    var cacheCost: Int {
        if let tiled {
            // Charge disk ownership too, so the presentation cache cannot retain many large assets.
            return tiled.diskCost + Self.imageCost(tiled.preview) + MangaTiledImage.memoryLimit + tiled.tiles.count * 256
        }
        return bitmap.map(Self.imageCost) ?? 0
    }

    init(bitmap: UIImage, sourcePixelWidth: Int) {
        self.bitmap = bitmap
        self.sourcePixelWidth = sourcePixelWidth
        tiled = nil
        super.init()
    }

    init(tiled: MangaTiledImage, sourcePixelWidth: Int) {
        bitmap = nil
        self.tiled = tiled
        self.sourcePixelWidth = sourcePixelWidth
        super.init()
    }

    static func imageCost(_ image: UIImage) -> Int {
        guard let bitmap = image.cgImage else { return 0 }
        let (cost, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.height)
        return overflow ? Int.max : cost
    }
}

struct MangaImageTile: Sendable {
    let index: Int
    // Top-left origin in normalized output pixels. Adjacent frames do not overlap.
    let frame: CGRect
    let fileURL: URL
}

final class MangaTiledImage: @unchecked Sendable {
    let pixelSize: CGSize
    let preview: UIImage
    let tiles: [MangaImageTile]
    let diskCost: Int

    static let memoryLimit = 16 * 1024 * 1024
    private static let countLimit = 8
    private let directory: URL
    private let lock = NSLock()
    private let cache = NSCache<NSNumber, UIImage>()
    private var costs: [Int: Int] = [:]
    private var recency: [Int] = []
    private var memoryCost = 0

    init(pixelSize: CGSize, preview: UIImage, tiles: [MangaImageTile], directory: URL, diskCost: Int) {
        self.pixelSize = pixelSize
        self.preview = preview
        self.tiles = tiles
        self.directory = directory
        self.diskCost = diskCost
        cache.totalCostLimit = Self.memoryLimit
        cache.countLimit = Self.countLimit
    }

    deinit {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
    }

    func image(at index: Int) throws -> UIImage {
        try Task.checkCancellation()
        // Serialize both disk loads and cache resets. A reset cannot be undone by an older in-flight load.
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        guard tiles.indices.contains(index), tiles[index].index == index else {
            throw failure("图片分片索引无效")
        }
        if let image = cache.object(forKey: NSNumber(value: index)) {
            recency.removeAll { $0 == index }
            recency.append(index)
            return image
        }
        forget(index)
        let tile = tiles[index]
        let image: UIImage = try autoreleasepool {
            guard
                let source = CGImageSourceCreateWithURL(
                    tile.fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) == 1,
                CGImageSourceGetStatus(source) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == Int(tile.frame.width),
                (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == Int(tile.frame.height)
            else { throw failure("图片分片已失效，请重新加载原图") }
            try Task.checkCancellation()
            guard
                let decoded = CGImageSourceCreateImageAtIndex(
                    source, 0,
                    [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                decoded.width == Int(tile.frame.width), decoded.height == Int(tile.frame.height),
                CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
            else { throw failure("图片分片解码失败，请重新加载原图") }
            try Task.checkCancellation()
            return UIImage(cgImage: decoded)
        }
        try Task.checkCancellation()
        let cost = MangaImagePresentation.imageCost(image)
        // NSCache's own limits are advisory. Enforce a conservative hard bound as well.
        if cost <= Self.memoryLimit {
            while !recency.isEmpty && (recency.count >= Self.countLimit || memoryCost > Self.memoryLimit - cost) {
                forget(recency[0])
            }
            costs[index] = cost
            recency.append(index)
            memoryCost += cost
            cache.setObject(image, forKey: NSNumber(value: index), cost: cost)
        }
        return image
    }

    func clearMemory() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
        costs.removeAll()
        recency.removeAll()
        memoryCost = 0
    }

    private func forget(_ index: Int) {
        cache.removeObject(forKey: NSNumber(value: index))
        if let cost = costs.removeValue(forKey: index) { memoryCost -= cost }
        recency.removeAll { $0 == index }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.manga.image", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
