import Foundation
import UniformTypeIdentifiers

enum LocalBookArchiveType: String, CaseIterable {
    case zip
    case rar
    case sevenZip = "7z"

    static let extensions = Set(allCases.map(\.rawValue))
    static let pickerTypes: [UTType] = {
        var types: [UTType] = []
        for format in allCases {
            let type = format == .zip ? UTType.zip : (UTType(filenameExtension: format.rawValue) ?? .data)
            if !types.contains(type) { types.append(type) }
        }
        return types
    }()

    init?(fileName: String) {
        self.init(rawValue: (fileName as NSString).pathExtension.lowercased())
    }

    static func isArchive(fileExtension: String) -> Bool {
        extensions.contains(fileExtension.lowercased())
    }

    var displayName: String {
        self == .sevenZip ? "7z" : rawValue.uppercased()
    }
}

enum LocalBookFormats {
    static let bookExtensions: Set<String> = ["txt", "epub", "pdf", "umd", "mobi", "azw", "azw3"]
    static let importExtensions = bookExtensions.union(LocalBookArchiveType.extensions)
    static let pickerTypes: [UTType] =
        [.plainText, .epub, .pdf] + LocalBookArchiveType.pickerTypes
        + ["umd", "mobi", "azw", "azw3"].compactMap { UTType(filenameExtension: $0) }

    static let unsupportedMessage = "请选择 TXT、EPUB、PDF、UMD、MOBI/AZW3 或 ZIP、RAR、7z 压缩包；不支持 DRM"
}
