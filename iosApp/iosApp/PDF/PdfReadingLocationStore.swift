import CryptoKit
import Foundation

enum PdfReadingMode: String, Codable {
    case continuous
    case paged
}

struct PdfReadingLocation: Codable, Equatable {
    var mode: PdfReadingMode
    var pageIndex: Int
    var pointX: Double
    var pointY: Double
    var relativeScale: Double

    init(
        mode: PdfReadingMode,
        pageIndex: Int,
        pointX: Double,
        pointY: Double,
        relativeScale: Double
    ) {
        self.mode = mode
        self.pageIndex = pageIndex
        self.pointX = pointX
        self.pointY = pointY
        self.relativeScale = relativeScale
    }
}

final class PdfReadingLocationStore {
    private struct FileFingerprint: Codable, Equatable {
        let path: String
        let byteCount: Int64
        let modificationTime: Double
    }

    private struct Record: Codable {
        let version: Int
        let fingerprint: FileFingerprint
        let pageCount: Int
        let location: PdfReadingLocation
    }

    private static let version = 1
    private static let maximumRecordBytes = 4 * 1024
    private static let relativeScaleBudget = 0.01...64.0
    private static let errorDomain = "io.legado.kmp.ios.pdf.reading-location"

    private let defaults: UserDefaults
    private let key: String

    init(bookURL: String, defaults: UserDefaults = .standard) {
        let digest = SHA256.hash(data: Data(bookURL.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        key = "io.legado.kmp.ios.pdf.reading-location.v\(Self.version).\(digest)"
        self.defaults = defaults
    }

    // The caller owns shared-page precedence and explicit-jump suppression.
    func load(fileURL: URL, pageCount: Int) -> PdfReadingLocation? {
        guard pageCount > 0,
            let data = defaults.object(forKey: key) as? Data,
            !data.isEmpty,
            data.count <= Self.maximumRecordBytes,
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.version == Self.version,
            record.pageCount == pageCount,
            Self.isValid(record.location, pageCount: pageCount),
            let fingerprint = try? Self.fingerprint(fileURL: fileURL),
            record.fingerprint == fingerprint
        else {
            // Unavailable metadata and invalid records must never erase a saved location.
            return nil
        }
        return record.location
    }

    func save(_ location: PdfReadingLocation, fileURL: URL, pageCount: Int) throws {
        guard Self.isValid(location, pageCount: pageCount) else {
            throw Self.error(
                code: 1,
                message: "PDF 页码、坐标或缩放比例无效"
            )
        }

        let record = Record(
            version: Self.version,
            fingerprint: try Self.fingerprint(fileURL: fileURL),
            pageCount: pageCount,
            location: location
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw Self.error(code: 3, message: "无法保存 PDF 阅读位置", underlying: error)
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw Self.error(code: 4, message: "PDF 阅读位置记录超过大小限制")
        }

        // Only this book's record is replaced; UserDefaults persists it asynchronously.
        defaults.set(data, forKey: key)
    }

    private static func isValid(_ location: PdfReadingLocation, pageCount: Int) -> Bool {
        // PDF page-space coordinates can be negative; PDFKit owns page-bound checks.
        pageCount > 0
            && location.pageIndex >= 0
            && location.pageIndex < pageCount
            && location.pointX.isFinite
            && location.pointY.isFinite
            && location.relativeScale.isFinite
            && relativeScaleBudget.contains(location.relativeScale)
    }

    private static func fingerprint(fileURL: URL) throws -> FileFingerprint {
        guard fileURL.isFileURL else {
            throw error(code: 2, message: "PDF 阅读位置需要本地文件")
        }
        let canonicalURL = fileURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let attributes: [FileAttributeKey: Any]
        do {
            // Read fresh filesystem attributes instead of potentially cached URL resource values.
            attributes = try FileManager.default.attributesOfItem(atPath: canonicalURL.path)
        } catch {
            throw Self.error(code: 2, message: "无法读取 PDF 文件信息", underlying: error)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let byteCount = attributes[.size] as? NSNumber,
            byteCount.int64Value > 0,
            let modificationDate = attributes[.modificationDate] as? Date,
            modificationDate.timeIntervalSince1970.isFinite
        else {
            throw error(code: 2, message: "PDF 文件信息缺失或无效")
        }
        return FileFingerprint(
            path: canonicalURL.path,
            byteCount: byteCount.int64Value,
            modificationTime: modificationDate.timeIntervalSince1970
        )
    }

    private static func error(code: Int, message: String, underlying: Error? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying as NSError
        }
        return NSError(domain: errorDomain, code: code, userInfo: userInfo)
    }
}
