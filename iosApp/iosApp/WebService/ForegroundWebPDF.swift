import Foundation
import PDFKit
import UIKit
import shared

enum ForegroundWebPDF {
    private enum Operation: Sendable {
        case original
        case info
        case page(Int)
    }

    @MainActor
    static func load(bookUrl: String) async throws -> Data {
        try await response(bookUrl: bookUrl, operation: .original)
    }

    @MainActor
    static func info(bookUrl: String) async throws -> Data {
        try await response(bookUrl: bookUrl, operation: .info)
    }

    @MainActor
    static func page(bookUrl: String, index: Int) async throws -> Data {
        try await response(bookUrl: bookUrl, operation: .page(index))
    }

    @MainActor
    private static func response(bookUrl: String, operation: Operation) async throws -> Data {
        let facade = try PdfReaderDocumentFacade.companion.create()
        let resolved: PdfReaderDocument = try await SharedAsync.value { facade.resolve(bookUrl: bookUrl, completionHandler: $0) }
        try Task.checkCancellation()
        let path = resolved.filePath
        let loading = Task.detached(priority: .userInitiated) {
            let (bytes, document) = try read(path: path)
            switch operation {
            case .original: return bytes
            case .info: return try envelope(["pageCount": document.pageCount])
            case .page(let index): return try render(document: document, index: index)
            }
        }
        return try await withTaskCancellationHandler {
            try await loading.value
        } onCancel: {
            loading.cancel()
        }
    }

    private static func read(path: String) throws -> (Data, PDFDocument) {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length > 0, length <= 16 * 1024 * 1024 else { throw failure("网页 PDF 上限为 16 MiB，请在 App 中打开此文件") }
        try file.seek(toOffset: 0)
        var bytes = Data()
        while bytes.count < Int(length) {
            try Task.checkCancellation()
            guard let block = try file.read(upToCount: min(64 * 1024, Int(length) - bytes.count)), !block.isEmpty else {
                throw failure("PDF 文件读取不完整")
            }
            bytes.append(block)
        }
        try Task.checkCancellation()
        guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else {
            throw failure("PDF 已加密、损坏或没有可阅读的页面")
        }
        return (bytes, document)
    }

    private static func render(document: PDFDocument, index: Int) throws -> Data {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index), let reference = page.pageRef else {
            throw failure("PDF 页码无效")
        }
        let box = reference.getBoxRect(.cropBox)
        let rotated = abs(reference.rotationAngle) % 180 == 90
        let pageWidth = rotated ? box.height : box.width
        let pageHeight = rotated ? box.width : box.height
        guard pageWidth.isFinite, pageHeight.isFinite, pageWidth > 0, pageHeight > 0 else { throw failure("PDF 原页尺寸无效") }
        let scale = min(1200 / pageWidth, 1800 / pageHeight)
        let size = CGSize(width: max(1, ceil(pageWidth * scale)), height: max(1, ceil(pageHeight * scale)))
        let bounds = CGRect(origin: .zero, size: size)
        let intrinsic = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let transform = reference.getDrawingTransform(.cropBox, rect: intrinsic, rotate: 0, preserveAspectRatio: true)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        try Task.checkCancellation()
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.concatenate(transform)
            context.cgContext.drawPDFPage(reference)
        }
        try Task.checkCancellation()
        guard let png = image.pngData(), png.count <= 8 * 1024 * 1024 else { throw failure("PDF 原页图像超过上限") }
        let string = page.string ?? ""
        guard string.utf16.count <= 500_000 else { throw failure("PDF 原页文字层超过容量") }
        let lines = page.selection(for: NSRange(location: 0, length: string.utf16.count))?.selectionsByLine() ?? []
        guard lines.count <= 10_000 else { throw failure("PDF 原页文字行过多") }
        var text: [[String: Any]] = []
        for line in lines {
            try Task.checkCancellation()
            guard let value = line.string, !value.isEmpty else { continue }
            let rect = line.bounds(for: page).applying(transform).intersection(bounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            text.append([
                "text": value, "left": rect.minX / size.width, "top": 1 - rect.maxY / size.height,
                "width": rect.width / size.width, "height": rect.height / size.height,
            ])
        }
        return try envelope([
            "index": index, "width": size.width, "height": size.height, "png": png.base64EncodedString(), "text": text,
        ])
    }

    private static func envelope(_ data: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["isSuccess": true, "errorMsg": "", "data": data])
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web.pdf", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
