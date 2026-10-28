import Foundation
import SQLite3
import shared

enum SourceManagementListSort: String, CaseIterable {
    // Menu order is independent of Android's persisted enum ordinals.
    case manual, weight, name, url, update, respond, enabled
}

struct SourceManagementListConfiguration: Equatable {
    var sort: SourceManagementListSort = .manual
    var ascending = true
    var groupsByDomain = false
}

struct SourceManagementListPreferences {
    private let defaults: UserDefaults
    private static let prefix = "legado.ios.sourceManagement.list."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SourceManagementListConfiguration {
        let sort =
            defaults.string(forKey: Self.prefix + "sort")
            .flatMap(SourceManagementListSort.init(rawValue:)) ?? .manual
        return SourceManagementListConfiguration(
            sort: sort,
            ascending: defaults.object(forKey: Self.prefix + "ascending") as? Bool ?? true,
            groupsByDomain: defaults.object(forKey: Self.prefix + "groupsByDomain") as? Bool ?? false
        )
    }

    // Loading never registers or persists defaults; only an explicit user change calls save.
    func save(_ configuration: SourceManagementListConfiguration) {
        defaults.set(configuration.sort.rawValue, forKey: Self.prefix + "sort")
        defaults.set(configuration.ascending, forKey: Self.prefix + "ascending")
        defaults.set(configuration.groupsByDomain, forKey: Self.prefix + "groupsByDomain")
    }
}

/// BookSourceActivity, BookSourceAdapter and BookSourceDao at Legado 5f5d314.
enum SourceManagementListPolicy {
    enum FilterQuery {
        static let enabled = "已启用"
        static let disabled = "已禁用"
        static let needsLogin = "需要登录"
        static let ungrouped = "未分组"
        static let exploreEnabled = "已启用发现"
        static let exploreDisabled = "已禁用发现"
    }

    static func apply(
        sources: [BookSource], query: String, configuration: SourceManagementListConfiguration
    ) -> [BookSource] {
        // Every original DAO flow starts in customOrder order. Keep input order for ties.
        let ordered = sources.enumerated().filter { matches($0.element, query: query) }
            .sorted { lhs, rhs in
                lhs.element.customOrder == rhs.element.customOrder
                    ? lhs.offset < rhs.offset : lhs.element.customOrder < rhs.element.customOrder
            }.map(\.element)

        if configuration.groupsByDomain {
            var hosts: [String: String] = [:]
            for source in ordered {
                hosts[source.bookSourceUrl] = sourceHost(source.bookSourceUrl)
            }
            return stableSort(ordered) { lhs, rhs in
                let left = hosts[lhs.bookSourceUrl] ?? "#"
                let right = hosts[rhs.bookSourceUrl] ?? "#"
                if left != right {
                    if left == "#" { return .orderedDescending }
                    if right == "#" { return .orderedAscending }
                    return compareUTF16(left, right)
                }
                return compare(rhs.lastUpdateTime, lhs.lastUpdateTime)
            }
        }

        if configuration.sort == .manual {
            return configuration.ascending ? ordered : Array(ordered.reversed())
        }
        return stableSort(ordered) { lhs, rhs in
            switch configuration.sort {
            case .manual:
                return .orderedSame
            case .weight:
                return direction(compare(lhs.weight, rhs.weight), ascending: configuration.ascending)
            case .name:
                return configuration.ascending
                    ? compareNames(lhs.bookSourceName, rhs.bookSourceName)
                    : compareNames(rhs.bookSourceName, lhs.bookSourceName)
            case .url:
                return direction(
                    compareUTF16(lhs.bookSourceUrl, rhs.bookSourceUrl), ascending: configuration.ascending
                )
            case .update:
                // Android's ascending update sort deliberately puts newest first.
                return direction(compare(rhs.lastUpdateTime, lhs.lastUpdateTime), ascending: configuration.ascending)
            case .respond:
                return direction(compare(lhs.respondTime, rhs.respondTime), ascending: configuration.ascending)
            case .enabled:
                if lhs.enabled != rhs.enabled {
                    return lhs.enabled == configuration.ascending ? .orderedAscending : .orderedDescending
                }
                // Name ties do not reverse when the enabled-state direction changes.
                return compareNames(lhs.bookSourceName, rhs.bookSourceName)
            }
        }
    }

    /// Pass the already ordered visible sources; keys are the first source URL in each host group.
    static func domainHeaders(sources: [BookSource], grouped: Bool) -> [String: String] {
        guard grouped else { return [:] }
        var result: [String: String] = [:]
        var previousHost: String?
        for source in sources {
            let host = sourceHost(source.bookSourceUrl)
            if host != previousHost {
                result[source.bookSourceUrl] = host
            }
            previousHost = host
        }
        return result
    }

    static func sourceHost(_ sourceURL: String) -> String {
        guard let components = URLComponents(string: sourceURL),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return "#" }
        // Reuse the existing iOS resolver, not a second suffix table. Unlike Android's
        // OkHttp PSL it covers only common multipart suffixes; rare/private suffixes can differ.
        let domain = CookieSupportKt.extractCookieDomain(url: sourceURL)
        return domain.isEmpty ? host : domain
    }

    private static func matches(_ source: BookSource, query: String) -> Bool {
        // Activity tests isNullOrEmpty, not isBlank: spaces remain part of the LIKE query.
        switch query {
        case "":
            return true
        case FilterQuery.enabled:
            return source.enabled
        case FilterQuery.disabled:
            return !source.enabled
        case FilterQuery.needsLogin:
            return source.hasManagementLoginURL
        case FilterQuery.ungrouped:
            guard let group = source.bookSourceGroup else { return true }
            return group.isEmpty || like(group, pattern: "%未分组%")
        case FilterQuery.exploreEnabled:
            return source.enabledExplore
        case FilterQuery.exploreDisabled:
            return !source.enabledExplore
        default:
            if query.hasPrefix("group:") {
                guard let group = source.bookSourceGroup else { return false }
                let key = String(query.dropFirst("group:".count))
                // The equality arm is BINARY; LIKE arms intentionally retain %/_ wildcards.
                return group.utf16.elementsEqual(key.utf16)
                    || like(group, pattern: key + ",%")
                    || like(group, pattern: "%," + key)
                    || like(group, pattern: "%," + key + ",%")
            }
            let pattern = "%" + query + "%"
            let fields: [String?] = [
                source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup, source.bookSourceComment,
            ]
            return
                fields
                .contains { value in value.map { like($0, pattern: pattern) } ?? false }
        }
    }

    private static func like(_ value: String, pattern: String) -> Bool {
        // Match the DAO's SQLite LIKE: ASCII case folds, Unicode case does not, no ESCAPE clause.
        sqlite3_strlike(pattern, value, 0) == 0
    }

    private static func stableSort(
        _ sources: [BookSource], by compare: (BookSource, BookSource) -> ComparisonResult
    ) -> [BookSource] {
        sources.enumerated().sorted { lhs, rhs in
            let result = compare(lhs.element, rhs.element)
            return result == .orderedSame ? lhs.offset < rhs.offset : result == .orderedAscending
        }.map(\.element)
    }

    private static func direction(_ result: ComparisonResult, ascending: Bool) -> ComparisonResult {
        if ascending || result == .orderedSame { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private static func compareUTF16(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.utf16.elementsEqual(rhs.utf16) { return .orderedSame }
        return lhs.utf16.lexicographicallyPrecedes(rhs.utf16) ? .orderedAscending : .orderedDescending
    }

    private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        // Simplified-Chinese collation, not device locale, numeric sorting or alphabet sections.
        // Foundation/ICU collation versions can differ from Android's ICU Collator(zh_CN).
        lhs.compare(rhs, options: [], range: nil, locale: Locale(identifier: "zh_CN"))
    }
}
