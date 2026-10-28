import UIKit
import shared

@MainActor
final class ThemeBackgroundSettingsClient {
    private var facade: ThemeSettingsFacade?

    func configuration(_ channel: ThemeBackgroundChannel) throws -> ThemeBackgroundConfiguration {
        let value = try resolve().background(isNightTheme: channel.isNight)
        return ThemeBackgroundConfiguration(channel: channel, imagePath: value.imagePath, blurring: Int(value.blurring))
    }

    func replaceImage(_ path: String?, expected: ThemeBackgroundConfiguration) async throws {
        let facade = try resolve()
        try await SharedAsync.void {
            facade.setBackgroundImage(
                isNightTheme: expected.channel.isNight, imagePath: path,
                expectedImagePath: expected.imagePath, completionHandler: $0)
        }
        ThemeBackgroundConsumer.refreshAll()
    }

    func setBlurring(_ value: Int, expected: ThemeBackgroundConfiguration) async throws {
        let facade = try resolve()
        try await SharedAsync.void {
            facade.setBackgroundBlurring(
                isNightTheme: expected.channel.isNight, blurring: Int32(value),
                expectedBlurring: Int32(expected.blurring), completionHandler: $0)
        }
        ThemeBackgroundConsumer.refreshAll()
    }

    func referencedPaths() throws -> [String] {
        try ThemeBackgroundChannel.allCases.compactMap { try configuration($0).imagePath }
    }

    private func resolve() throws -> ThemeSettingsFacade {
        if let facade { return facade }
        let resolved = try SharedRuntime.settingsFacade().get().themeSettings
        facade = resolved
        return resolved
    }
}
