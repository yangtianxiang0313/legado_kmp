import shared

struct ReaderPreferencesPresentationKey: Equatable {
    private let themeMode: ThemeMode
    private let bookshelfLayoutMode: BookshelfLayoutMode
    private let readerPresetName: String
    private let themePresetName: String
    private let readerStyle: ReaderStylePreferences

    init(preferences: AppUiPreferences) {
        themeMode = preferences.themeMode
        bookshelfLayoutMode = preferences.bookshelfLayoutMode
        readerPresetName = preferences.readerPresetName
        themePresetName = preferences.themePresetName
        readerStyle = preferences.readerStyle
    }

    static func == (
        lhs: ReaderPreferencesPresentationKey,
        rhs: ReaderPreferencesPresentationKey
    ) -> Bool {
        // Kotlin's immutable data-class equals includes every style field, including titleSize.
        lhs.themeMode == rhs.themeMode
            && lhs.bookshelfLayoutMode == rhs.bookshelfLayoutMode
            && lhs.readerPresetName == rhs.readerPresetName
            && lhs.themePresetName == rhs.themePresetName
            && lhs.readerStyle.isEqual(rhs.readerStyle)
    }
}
