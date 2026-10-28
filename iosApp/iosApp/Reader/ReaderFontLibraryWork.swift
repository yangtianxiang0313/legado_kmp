import Foundation
import UIKit

enum ReaderFontLibraryWork {
    private static let queue = DispatchQueue(label: "io.legado.reader.font-library", qos: .userInitiated)
    private static let library = ReaderFontLibrary(store: .shared)

    static func load() async throws -> ReaderFontLibrarySnapshot {
        try await perform { try library.load() }
    }

    static func chooseDirectory(_ url: URL) async throws -> ReaderFontLibrarySnapshot {
        try await perform { try library.chooseDirectory(url) }
    }

    static func previewFont(entry: ReaderFontEntry, size: CGFloat) async -> UIFont? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: library.previewFont(entry: entry, size: size)) }
        }
    }

    static func selectionIdentifier(for entry: ReaderFontEntry) async throws -> String {
        try await perform { try library.selectionIdentifier(for: entry) }
    }

    static func selectedFilename(for identifier: String?) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: library.selectedFilename(for: identifier)) }
        }
    }

    private static func perform<Value>(_ work: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}
