import Foundation

/// The optional filename belongs to this selection, not to the deduplicated font catalog.
struct ReaderFontSelectionToken {
    let catalogIdentifier: String
    let filename: String?
    private static let prefix = "reader-font:"
    private static let separator = "#filename-v1="

    init?(identifier: String) {
        let parts = identifier.components(separatedBy: Self.separator)
        guard parts.count <= 2, let base = parts.first, base.hasPrefix(Self.prefix),
            UUID(uuidString: String(base.dropFirst(Self.prefix.count)))?.uuidString == String(base.dropFirst(Self.prefix.count))
        else { return nil }
        catalogIdentifier = base
        if parts.count == 1 {
            filename = nil
        } else {
            guard parts[1].utf8.count <= 1_368, let data = Data(base64Encoded: parts[1]),
                let decoded = String(data: data, encoding: .utf8), Self.isValidFilename(decoded)
            else { return nil }
            filename = decoded
        }
    }

    static func preservingFilename(_ filename: String, for identifier: String) -> String? {
        guard let token = Self(identifier: identifier), isValidFilename(filename) else { return nil }
        return token.catalogIdentifier + separator + Data(filename.utf8).base64EncodedString()
    }

    private static func isValidFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename.utf8.count <= 1_024 && !filename.utf8.contains(0)
            && (filename as NSString).lastPathComponent == filename
            && ["ttf", "otf"].contains((filename as NSString).pathExtension.lowercased())
    }
}
