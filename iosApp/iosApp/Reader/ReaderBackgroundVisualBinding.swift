import UIKit
import shared

/// Drain an editor's captured scheme/variant before binding another appearance.
@MainActor
final class ReaderBackgroundVisualBinding {
    private let facade: SettingsFacade
    private var preferences: AppUiPreferences?
    private var interfaceStyle: UIUserInterfaceStyle = .light
    private var rebindTask: Task<Void, Never>?
    private(set) var variant: ReaderVisualVariant
    private(set) var queue: ReaderBackgroundTextWriteQueue
    var presetName: String
    private(set) var presetIndex: Int32
    var onChange: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var isSwitching: Bool { rebindTask != nil }

    init(style: ReaderStylePreferences, presetName: String, variant: ReaderVisualVariant, facade: SettingsFacade, presetIndex: Int32 = 0) {
        self.facade = facade
        self.presetName = presetName
        self.presetIndex = presetIndex
        self.variant = variant
        queue = Self.makeQueue(style: style, name: presetName, index: presetIndex, variant: variant, facade: facade)
        bindCallbacks()
    }

    func receive(_ preferences: AppUiPreferences, interfaceStyle: UIUserInterfaceStyle) {
        self.preferences = preferences
        self.interfaceStyle = interfaceStyle
        guard rebindTask == nil else { return }
        let target = ReaderThemeVisualStyle.variant(preferences: preferences, userInterfaceStyle: interfaceStyle)
        if target == variant && preferences.readerPresetName == presetName && preferences.readerPresetIndex == presetIndex {
            queue.absorb(preferences.effectiveReaderStyle(userInterfaceStyle: interfaceStyle))
        } else {
            beginRebinding()
        }
        onChange?()
    }

    func updateInterfaceStyle(_ interfaceStyle: UIUserInterfaceStyle) {
        guard let preferences else { return }
        receive(preferences, interfaceStyle: interfaceStyle)
    }

    func acceptSnapshot(_ preferences: AppUiPreferences, interfaceStyle: UIUserInterfaceStyle) {
        self.preferences = preferences
        self.interfaceStyle = interfaceStyle
        let target = ReaderThemeVisualStyle.variant(preferences: preferences, userInterfaceStyle: interfaceStyle)
        if !isSwitching, target == variant, preferences.readerPresetName == presetName, preferences.readerPresetIndex == presetIndex {
            queue.acceptSnapshot(preferences.effectiveReaderStyle(userInterfaceStyle: interfaceStyle))
        } else {
            receive(preferences, interfaceStyle: interfaceStyle)
        }
    }

    func flush() async throws {
        while let task = rebindTask { await task.value }
        try await queue.flush()
    }

    func retry() {
        queue.retry()
        if let preferences { receive(preferences, interfaceStyle: interfaceStyle) }
    }

    func discardFailedChanges() {
        queue.discardFailedChanges()
        if let preferences { receive(preferences, interfaceStyle: interfaceStyle) }
    }

    private func beginRebinding() {
        rebindTask = Task { [self] in
            defer {
                rebindTask = nil
                onChange?()
            }
            do {
                try await queue.flush()
                let latest = try await ReaderAppearanceSnapshotRequest.read(facade: facade).preferences
                preferences = latest
                presetName = latest.readerPresetName
                presetIndex = latest.readerPresetIndex
                variant = ReaderThemeVisualStyle.variant(preferences: latest, userInterfaceStyle: interfaceStyle)
                queue = Self.makeQueue(
                    style: latest.effectiveReaderStyle(userInterfaceStyle: interfaceStyle),
                    name: presetName, index: presetIndex, variant: variant, facade: facade)
                bindCallbacks()
            } catch { onFailure?(error) }
        }
    }

    private func bindCallbacks() {
        queue.onChange = { [weak self] in self?.onChange?() }
        queue.onFailure = { [weak self] error in self?.onFailure?(error) }
    }

    private static func makeQueue(
        style: ReaderStylePreferences, name: String, index: Int32, variant: ReaderVisualVariant, facade: SettingsFacade
    ) -> ReaderBackgroundTextWriteQueue {
        ReaderBackgroundTextWriteQueue(style: style) {
            try await facade.setReaderStyleForVariantAsync(style: $0, variant: variant, presetName: name, expectedIndex: index)
        }
    }
}
