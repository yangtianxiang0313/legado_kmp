import Foundation
import PDFKit

enum PdfBookmarkExcerpt {
    static let maximumUTF16Length = 4_096

    static func load(fileURL: URL, pageIndex: Int, selectedText: String?) async throws -> String {
        try Task.checkCancellation()
        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bounded(selectedText)
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard fileURL.isFileURL, pageIndex >= 0, let document = PDFDocument(url: fileURL),
                !document.isLocked, let page = document.page(at: pageIndex)
            else {
                throw NSError(
                    domain: "io.legado.pdf.bookmark", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "PDF 页面已不可用"])
            }
            let text = page.string ?? ""
            try Task.checkCancellation()
            return bounded(text)
        }
        let text = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        // Scanned pages stay readable and bookmarkable without inventing an OCR text layer.
        return text.isEmpty ? "第 \(pageIndex + 1) 页" : text
    }

    static func bounded(_ text: String) -> String {
        let value = text as NSString
        var length = min(value.length, maximumUTF16Length)
        if length > 0, length < value.length, (0xD800...0xDBFF).contains(value.character(at: length - 1)) { length -= 1 }
        return value.substring(to: length).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
