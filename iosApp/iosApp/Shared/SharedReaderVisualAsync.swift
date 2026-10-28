import Foundation
import shared

extension SettingsFacade {
    func setReaderQuickOptionAsync(
        option: ReaderAppearanceQuickOption, value: Int32,
        expectedName: String, expectedIndex: Int32, expectedShareLayout: Bool
    ) async throws {
        try await SharedAsync.void { completion in
            self.setReaderQuickOption(
                option: option, value: value, expectedName: expectedName, expectedIndex: expectedIndex,
                expectedShareLayout: expectedShareLayout, completionHandler: completion)
        }
    }

    func setReaderFontSelectionAsync(fontName: String?, expectedName: String, expectedIndex: Int32, expectedShareLayout: Bool) async throws {
        try await SharedAsync.void { completion in
            self.setReaderFontSelection(
                fontName: fontName, expectedName: expectedName, expectedIndex: expectedIndex,
                expectedShareLayout: expectedShareLayout, completionHandler: completion
            )
        }
    }

    func setReaderLayoutAsync(style: ReaderStylePreferences) async throws {
        try await SharedAsync.void { completion in
            self.setReaderLayout(style: style, completionHandler: completion)
        }
    }

    func setReaderStyleForVariantAsync(style: ReaderStylePreferences, variant: ReaderVisualVariant, presetName: String? = nil, expectedIndex: Int32? = nil)
        async throws
    {
        try await SharedAsync.void { completion in
            self.setReaderStyleForVariant(
                style: style, variant: variant, presetName: presetName, expectedIndex: expectedIndex.map { KotlinInt(value: $0) }, completionHandler: completion
            )
        }
    }

    func restoreReaderPresetAsync(name: String, template: ReaderPreset, expectedIndex: Int32? = nil) async throws {
        try await SharedAsync.void { completion in
            self.restoreReaderPreset(name: name, template: template, expectedIndex: expectedIndex.map { KotlinInt(value: $0) }, completionHandler: completion)
        }
    }

    func replaceAndroidReaderPresetAsync(expectedName: String, jsonString: String, expectedIndex: Int32? = nil) async throws -> ReaderPreset {
        try await SharedAsync.value { completion in
            self.replaceAndroidReaderPreset(
                expectedName: expectedName, jsonString: jsonString, expectedIndex: expectedIndex.map { KotlinInt(value: $0) }, completionHandler: completion)
        }
    }
}
