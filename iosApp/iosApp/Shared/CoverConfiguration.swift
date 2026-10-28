import Foundation

enum CoverConfigurationMode: Int, CaseIterable {
    case day
    case night

    var title: String { self == .day ? "日间" : "夜间" }
    var imageKey: String { self == .day ? "defaultCover" : "defaultCoverDark" }
    var nameKey: String { self == .day ? "coverShowName" : "coverShowNameN" }
    var authorKey: String { self == .day ? "coverShowAuthor" : "coverShowAuthorN" }
}

struct CoverConfiguration: Equatable {
    var backgroundPath: String?
    var showsName = true
    var showsAuthor = true
}

@MainActor
final class CoverConfigurationStore {
    static let shared = CoverConfigurationStore()
    static let didChange = Notification.Name("CoverConfigurationDidChange")
    private let defaults: UserDefaults
    private let rawKey = "backup_android_config"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var usesDefaultCover: Bool {
        bool("useDefaultCover", localKey: "use_default_cover", fallback: false)
    }

    var loadsOnlyOnWiFi: Bool {
        bool("loadCoverOnlyWifi", localKey: "load_cover_only_wifi", fallback: false)
    }

    var policySignature: String { CoverConfigurationLoadingPolicy(defaults: defaults).signature }

    func configuration(for mode: CoverConfigurationMode) -> CoverConfiguration {
        let raw = rawValues()
        let path = (raw[mode.imageKey] as? String) ?? defaults.string(forKey: mode.imageKey)
        return CoverConfiguration(
            backgroundPath: path?.isEmpty == false ? path : nil,
            showsName: bool(mode.nameKey, fallback: true),
            showsAuthor: bool(mode.authorKey, fallback: true))
    }

    func setUsesDefaultCover(_ enabled: Bool) {
        write(["useDefaultCover": enabled], aliases: ["use_default_cover": enabled])
    }

    func setLoadsOnlyOnWiFi(_ enabled: Bool) {
        write(["loadCoverOnlyWifi": enabled], aliases: ["load_cover_only_wifi": enabled])
    }

    func setShowsName(_ enabled: Bool, mode: CoverConfigurationMode) {
        write([mode.nameKey: enabled])
    }

    func setShowsAuthor(_ enabled: Bool, mode: CoverConfigurationMode) {
        write([mode.authorKey: enabled])
    }

    func setBackgroundPath(_ path: String?, mode: CoverConfigurationMode) {
        let previous = configuration(for: mode).backgroundPath
        write([mode.imageKey: path ?? ""])
        if previous != path { removeUnreferencedImage(previous) }
    }

    func restore(mode: CoverConfigurationMode) {
        let previous = configuration(for: mode).backgroundPath
        write([mode.imageKey: "", mode.nameKey: true, mode.authorKey: true])
        removeUnreferencedImage(previous)
    }

    func restoreAll() {
        let previous = CoverConfigurationMode.allCases.map { configuration(for: $0).backgroundPath }
        var values: [String: Any] = ["useDefaultCover": false, "loadCoverOnlyWifi": false]
        for mode in CoverConfigurationMode.allCases {
            values[mode.imageKey] = ""
            values[mode.nameKey] = true
            values[mode.authorKey] = true
        }
        write(values, aliases: ["use_default_cover": false, "load_cover_only_wifi": false])
        previous.forEach(removeUnreferencedImage)
    }

    func imageURL(for mode: CoverConfigurationMode) -> URL? {
        configuration(for: mode).backgroundPath.flatMap(CoverConfigurationImageFiles.resolve)
    }

    private func bool(_ key: String, localKey: String? = nil, fallback: Bool) -> Bool {
        // Shared runtime setters use the mapped local key. Android-only keys live in the raw snapshot.
        if let localKey, let value = defaults.object(forKey: localKey) as? NSNumber { return value.boolValue }
        let value = rawValues()[key] ?? defaults.object(forKey: key)
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if value == "true" || value == "1" { return true }
            if value == "false" || value == "0" { return false }
        }
        return fallback
    }

    private func rawValues() -> [String: Any] {
        guard let raw = defaults.string(forKey: rawKey), let data = raw.data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return values
    }

    private func write(_ changes: [String: Any], aliases: [String: Any] = [:]) {
        // Merge at write time so unrelated theme/backup fields are never replaced by a stale snapshot.
        var raw = rawValues()
        changes.forEach { raw[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
            let value = String(data: data, encoding: .utf8)
        else { return }
        changes.forEach { defaults.set($0.value, forKey: $0.key) }
        aliases.forEach { defaults.set($0.value, forKey: $0.key) }
        defaults.set(value, forKey: rawKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func removeUnreferencedImage(_ path: String?) {
        guard let path,
            !CoverConfigurationMode.allCases.contains(where: { configuration(for: $0).backgroundPath == path })
        else { return }
        CoverConfigurationImageFiles.removeOwnedImage(path)
    }
}
