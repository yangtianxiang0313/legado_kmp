import Foundation

enum StartupReadingPreferences {
    private static let key = "defaultToRead"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension L10n {
    enum StartupReading {
        static let title = Bundle.main.localizedString(
            forKey: "settings.default_to_read", value: "自动跳转最近阅读", table: nil)
        static let detail = Bundle.main.localizedString(
            forKey: "settings.default_to_read_detail", value: "默认打开书架", table: nil)
    }
}
