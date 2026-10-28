import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BookInfoEditCoverFiles {
    static func copyCover(from url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) {
            readableURL in
            result = Result {
                guard let source = CGImageSourceCreateWithURL(readableURL as CFURL, nil),
                    CGImageSourceGetCount(source) > 0,
                    let identifier = CGImageSourceGetType(source),
                    let type = UTType(identifier as String), type.conforms(to: .image)
                else {
                    throw NSError(
                        domain: "BookInfoEditCover", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "所选文件不是可读取的图片。"])
                }
                let manager = FileManager.default
                let support = try manager.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let covers = support.appendingPathComponent("covers", isDirectory: true)
                try manager.createDirectory(at: covers, withIntermediateDirectories: true)
                let destination = covers.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(type.preferredFilenameExtension ?? "img")
                do {
                    try manager.copyItem(at: readableURL, to: destination)
                    return destination
                } catch {
                    try? manager.removeItem(at: destination)
                    throw error
                }
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
    }
}
