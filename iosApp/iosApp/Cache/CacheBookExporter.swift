import Foundation
import shared

struct CacheBookExportResult {
    let files: [CacheExportFileLease]
    let uploadPayloads: [KotlinByteArray]
    let chapterCount: Int
    let readableChapterCount: Int
    let missingChapterCount: Int
    let missingImageCount: Int

    init(
        file: CacheExportFileLease, chapterCount: Int, readableChapterCount: Int,
        missingChapterCount: Int, missingImageCount: Int
    ) {
        self.init(
            files: [file], chapterCount: chapterCount, readableChapterCount: readableChapterCount,
            missingChapterCount: missingChapterCount, missingImageCount: missingImageCount)
    }

    init(
        files: [CacheExportFileLease], chapterCount: Int, readableChapterCount: Int,
        missingChapterCount: Int, missingImageCount: Int, uploadPayloads: [KotlinByteArray] = []
    ) {
        precondition(!files.isEmpty)
        self.files = files
        self.uploadPayloads = uploadPayloads
        self.chapterCount = chapterCount
        self.readableChapterCount = readableChapterCount
        self.missingChapterCount = missingChapterCount
        self.missingImageCount = missingImageCount
    }

    var file: CacheExportFileLease { files[0] }
    var url: URL { file.url }
    var urls: [URL] { files.map(\.url) }
    func cleanup() { files.forEach { $0.cleanup() } }
    var isPartial: Bool { missingChapterCount > 0 || missingImageCount > 0 }
    var missingContentMessage: String {
        var parts: [String] = []
        if missingChapterCount > 0 { parts.append("缺失 \(missingChapterCount) 章") }
        if missingImageCount > 0 { parts.append("缺失 \(missingImageCount) 张图片") }
        return parts.joined(separator: "，")
    }
}

@MainActor
final class CacheBookExporter {
    private var facade: BookExportFacade?

    // Legacy URL-only callers must remove the returned file's parent directory after sharing.
    func export(_ book: Book, format: CacheExportFormat) async throws -> URL {
        let result = try await export(book, format: format, onProgress: { _ in })
        return result.file.transferToURLCaller()
    }

    func export(
        _ book: Book, format: CacheExportFormat,
        onProgress: @escaping @MainActor (CacheExportProgress) -> Void
    ) async throws -> CacheBookExportResult {
        try Task.checkCancellation()
        if facade == nil { facade = try BookExportFacade.companion.create() }
        guard let facade else { throw CancellationError() }
        let file = try CacheExportFileLease(fileName: "\(Self.fileName(book.name)).\(format.rawValue)")
        do {
            let payload = try await CacheExportAsync.prepare(
                bookURL: book.bookUrl, format: format, facade: facade, onProgress: onProgress)
            try Task.checkCancellation()
            guard payload.readableChapterCount > 0, payload.data.size > 0 else { throw noContent() }
            guard payload.fileExtension.lowercased() == format.rawValue else {
                throw NSError(
                    domain: "io.legado.cache.export", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "导出文件格式不匹配"])
            }
            try await CacheExportFiles.write(payload.data, to: file.url)
            try Task.checkCancellation()
            return CacheBookExportResult(
                file: file, chapterCount: Int(payload.chapterCount),
                readableChapterCount: Int(payload.readableChapterCount),
                missingChapterCount: Int(payload.missingChapterCount), missingImageCount: Int(payload.missingImageCount))
        } catch {
            file.cleanup()
            throw error
        }
    }

    func exportConfigured(
        _ book: Book, format: CacheExportFormat, options: CacheExportOptions,
        onProgress: @escaping @MainActor (CacheExportProgress) -> Void
    ) async throws -> CacheBookExportResult {
        try Task.checkCancellation()
        guard let count = Int32(exactly: options.chaptersPerFile) else { throw invalidConfiguration() }
        if facade == nil { facade = try BookExportFacade.companion.create() }
        guard let facade else { throw CancellationError() }
        if format == .epub && options.useCustomEpubTemplate && options.epubTemplateBase64.isEmpty {
            throw NSError(
                domain: "io.legado.cache.export", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "自定义 EPUB 模板不可用，请重新导入或选择内置模板"])
        }
        let settings = BookExportOptions(
            chapterScope: options.chapterScope, chaptersPerFile: count, charset: options.charset,
            includeChapterTitle: options.includeChapterTitle, useReplaceRules: options.useReplaceRules,
            fileNameScript: options.fileNameScript, splitFileNameScript: options.splitFileNameScript,
            includeImages: format == .txt && options.includeImages,
            epubTemplateBase64: format == .epub && options.useCustomEpubTemplate ? options.epubTemplateBase64 : "")
        let batch = try await CacheExportAsync.prepareConfigured(
            bookURL: book.bookUrl, format: format, options: settings, facade: facade, onProgress: onProgress)
        try Task.checkCancellation()
        guard !batch.parts.isEmpty, batch.parts.count <= 1000 else { throw invalidConfiguration() }
        var files: [CacheExportFileLease] = []
        var totalBytes: Int64 = 0
        var chapterCount = 0
        var readableChapterCount = 0
        var missingChapterCount = 0
        var missingImageCount = 0
        var names = Set<String>()
        let extensionName = format == .txt && options.includeImages ? "zip" : format.rawValue
        do {
            for part in batch.parts {
                try Task.checkCancellation()
                let payload = part.export_
                guard payload.fileExtension == extensionName, payload.data.size > 0,
                    (part.fileName as NSString).pathExtension.lowercased() == extensionName,
                    names.insert(part.fileName.lowercased()).inserted
                else { throw invalidConfiguration() }
                totalBytes += Int64(payload.data.size)
                guard totalBytes <= 128 * 1024 * 1024 else { throw invalidConfiguration() }
                let file = try CacheExportFileLease(fileName: part.fileName)
                files.append(file)
                try await CacheExportFiles.write(payload.data, to: file.url)
                chapterCount += Int(payload.chapterCount)
                readableChapterCount += Int(payload.readableChapterCount)
                missingChapterCount += Int(payload.missingChapterCount)
                missingImageCount += Int(payload.missingImageCount)
            }
            try Task.checkCancellation()
            guard readableChapterCount > 0 else { throw noContent() }
            return CacheBookExportResult(
                files: files, chapterCount: chapterCount, readableChapterCount: readableChapterCount,
                missingChapterCount: missingChapterCount, missingImageCount: missingImageCount,
                uploadPayloads: options.destination == .webDAV ? batch.parts.map { $0.export_.data } : [])
        } catch {
            files.forEach { $0.cleanup() }
            throw error
        }
    }

    private func invalidConfiguration() -> NSError {
        NSError(
            domain: "io.legado.cache.export", code: -4,
            userInfo: [NSLocalizedDescriptionKey: "导出配置或生成文件无效，请检查后重试"])
    }

    static func fileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in cleaned {
            let next = String(character)
            if result.utf8.count + next.utf8.count > 160 { break }
            result += next
        }
        return result.isEmpty ? "book" : result
    }

    private func noContent() -> NSError {
        NSError(
            domain: "io.legado.cache.export", code: -2,
            userInfo: [NSLocalizedDescriptionKey: L10n.CacheManagement.exportNoCachedContent])
    }
}
