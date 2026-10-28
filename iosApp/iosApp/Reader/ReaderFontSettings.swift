import shared

/// Owns the save independently of the presenting appearance panel's tasks.
@MainActor
final class ReaderFontSettings {
    private let facade: SettingsFacade

    init() throws {
        facade = try SharedRuntime.settingsFacade().get()
    }

    func select(_ name: String?) async throws {
        let currentStyle = await readerStylePreferenceSnapshot(facade: facade)
        try await facade.setReaderLayoutAsync(style: currentStyle.androidCopy(fontName: .some(name)))
    }
}
