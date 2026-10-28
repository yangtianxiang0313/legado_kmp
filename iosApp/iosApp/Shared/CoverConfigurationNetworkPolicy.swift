import Foundation
import Network

struct CoverConfigurationLoadingPolicy: Sendable {
    let usesDefaultCover: Bool
    let loadsOnlyOnWiFi: Bool

    init(defaults: UserDefaults = .standard) {
        let raw =
            defaults.string(forKey: "backup_android_config")?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func flag(_ localKey: String, androidKey: String) -> Bool {
            let value = defaults.object(forKey: localKey) ?? raw[androidKey] ?? defaults.object(forKey: androidKey)
            if let value = value as? NSNumber { return value.boolValue }
            if let value = value as? String { return value == "true" || value == "1" }
            return false
        }
        usesDefaultCover = flag("use_default_cover", androidKey: "useDefaultCover")
        loadsOnlyOnWiFi = flag("load_cover_only_wifi", androidKey: "loadCoverOnlyWifi")
    }

    var cacheOnly: Bool { loadsOnlyOnWiFi && !CoverConfigurationNetworkPolicy.shared.isWiFiAvailable }
    var signature: String { "\(usesDefaultCover):\(loadsOnlyOnWiFi):\(cacheOnly)" }
}

final class CoverConfigurationNetworkPolicy: @unchecked Sendable {
    static let shared = CoverConfigurationNetworkPolicy()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var wifiAvailable = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            let previous = self.wifiAvailable
            self.wifiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let changed = previous != self.wifiAvailable
            self.lock.unlock()
            if changed {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: CoverConfigurationStore.didChange, object: nil)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.legado.cover-network-policy"))
    }

    var isWiFiAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wifiAvailable
    }
}
