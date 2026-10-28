import UIKit
import shared

/// ThemeConfigFragment's color, name and catalog dialogs share the settings page's binding.
@MainActor
final class ThemeSettingsCoordinator {
    private weak var owner: UIViewController?
    private let screen: SettingsScreenAdapter
    private let generation: () -> UInt64
    private let isSessionCurrent: (UInt64) -> Bool
    private let onChange: () -> Void
    private let onBusy: (Bool) -> Void
    private var isBusy = false
    private var task: Task<Void, Never>?
    private lazy var backgroundCoordinator = ThemeBackgroundCoordinator(owner: owner)

    init(
        owner: UIViewController, screen: SettingsScreenAdapter,
        generation: @escaping () -> UInt64, isSessionCurrent: @escaping (UInt64) -> Bool,
        onChange: @escaping () -> Void, onBusy: @escaping (Bool) -> Void
    ) {
        self.owner = owner
        self.screen = screen
        self.generation = generation
        self.isSessionCurrent = isSessionCurrent
        self.onChange = onChange
        self.onBusy = onBusy
    }

    deinit { task?.cancel() }

    func backgroundSummary(isNight: Bool) -> String {
        ThemeBackgroundConfiguration.read(channel: .init(isNight: isNight)).summary
    }

    func showBackground(isNight: Bool) {
        let session = generation()
        guard canPresent(session) else { return }
        backgroundCoordinator.show(
            channel: .init(isNight: isNight),
            isCurrent: { [weak self] in self?.isCurrent(session) == true },
            performChange: { [weak self] operation in
                guard let self else { throw CancellationError() }
                try await self.change(session) { _ in try await operation() }
            })
    }

    func showPresets() {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let dialog = ThemeListDialogViewController(
            loadPresets: { [weak self] in
                guard let self, self.isCurrent(session) else { return [] }
                return self.screen.themePresets
            },
            onApply: { [weak self] preset in
                guard let self else { throw CancellationError() }
                try await self.change(session) { try await $0.applyThemePreset(themeName: preset.themeName) }
            },
            onDelete: { [weak self] preset in
                guard let self else { throw CancellationError() }
                try await self.change(session) { try await $0.deleteThemePreset(themeName: preset.themeName) }
            },
            onImport: { [weak self] json in
                guard let self else { throw CancellationError() }
                try await self.change(session) { try await $0.importThemePreset(json: json) }
            })
        dialog.canSubmit = { [weak self, weak dialog] in
            guard let self, let dialog else { return false }
            return self.isCurrent(session) && self.owner?.presentedViewController === dialog
        }
        owner.present(dialog, animated: true)
    }

    func showColor(_ field: ThemeColorSetting, isNight: Bool) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        do {
            let palette = try screen.themePalette(isNight: isNight)
            guard let color = field.color(in: palette) else { return }
            let initial = field.hex(in: palette)
            let bindingIsCurrent = { [weak self] in
                guard let self, self.isCurrent(session),
                    let current = try? self.screen.themePalette(isNight: isNight)
                else { return false }
                return field.hex(in: current) == initial
            }
            let dialog = ReaderColorPickerDialogViewController(color: color, startsWithPresets: true) {
                [weak self] selected in
                guard bindingIsCurrent() else { return }
                self?.run(session) { screen in
                    guard bindingIsCurrent() else { throw CancellationError() }
                    try await screen.setThemeColor(
                        isNight: isNight, field: field.sharedField, color: ThemeColorSetting.hex(selected))
                }
            }
            dialog.canSubmit = bindingIsCurrent
            owner.present(dialog, animated: true)
        } catch { owner.presentError(error) }
    }

    func showSave(isNight: Bool) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let dialog = ReaderConfigURLDialogViewController(themeName: "") { [weak self] name in
            self?.run(session) { try await $0.saveThemePalette(name: name, isNight: isNight) }
        }
        dialog.canSubmit = { [weak self] in self?.isCurrent(session) == true }
        owner.present(dialog, animated: true)
    }

    func toggleMode() {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let next: ThemeMode = owner.traitCollection.userInterfaceStyle == .dark ? .light : .dark
        run(session) { try await $0.setThemeMode(mode: next) }
    }

    func showModePicker(current: ThemeMode?) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let choices: [(String, ThemeMode)] = [
            (L10n.Settings.themeModeSystem, .system),
            (L10n.Settings.themeModeLight, .light),
            (L10n.Settings.themeModeDark, .dark),
        ]
        let dialog = ReaderPreferenceChoiceDialogViewController(
            title: L10n.Settings.themeModePicker, items: choices.map(\.0),
            selectedIndex: choices.firstIndex { $0.1 == current } ?? 0,
            identifier: "settings.theme.mode"
        ) { [weak self] index in
            guard choices.indices.contains(index) else { return }
            self?.run(session) { try await $0.setThemeMode(mode: choices[index].1) }
        }
        dialog.canSelect = { [weak self] in self?.isCurrent(session) == true }
        owner.present(dialog, animated: true)
    }

    private func isCurrent(_ session: UInt64) -> Bool {
        guard let owner, isSessionCurrent(session),
            UIApplication.shared.applicationState == .active,
            let window = owner.viewIfLoaded?.window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    private func canPresent(_ session: UInt64) -> Bool {
        !isBusy && isCurrent(session) && owner?.presentedViewController == nil
            && owner?.canPerformNavigationAction == true
    }

    private func change(_ session: UInt64, operation: (SettingsScreenAdapter) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !isBusy, isCurrent(session) else { throw CancellationError() }
        isBusy = true
        onBusy(true)
        defer {
            isBusy = false
            onBusy(false)
            onChange()
        }
        try await operation(screen)
        try Task.checkCancellation()
        guard isCurrent(session) else { throw CancellationError() }
    }

    private func run(_ session: UInt64, operation: @escaping (SettingsScreenAdapter) async throws -> Void) {
        guard !isBusy, isCurrent(session), owner?.presentedViewController == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.change(session, operation: operation) } catch {
                guard self.isCurrent(session), !(error is CancellationError) else { return }
                self.owner?.presentError(error)
            }
            self.task = nil
        }
    }
}
