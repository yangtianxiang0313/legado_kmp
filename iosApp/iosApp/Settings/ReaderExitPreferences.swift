import Foundation

struct ReaderExitPreferences {
    private static let promptKey = "showAddToShelfAlert"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var showsAddToShelfPrompt: Bool {
        get {
            defaults.object(forKey: Self.promptKey) as? Bool
                ?? defaults.object(forKey: "show_add_to_shelf_alert") as? Bool ?? true
        }
        nonmutating set { defaults.set(newValue, forKey: Self.promptKey) }
    }
}
