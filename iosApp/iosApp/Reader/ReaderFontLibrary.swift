import Foundation
import UIKit

struct ReaderFontLibrarySnapshot {
    let entries: [ReaderFontEntry]
    let requiresDirectorySelection: Bool
    let warning: String?
}

// Synchronous file work; callers on the UI use ReaderFontLibraryWork instead.
final class ReaderFontLibrary {
    static let directoryBookmarkKey = "readerFontLibrary.directoryBookmark.v1"

    private let store: ReaderFontStore
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let temporaryDirectoryURL: URL
    private let lock = NSLock()
    private var directory: Directory?
    private var imports: [String: ImportedFont] = [:]
    private var previewFailures: [String: PreviewFailure] = [:]

    init(
        store: ReaderFontStore, defaults: UserDefaults = .standard,
        bookmarkKey: String = ReaderFontLibrary.directoryBookmarkKey,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.store = store
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    func load() throws -> ReaderFontLibrarySnapshot {
        try locked {
            let owned = try ownedFonts()
            guard let value = defaults.object(forKey: bookmarkKey) else {
                return snapshot(
                    owned: owned, requiresSelection: true,
                    warning: directory == nil ? nil : "字体目录授权记录已丢失，请重新选择字体目录。")
            }
            do {
                guard let bookmark = value as? Data else { throw ReaderFontDirectoryError.invalidBookmark }
                let resolved = try ReaderFontDirectoryAccess.resolve(bookmark)
                let scanned = try ReaderFontDirectoryAccess.scan(
                    resolved.url, makeBookmark: resolved.isStale)
                let updatedBookmark = scanned.bookmark ?? bookmark
                let updated = makeDirectory(scanned, bookmark: updatedBookmark, reusing: bookmark)
                let result = snapshot(owned: owned, directory: updated, requiresSelection: false)
                // Refresh stale bookmarks only after the directory has really been read.
                if updatedBookmark != bookmark { defaults.set(updatedBookmark, forKey: bookmarkKey) }
                install(updated)
                return result
            } catch {
                return snapshot(
                    owned: owned, requiresSelection: true,
                    warning: "无法加载字体目录：\(error.localizedDescription)\n请重新选择字体目录。")
            }
        }
    }

    func chooseDirectory(_ url: URL) throws -> ReaderFontLibrarySnapshot {
        try locked {
            let owned = try ownedFonts()
            let scanned = try ReaderFontDirectoryAccess.scan(url, makeBookmark: true)
            guard let bookmark = scanned.bookmark else { throw ReaderFontDirectoryError.invalidBookmark }
            let updated = makeDirectory(scanned, bookmark: bookmark, reusing: nil)
            let result = snapshot(owned: owned, directory: updated, requiresSelection: false)
            // A failed scan/bookmark creation must not replace the user's previous grant.
            defaults.set(bookmark, forKey: bookmarkKey)
            install(updated)
            return result
        }
    }

    func previewFont(entry: ReaderFontEntry, size: CGFloat) -> UIFont? {
        guard size.isFinite, size > 0 else { return nil }
        return locked {
            do {
                let identifier = try ownedIdentifier(for: entry, isPreview: true)
                return store.font(for: identifier, size: size)
            } catch {
                // Android lists invalid font files too; a preview failure is only a fallback.
                return nil
            }
        }
    }

    func selectionIdentifier(for entry: ReaderFontEntry) throws -> String {
        try locked {
            let owned = try ownedIdentifier(for: entry)
            return entry.identifier.hasPrefix("reader-font-directory:")
                ? try store.selectionIdentifier(for: owned, filename: entry.title) : owned
        }
    }

    func selectedFilename(for identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return locked {
            if let filename = store.originalFilename(for: identifier) { return filename }
            if let item = directory?.items.first(where: { $0.entry.identifier == identifier }) { return item.filename }
            // Preserve old configurations which used a registered PostScript name.
            guard let entry = try? store.entries().first(where: { $0.postScriptName == identifier }) else { return nil }
            return store.originalFilename(for: entry.identifier)
        }
    }

    private func ownedIdentifier(for entry: ReaderFontEntry, isPreview: Bool = false) throws -> String {
        if entry.identifier.hasPrefix("reader-font-directory:") {
            guard let directory,
                let item = directory.items.first(where: { $0.entry == entry }),
                defaults.data(forKey: bookmarkKey) == directory.bookmark
            else { throw ReaderFontDirectoryError.staleEntry }
            let resolved = try ReaderFontDirectoryAccess.resolve(directory.bookmark)
            guard !resolved.isStale else { throw ReaderFontDirectoryError.staleBookmark }
            return try ReaderFontDirectoryAccess.withFont(
                in: resolved.url, identity: directory.identity, filename: item.filename
            ) { file in
                if let cached = imports[entry.identifier], cached.stamp == file.stamp,
                    store.font(for: cached.entry.identifier, size: 12) != nil
                {
                    return cached.entry.identifier
                }
                if isPreview, let failure = previewFailures[entry.identifier], failure.stamp == file.stamp {
                    throw failure.error
                }
                do {
                    let imported = try ReaderFontDirectoryAccess.withTemporaryFont(
                        file, filename: item.filename, root: temporaryDirectoryURL
                    ) { try store.importFont(from: $0) }
                    // importFont returns only after validation, registration and owned catalog commit.
                    imports[entry.identifier] = ImportedFont(stamp: file.stamp, entry: imported)
                    previewFailures.removeValue(forKey: entry.identifier)
                    return imported.identifier
                } catch {
                    previewFailures[entry.identifier] = PreviewFailure(stamp: file.stamp, error: error)
                    throw error
                }
            }
        }
        guard let font = store.font(for: entry.identifier, size: 12), font.fontName == entry.postScriptName else {
            throw ReaderFontDirectoryError.unavailableFont
        }
        return entry.identifier
    }

    private func ownedFonts() throws -> [(entry: ReaderFontEntry, filename: String)] {
        try store.entries().map { entry in
            (entry, store.originalFilename(for: entry.identifier) ?? entry.title)
        }
    }

    private func makeDirectory(
        _ scanned: ReaderFontDirectoryAccess.Scan, bookmark: Data, reusing previousBookmark: Data?
    ) -> Directory {
        let previous: Directory?
        if let previousBookmark, directory?.bookmark == previousBookmark, directory?.identity == scanned.identity {
            previous = directory
        } else {
            previous = nil
        }
        let previousItems = Dictionary(
            (previous?.items ?? []).map { (Data($0.filename.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        let items = scanned.filenames.map { filename -> DirectoryItem in
            let existing = previousItems[Data(filename.utf8)]
            let entry =
                existing?.entry
                ?? ReaderFontEntry(
                    identifier: "reader-font-directory:" + UUID().uuidString,
                    title: filename, postScriptName: "")
            return DirectoryItem(filename: filename, entry: entry)
        }
        return Directory(bookmark: bookmark, identity: scanned.identity, items: items)
    }

    private func install(_ updated: Directory) {
        directory = updated
        let active = Set(updated.items.map { $0.entry.identifier })
        imports = imports.filter { active.contains($0.key) }
        previewFailures.removeAll()
    }

    private func snapshot(
        owned: [(entry: ReaderFontEntry, filename: String)],
        requiresSelection: Bool, warning: String? = nil
    ) -> ReaderFontLibrarySnapshot {
        snapshot(owned: owned, directory: directory, requiresSelection: requiresSelection, warning: warning)
    }

    private func snapshot(
        owned: [(entry: ReaderFontEntry, filename: String)], directory: Directory?,
        requiresSelection: Bool, warning: String? = nil
    ) -> ReaderFontLibrarySnapshot {
        let external = directory?.items ?? []
        // String equality is canonically equivalent in Swift; Android's exact filename match is not.
        let filenames = Set(external.map { Data($0.filename.utf8) })
        var merged = external.map { (entry: $0.entry, filename: $0.filename) }
        merged.append(contentsOf: owned.filter { !filenames.contains(Data($0.filename.utf8)) })
        let locale = Locale(identifier: "zh_CN")
        merged.sort {
            let order = $0.filename.compare($1.filename, options: [], range: nil, locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            let lhs = Array($0.filename.utf8)
            let rhs = Array($1.filename.utf8)
            if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) }
            return $0.entry.identifier < $1.entry.identifier
        }
        return ReaderFontLibrarySnapshot(
            entries: merged.map { $0.entry }, requiresDirectorySelection: requiresSelection, warning: warning)
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    private struct Directory {
        let bookmark: Data
        let identity: ReaderFontDirectoryAccess.Identity
        let items: [DirectoryItem]
    }

    private struct DirectoryItem {
        let filename: String
        let entry: ReaderFontEntry
    }

    private struct ImportedFont {
        let stamp: ReaderFontDirectoryAccess.Stamp
        let entry: ReaderFontEntry
    }

    private struct PreviewFailure {
        let stamp: ReaderFontDirectoryAccess.Stamp
        let error: Error
    }
}
