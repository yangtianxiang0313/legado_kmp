import Foundation
import ImageIO
import UIKit
import shared

enum RssArticleThumbnailLoader {
    static func hasNonBlankImage(_ image: String?) -> Bool {
        guard let image else { return false }
        return image.unicodeScalars.contains { scalar in
            // Kotlin isBlank uses Character.isWhitespace || Character.isSpaceChar.
            if (0x09...0x0D).contains(scalar.value) || (0x1C...0x1F).contains(scalar.value) { return false }
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }

    @MainActor
    static func loadImage(article: RssArticle, cacheOnly: Bool = false) async throws -> UIImage? {
        try Task.checkCancellation()
        guard hasNonBlankImage(article.image) else { return nil }
        let facade = try RssArticleThumbnailFacade.companion.create()
        let result: RssArticleThumbnailResult = try await SharedCancellableAsync.value { completion in
            facade.loadImage(article: article, cacheOnly: cacheOnly) { result in
                completion(result.isCancelled ? nil : result, result.isCancelled ? CancellationError() : nil)
            }
        }
        try Task.checkCancellation()
        guard result.errorMessage == nil, let base64 = result.imageBase64, !base64.isEmpty else { return nil }

        // Decode the raw Base64 and thumbnail pixels off-main, without materializing a full-size UIImage.
        let decoder = Task.detached(priority: .userInitiated) { () throws -> UIImage? in
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let data = Data(base64Encoded: base64) else { return nil }
                try Task.checkCancellation()
                guard
                    let source = CGImageSourceCreateWithData(
                        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 330,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                try Task.checkCancellation()
                return UIImage(cgImage: thumbnail)
            }
        }
        return try await withTaskCancellationHandler {
            let image = try await decoder.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            decoder.cancel()
        }
    }
}
