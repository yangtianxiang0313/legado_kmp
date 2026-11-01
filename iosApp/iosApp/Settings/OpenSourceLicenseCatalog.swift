import Foundation

enum OpenSourceLicenseCategory: String, Decodable, CaseIterable, Sendable {
    case project
    case library
    case resource
}

struct OpenSourceLicenseDocument: Decodable, Sendable {
    let title: String
    let resource: String
    let fileExtension: String
    let subdirectory: String?
}

struct OpenSourceLicenseComponent: Decodable, Sendable {
    let id: String
    let title: String
    let license: String
    let category: OpenSourceLicenseCategory
    let homepage: URL?
    let documents: [OpenSourceLicenseDocument]
}

enum OpenSourceLicenseCatalogError: Error, LocalizedError {
    case missingCatalog
    case unreadableCatalog
    case malformedCatalog
    case unsupportedVersion
    case emptyCatalog
    case invalidComponentID
    case duplicateComponentID
    case invalidComponentTitle
    case invalidLicenseName
    case missingDocuments
    case invalidDocumentTitle
    case invalidDocumentPath
    case duplicateDocument
    case invalidHomepage
    case missingDocument
    case unreadableDocument
    case invalidUTF8Document
    case emptyDocument

    var errorDescription: String? {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        let isChinese = Locale(identifier: preferredLanguage).languageCode == "zh"
        switch self {
        case .missingCatalog:
            return isChinese ? "找不到开源许可清单。" : "The open-source license catalog is missing."
        case .unreadableCatalog:
            return isChinese ? "无法读取开源许可清单。" : "The open-source license catalog could not be read."
        case .malformedCatalog:
            return isChinese ? "开源许可清单格式无效。" : "The open-source license catalog is malformed."
        case .unsupportedVersion:
            return isChinese ? "不支持此开源许可清单版本。" : "This license catalog version is not supported."
        case .emptyCatalog:
            return isChinese ? "开源许可清单没有组件。" : "The license catalog contains no components."
        case .invalidComponentID:
            return isChinese ? "许可组件标识为空或格式无效。" : "A license component ID is empty or invalid."
        case .duplicateComponentID:
            return isChinese ? "开源许可清单包含重复组件标识。" : "The license catalog contains duplicate component IDs."
        case .invalidComponentTitle:
            return isChinese ? "许可组件标题为空。" : "A license component title is empty."
        case .invalidLicenseName:
            return isChinese ? "许可名称为空。" : "A license name is empty."
        case .missingDocuments:
            return isChinese ? "许可组件没有文档。" : "A license component has no documents."
        case .invalidDocumentTitle:
            return isChinese ? "许可文档标题为空。" : "A license document title is empty."
        case .invalidDocumentPath:
            return isChinese ? "许可文档资源名称、目录或扩展名无效。" : "A license document resource, directory, or extension is invalid."
        case .duplicateDocument:
            return isChinese ? "许可组件包含重复文档。" : "A license component contains duplicate documents."
        case .invalidHomepage:
            return isChinese
                ? "组件主页必须是无用户名和密码且主机非空的 HTTPS 地址。" : "A component homepage must use HTTPS with a nonempty host and no credentials."
        case .missingDocument:
            return isChinese ? "找不到许可文档。" : "A license document is missing."
        case .unreadableDocument:
            return isChinese ? "无法读取许可文档。" : "A license document could not be read."
        case .invalidUTF8Document:
            return isChinese ? "许可文档不是有效的 UTF-8 文本。" : "A license document is not valid UTF-8 text."
        case .emptyDocument:
            return isChinese ? "许可文档内容为空。" : "A license document is empty."
        }
    }
}

enum OpenSourceLicenseCatalog {
    private struct Catalog: Decodable {
        let version: Int
        let components: [OpenSourceLicenseComponent]
    }

    static func load(in bundle: Bundle = .main) throws -> [OpenSourceLicenseComponent] {
        guard let url = bundle.url(forResource: "OpenSourceLicenses", withExtension: "json", subdirectory: nil) else {
            throw OpenSourceLicenseCatalogError.missingCatalog
        }
        guard isLocalResource(url, in: bundle) else { throw OpenSourceLicenseCatalogError.unreadableCatalog }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OpenSourceLicenseCatalogError.unreadableCatalog
        }
        let catalog: Catalog
        do {
            catalog = try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            // Decoding and filesystem errors can include absolute paths or untrusted input.
            throw OpenSourceLicenseCatalogError.malformedCatalog
        }
        guard catalog.version == 1 else { throw OpenSourceLicenseCatalogError.unsupportedVersion }
        guard !catalog.components.isEmpty else { throw OpenSourceLicenseCatalogError.emptyCatalog }
        var identifiers = Set<String>()
        for component in catalog.components {
            try validate(component)
            guard identifiers.insert(component.id).inserted else {
                throw OpenSourceLicenseCatalogError.duplicateComponentID
            }
        }
        return catalog.components
    }

    static func readText(for component: OpenSourceLicenseComponent, in bundle: Bundle = .main) throws -> String {
        // Also validate values constructed directly by a caller, not just decoded catalog entries.
        try validate(component)
        var sections: [String] = []
        for document in component.documents {
            guard
                let url = bundle.url(
                    forResource: document.resource,
                    withExtension: document.fileExtension,
                    subdirectory: normalizedDirectory(document.subdirectory)
                )
            else {
                throw OpenSourceLicenseCatalogError.missingDocument
            }
            guard isLocalResource(url, in: bundle) else { throw OpenSourceLicenseCatalogError.invalidDocumentPath }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw OpenSourceLicenseCatalogError.unreadableDocument
            }
            guard String(data: data, encoding: .utf8) != nil else {
                throw OpenSourceLicenseCatalogError.invalidUTF8Document
            }
            // Foundation validates UTF-8 but removes its BOM; decode the validated bytes without stripping it.
            let text = String(decoding: data, as: UTF8.self)
            let emptyCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
            guard !text.trimmingCharacters(in: emptyCharacters).isEmpty else {
                throw OpenSourceLicenseCatalogError.emptyDocument
            }
            // Only the emptiness check trims; every original character is retained in the output.
            sections.append(document.title + "\n\n" + text)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func validate(_ component: OpenSourceLicenseComponent) throws {
        guard isNonblank(component.id), component.id == component.id.trimmingCharacters(in: .whitespacesAndNewlines),
            component.id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw OpenSourceLicenseCatalogError.invalidComponentID }
        guard isNonblank(component.title) else { throw OpenSourceLicenseCatalogError.invalidComponentTitle }
        guard isNonblank(component.license) else { throw OpenSourceLicenseCatalogError.invalidLicenseName }
        if let homepage = component.homepage {
            guard let parts = URLComponents(url: homepage, resolvingAgainstBaseURL: false),
                parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
                let host = parts.host, isNonblank(host),
                host.unicodeScalars.allSatisfy({
                    !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
                })
            else { throw OpenSourceLicenseCatalogError.invalidHomepage }
        }
        guard !component.documents.isEmpty else { throw OpenSourceLicenseCatalogError.missingDocuments }
        var documentPaths = Set<String>()
        for document in component.documents {
            guard isNonblank(document.title) else { throw OpenSourceLicenseCatalogError.invalidDocumentTitle }
            guard isPathSegment(document.resource), ["txt", "md"].contains(document.fileExtension) else {
                throw OpenSourceLicenseCatalogError.invalidDocumentPath
            }
            let directory = normalizedDirectory(document.subdirectory)
            if let directory {
                let segments = directory.split(separator: "/", omittingEmptySubsequences: false)
                guard segments.allSatisfy({ isPathSegment(String($0)) }) else {
                    throw OpenSourceLicenseCatalogError.invalidDocumentPath
                }
            }
            let path = (directory.map { $0 + "/" } ?? "") + document.resource + "." + document.fileExtension
            guard documentPaths.insert(path).inserted else { throw OpenSourceLicenseCatalogError.duplicateDocument }
        }
    }

    private static func isNonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        return directory
    }

    private static func isLocalResource(_ url: URL, in bundle: Bundle) -> Bool {
        guard url.isFileURL, bundle.bundleURL.isFileURL else { return false }
        let root = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return target.count > root.count && target.starts(with: root)
    }

    private static func isPathSegment(_ value: String) -> Bool {
        isNonblank(value) && value != "." && !value.contains("..") && !value.contains("/") && !value.contains("\\") && !value.contains("%")
            && !value.contains(":") && value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    }
}
