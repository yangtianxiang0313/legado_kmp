import UIKit
import shared

struct ReaderAppearanceSelectionContext {
    let presetName: String
    let presetIndex: Int32
    let shareLayout: Bool
    let themeMode: ThemeMode

    init(_ state: ReaderAppearanceState) {
        presetName = state.preferences.readerPresetName
        presetIndex = state.preferences.readerPresetIndex
        shareLayout = state.runtimeConfig.reader.shareLayout
        themeMode = state.preferences.themeMode
    }

    func matches(_ state: ReaderAppearanceState) -> Bool {
        presetName == state.preferences.readerPresetName && presetIndex == state.preferences.readerPresetIndex
            && shareLayout == state.runtimeConfig.reader.shareLayout && themeMode == state.preferences.themeMode
    }

    @MainActor
    static func isVisible(_ host: UIViewController) -> Bool {
        guard host.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            host.navigationController.map({ $0.topViewController === host }) != false
        else { return false }
        var current: UIViewController? = host
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent else { return false }
            current = controller.parent
        }
        return true
    }
}
