import Foundation
import shared

enum CacheManagementListPolicy {
    // CacheActivity has its own ordering: even the bookshelf author mode falls back to last read.
    static func sort(_ books: [Book], mode: Int) -> [Book] {
        books.enumerated().sorted { left, right in
            let lhs = left.element
            let rhs = right.element
            let result: ComparisonResult
            switch mode {
            case 1: result = compare(rhs.latestChapterTime, lhs.latestChapterTime)
            case 2: result = lhs.name.compare(rhs.name, options: [], range: nil, locale: Locale(identifier: "zh_CN"))
            case 3: result = compare(lhs.order, rhs.order)
            case 4:
                result = compare(
                    max(rhs.latestChapterTime, rhs.durChapterTime), max(lhs.latestChapterTime, lhs.durChapterTime))
            default: result = compare(rhs.durChapterTime, lhs.durChapterTime)
            }
            return result == .orderedSame ? left.offset < right.offset : result == .orderedAscending
        }.map(\.element)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

enum CacheExportFormat: String, CaseIterable {
    case txt, epub
    var title: String { rawValue.uppercased() }
}

struct CacheExportPreferences {
    private let defaults: UserDefaults
    private let key = "legado.ios.cache.exportType"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> CacheExportFormat { defaults.string(forKey: key).flatMap(CacheExportFormat.init(rawValue:)) ?? .txt }
    func save(_ format: CacheExportFormat) { defaults.set(format.rawValue, forKey: key) }
}
