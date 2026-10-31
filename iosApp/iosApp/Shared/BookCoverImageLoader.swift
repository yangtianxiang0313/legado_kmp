import Foundation
import ImageIO
import UIKit
import shared

enum BookCoverImageLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func loadDecodedCover(searchBook: SearchBook) async -> UIImage? {
        let policy = CoverConfigurationLoadingPolicy()
        guard !Task.isCancelled, !policy.usesDefaultCover,
            let cover = searchBook.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
            !cover.isEmpty, cover != "use_default_cover"
        else { return nil }
        let key = searchCoverCacheKey(for: searchBook)
        if let cached = cache.object(forKey: key) { return cached }
        guard !policy.cacheOnly else { return nil }
        guard case .success(let facade) = SharedRuntime.bookImageFacade() else { return nil }
        do {
            guard let base64 = try await facade.loadSearchCoverBase64Async(candidate: searchBook),
                !Task.isCancelled, !CoverConfigurationLoadingPolicy().usesDefaultCover,
                let data = Data(base64Encoded: base64), let image = UIImage(data: data)
            else { return nil }
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    static func loadDecodedCover(book: Book) async -> UIImage? {
        let policy = CoverConfigurationLoadingPolicy()
        guard !Task.isCancelled, !policy.usesDefaultCover else { return nil }
        let cacheKey = coverCacheKey(for: book)
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard book.displayCoverUrl?.isEmpty == false else {
            return nil
        }
        if let localURL = localImageURL(book.displayCoverUrl ?? "") {
            guard let image = await loadLocalImage(localURL), !Task.isCancelled,
                !CoverConfigurationLoadingPolicy().usesDefaultCover
            else { return nil }
            cache.setObject(image, forKey: cacheKey)
            return image
        }
        guard case .success(let facade) = SharedRuntime.bookImageFacade() else {
            return nil
        }
        do {
            let base64: String? = try await SharedAsync.optionalValue { completion in
                facade.loadBookCoverBase64(
                    bookUrl: book.bookUrl, useDefaultCover: false, loadOnlyWifi: policy.cacheOnly,
                    completionHandler: completion)
            }
            guard let base64, !Task.isCancelled, !CoverConfigurationLoadingPolicy().usesDefaultCover,
                let data = Data(base64Encoded: base64),
                let image = UIImage(data: data)
            else {
                return nil
            }
            cache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            SharedRuntime.log("decoded cover load failed")
            return nil
        }
    }

    static func loadDecodedImage(bookUrl: String, imageUrl: String, isCover: Bool, refresh: Bool = false) async
        -> UIImage?
    {
        guard !Task.isCancelled else { return nil }
        let normalizedUrl = imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let policy = CoverConfigurationLoadingPolicy()
        guard normalizedUrl.isEmpty == false, !isCover || !policy.usesDefaultCover else {
            return nil
        }
        let cacheKey = imageCacheKey(bookUrl: bookUrl, imageUrl: normalizedUrl, isCover: isCover)
        if refresh {
            cache.removeObject(forKey: cacheKey)
        } else if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if isCover, let localURL = localImageURL(normalizedUrl) {
            guard let image = await loadLocalImage(localURL), !Task.isCancelled,
                !CoverConfigurationLoadingPolicy().usesDefaultCover
            else { return nil }
            cache.setObject(image, forKey: cacheKey)
            return image
        }
        guard !isCover || !policy.cacheOnly else { return nil }
        guard case .success(let facade) = SharedRuntime.bookImageFacade() else {
            return nil
        }
        do {
            let base64: String?
            if refresh {
                base64 = try await facade.refreshBookImageBase64Async(
                    bookUrl: bookUrl, imageUrl: normalizedUrl, isCover: isCover)
            } else {
                base64 = try await facade.loadBookImageBase64Async(
                    bookUrl: bookUrl,
                    imageUrl: normalizedUrl,
                    isCover: isCover
                )
            }
            guard
                let base64,
                let data = Data(base64Encoded: base64),
                let image = UIImage(data: data), !Task.isCancelled,
                !isCover || !CoverConfigurationLoadingPolicy().usesDefaultCover
            else {
                return nil
            }
            cache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            SharedRuntime.log("decoded image load failed")
            return nil
        }
    }

    static func loadImageData(bookUrl: String, imageUrl: String, refresh: Bool = false) async throws -> Data? {
        try Task.checkCancellation()
        let facade = try SharedRuntime.bookImageFacade().get()
        let encoded: String?
        if refresh {
            encoded = try await facade.refreshBookImageBase64Async(bookUrl: bookUrl, imageUrl: imageUrl, isCover: false)
        } else {
            encoded = try await facade.loadBookImageBase64Async(bookUrl: bookUrl, imageUrl: imageUrl, isCover: false)
        }
        try Task.checkCancellation()
        guard let encoded, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: imageCacheKey(bookUrl: bookUrl, imageUrl: imageUrl, isCover: false))
        return data
    }

    static func coverCacheKey(for book: Book) -> NSString {
        let inputs: [String?] = [
            book.bookUrl, book.origin, book.name, book.author, book.coverUrl, book.customCoverUrl, book.variable,
        ]
        // Image rules can read book metadata/variables; URL-only keys can return an older resolved cover.
        guard let data = try? JSONEncoder().encode(inputs) else { return UUID().uuidString as NSString }
        return String(decoding: data, as: UTF8.self) as NSString
    }

    static func searchCoverCacheKey(for book: SearchBook) -> NSString {
        let inputs: [String?] = [
            "search", book.bookUrl, book.origin, book.coverUrl, book.name, book.author,
            book.originName, book.tocUrl, book.variable,
        ]
        guard let data = try? JSONEncoder().encode(inputs) else { return UUID().uuidString as NSString }
        return String(decoding: data, as: UTF8.self) as NSString
    }

    static func localImageURL(_ path: String) -> URL? {
        let fileURL = URL(string: path).flatMap { $0.isFileURL ? $0 : nil }
        let localPath = fileURL?.path ?? path
        let marker = "/Library/Application Support/covers/"
        if localPath.contains("/Containers/Data/Application/"), let range = localPath.range(of: marker) {
            let relative = String(localPath[range.upperBound...])
            if !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            {
                let rebound = support.appendingPathComponent("covers").appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: rebound.path) { return rebound }
            }
        }
        if let fileURL { return fileURL }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func loadLocalImage(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                    ] as CFDictionary)
            else { return nil }
            return UIImage(cgImage: image)
        }.value
    }

    static func imageCacheKey(bookUrl: String, imageUrl: String, isCover: Bool) -> NSString {
        "\(bookUrl)|\(imageUrl)|\(isCover)" as NSString
    }
}
