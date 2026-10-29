import shared
import UIKit

/// Keeps legacy settings controls and shared backup defaults on the same effective values.
@MainActor
final class RestoredAppPreferences {
    struct Snapshot: Equatable {
        let showDiscovery: Bool
        let showRss: Bool
        let homePage: Int
        let keepScreenOn: Bool
    }
    private static let booleanPairs = [
        ("show_discovery", "showDiscovery", true), ("show_rss", "showRss", true),
        ("auto_refresh_book", "autoRefreshOnStart", false), ("keep_screen_on", "keepScreenOn", false),
    ]
    private static var didRunStartupRefresh = false
    private let onChange: (Snapshot) -> Void
    private var observer: NSObjectProtocol?
    private var previousValues: [String: String] = [:]
    private var lastSnapshot: Snapshot?
    private var synchronizing = false

    init(onChange: @escaping (Snapshot) -> Void) { self.onChange = onChange }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    static var keepScreenOn: Bool { UserDefaults.standard.bool(forKey: "keep_screen_on") }

    static func setKeepScreenOn(_ enabled: Bool) {
        set(enabled, forKey: "keepScreenOn")
        UIApplication.shared.isIdleTimerDisabled = enabled
    }

    static func set(_ value: Any, forKey key: String) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: key)
        if let pair = booleanPairs.first(where: { $0.1 == key || $0.0 == key }) {
            let enabled = (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? pair.2
            defaults.set(enabled, forKey: pair.0)
            defaults.set(enabled, forKey: pair.1)
            Task {
                do {
                    let facade = try BootstrapApiKt.sharedSettingsFacade()
                    switch pair.0 {
                    case "show_discovery":
                        try await SharedAsync.void { facade.setShowDiscovery(enabled: enabled, completionHandler: $0) }
                    case "show_rss": try await SharedAsync.void { facade.setShowRSS(enabled: enabled, completionHandler: $0) }
                    case "auto_refresh_book":
                        try await SharedAsync.void { facade.setAutoRefreshBook(enabled: enabled, completionHandler: $0) }
                    default: break
                    }
                } catch { SharedRuntime.log("应用偏好同步失败，请重新打开设置后重试") }
            }
        } else if key == "defaultHomePage" || key == "default_home_page" {
            let index = homeIndex(value)
            defaults.set(index, forKey: "defaultHomePage")
            defaults.set(["bookshelf", "discovery", "rss", "settings"][index], forKey: "default_home_page")
        }
    }

    static func homeIndex(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return (0...3).contains(number.intValue) ? number.intValue : 0 }
        switch (value as? String)?.lowercased() {
        case "1", "discovery", "explore": return 1
        case "2", "rss": return 2
        case "3", "settings", "my", "person": return 3
        default: return 0
        }
    }

    func start() {
        synchronize()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main)
        { [weak self] _ in
            DispatchQueue.main.async { self?.synchronize() }
        }
        guard !Self.didRunStartupRefresh else { return }
        Self.didRunStartupRefresh = true
        guard UserDefaults.standard.bool(forKey: "auto_refresh_book") else { return }
        Task { @MainActor in
            do {
                let facade = try BootstrapApiKt.sharedBookshelfFacade()
                let books = try await facade.loadBooksAsync(groupId: -1)
                try BookshelfUpdateCoordinator.shared.enqueue(books: books)
            } catch { SharedRuntime.log("启动书架更新失败，请在书架下拉重试") }
        }
    }

    private func synchronize() {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        let defaults = UserDefaults.standard
        func raw(_ key: String) -> String? { defaults.object(forKey: key).map { String(describing: $0) } }
        func useAlias(_ canonical: String, _ alias: String) -> Bool {
            guard !previousValues.isEmpty else { return defaults.object(forKey: canonical) == nil }
            return raw(canonical) == previousValues[canonical] && raw(alias) != previousValues[alias]
        }
        for (canonical, alias, fallback) in Self.booleanPairs {
            let key = useAlias(canonical, alias) ? alias : canonical
            let value = defaults.object(forKey: key).map { _ in defaults.bool(forKey: key) } ?? fallback
            if defaults.object(forKey: canonical) == nil || defaults.bool(forKey: canonical) != value {
                defaults.set(value, forKey: canonical)
            }
            if defaults.object(forKey: alias) == nil || defaults.bool(forKey: alias) != value {
                defaults.set(value, forKey: alias)
            }
        }
        let homeKey = useAlias("default_home_page", "defaultHomePage") ? "defaultHomePage" : "default_home_page"
        let home = Self.homeIndex(defaults.object(forKey: homeKey))
        let homeName = ["bookshelf", "discovery", "rss", "settings"][home]
        if defaults.string(forKey: "default_home_page") != homeName { defaults.set(homeName, forKey: "default_home_page") }
        if defaults.object(forKey: "defaultHomePage") == nil || defaults.integer(forKey: "defaultHomePage") != home {
            defaults.set(home, forKey: "defaultHomePage")
        }
        let keys = Self.booleanPairs.flatMap { [$0.0, $0.1] } + ["default_home_page", "defaultHomePage"]
        previousValues = Dictionary(uniqueKeysWithValues: keys.compactMap { key in raw(key).map { (key, $0) } })
        let snapshot = Snapshot(
            showDiscovery: defaults.bool(forKey: "show_discovery"), showRss: defaults.bool(forKey: "show_rss"), homePage: home,
            keepScreenOn: Self.keepScreenOn)
        if lastSnapshot?.keepScreenOn != snapshot.keepScreenOn {
            UIApplication.shared.isIdleTimerDisabled = snapshot.keepScreenOn
        }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange(snapshot)
    }
}
