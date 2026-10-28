import Foundation
import SQLite3
import shared

enum ExploreSourceListPolicy {
    static func apply(_ sources: [BookSourcePart], query: String) -> [BookSourcePart] {
        sources.enumerated().filter { _, source in
            guard source.enabledExplore, source.hasExploreUrl else { return false }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if query.hasPrefix("group:") {
                guard let group = source.bookSourceGroup else { return false }
                let key = String(query.dropFirst(6))
                return group.utf16.elementsEqual(key.utf16)
                    || like(group, key + ",%") || like(group, "%," + key) || like(group, "%," + key + ",%")
            }
            let pattern = "%" + query + "%"
            return like(source.bookSourceName, pattern) || source.bookSourceGroup.map { like($0, pattern) } == true
        }.sorted {
            $0.element.customOrder == $1.element.customOrder
                ? $0.offset < $1.offset : $0.element.customOrder < $1.element.customOrder
        }.map(\.element)
    }

    static func groups(_ sources: [BookSourcePart]) -> [String] {
        let groups = Set(
            sources.flatMap { source in
                (source.bookSourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            })
        return groups.sorted { $0.compare($1, locale: Locale(identifier: "zh_CN")) == .orderedAscending }
    }

    private static func like(_ value: String, _ pattern: String) -> Bool {
        sqlite3_strlike(pattern, value, 0) == 0
    }
}
