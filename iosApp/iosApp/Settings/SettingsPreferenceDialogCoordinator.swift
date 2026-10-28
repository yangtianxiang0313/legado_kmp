import UIKit
import shared

/// Settings preferences use the same Android alert surfaces as their reading counterparts.
@MainActor
final class SettingsPreferenceDialogCoordinator {
    private weak var owner: UIViewController?
    private let screen: SettingsScreenAdapter
    private let generation: () -> UInt64
    private let isSessionCurrent: (UInt64) -> Bool
    private let canInteract: () -> Bool
    private let onBusy: (Bool) -> Void
    private let onChange: () -> Void
    private var isBusy = false
    private var task: Task<Void, Never>?

    init(
        owner: UIViewController, screen: SettingsScreenAdapter,
        generation: @escaping () -> UInt64, isSessionCurrent: @escaping (UInt64) -> Bool,
        canInteract: @escaping () -> Bool, onBusy: @escaping (Bool) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.owner = owner
        self.screen = screen
        self.generation = generation
        self.isSessionCurrent = isSessionCurrent
        self.canInteract = canInteract
        self.onBusy = onBusy
        self.onChange = onChange
    }

    deinit { task?.cancel() }

    func showBookshelfLayout(current: BookshelfLayoutMode?) {
        let options: [(String, BookshelfLayoutMode)] = [
            (L10n.Settings.layoutList, .list), (L10n.Settings.layoutGrid3, .grid3),
            (L10n.Settings.layoutGrid4, .grid4), (L10n.Settings.layoutGrid5, .grid5),
            (L10n.Settings.layoutGrid6, .grid6),
        ]
        showChoice(
            title: L10n.Settings.bookshelfLayoutPicker, items: options.map(\.0),
            selectedIndex: options.firstIndex { $0.1 == current } ?? -1, identifier: "settings.bookshelfLayout"
        ) { [weak self] index, session in
            guard options.indices.contains(index) else { return }
            self?.run(session) { try await $0.setBookshelfLayoutMode(mode: options[index].1) }
        }
    }

    func showDefaultHome(current: Int) {
        let items = [L10n.Tabs.bookshelf, L10n.Tabs.discovery, L10n.Tabs.rss, L10n.Tabs.settings]
        showChoice(
            title: L10n.Settings.defaultHomePicker, items: items, selectedIndex: current,
            identifier: "settings.defaultHome"
        ) { [weak self] index, session in
            guard items.indices.contains(index) else { return }
            self?.run(session) { _ in RestoredAppPreferences.set(index, forKey: "defaultHomePage") }
        }
    }

    func showThreadCount(current: Int) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let dialog = AndroidReaderNumberPickerDialogViewController(
            titleText: L10n.Settings.threadCountPicker, value: current, range: 1...999,
            valueTitle: { "\($0)" },
            completion: { [weak self] value in
                self?.run(session) { try await $0.setThreadCount(count: value) }
            })
        owner.present(dialog, animated: true)
    }

    func showBackupIgnore(selected: Set<String>, options: [(key: String, title: String)]) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let known = Set(options.map(\.key))
        let unknown = selected.subtracting(known)
        let dialog = SettingsMultiChoiceDialogViewController(
            titleText: L10n.Settings.restoreIgnoreTitle, items: options.map(\.title),
            selectedIndices: Set(options.indices.filter { selected.contains(options[$0].key) }),
            identifier: "settings.backupIgnore"
        ) { [weak self] indices in
            let keys = unknown.union(indices.filter { options.indices.contains($0) }.map { options[$0].key })
            guard keys != selected else { return }
            self?.run(session) { try await $0.setBackupRestoreIgnoredKeys(keys: keys.sorted()) }
        }
        dialog.canCommit = { [weak self] in self?.isCurrent(session) == true }
        owner.present(dialog, animated: true)
    }

    func showTextEditor(
        title: String, value: String?, placeholder: String, isSecure: Bool,
        usesUserAgentLayout: Bool, save: @escaping (String?) async throws -> Void
    ) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let dialog = SettingsTextPreferenceDialogViewController(
            titleText: title, value: value, placeholder: placeholder, isSecure: isSecure,
            usesUserAgentLayout: usesUserAgentLayout
        ) { [weak self] raw in
            guard let self else { throw CancellationError() }
            try await self.change(session) { _ in
                // EditTextPreference preserves meaningful spaces, notably in credentials.
                try await save(raw.isEmpty ? nil : raw)
            }
        }
        dialog.canSubmit = { [weak self, weak dialog] in
            guard let self, let dialog, self.isCurrent(session) else { return false }
            return self.owner?.presentedViewController === dialog
        }
        dialog.onDismiss = { [weak self] in
            guard let self, self.isCurrent(session) else { return }
            self.onChange()
        }
        owner.present(dialog, animated: true)
    }

    private func showChoice(
        title: String, items: [String], selectedIndex: Int, identifier: String,
        onSelect: @escaping (Int, UInt64) -> Void
    ) {
        let session = generation()
        guard canPresent(session), let owner else { return }
        let dialog = ReaderPreferenceChoiceDialogViewController(
            title: title, items: items, selectedIndex: selectedIndex, identifier: identifier
        ) { [weak self] index in
            guard self?.isCurrent(session) == true else { return }
            onSelect(index, session)
        }
        dialog.canSelect = { [weak self] in self?.isCurrent(session) == true }
        owner.present(dialog, animated: true)
    }

    private func isCurrent(_ session: UInt64) -> Bool {
        guard let owner, generation() == session, isSessionCurrent(session),
            UIApplication.shared.applicationState == .active,
            let window = owner.viewIfLoaded?.window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    private func canPresent(_ session: UInt64) -> Bool {
        !isBusy && canInteract() && isCurrent(session) && owner?.presentedViewController == nil
            && owner?.canPerformNavigationAction == true
    }

    private func change(
        _ session: UInt64, operation: (SettingsScreenAdapter) async throws -> Void
    ) async throws {
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
        guard !isBusy, isCurrent(session) else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.change(session, operation: operation) } catch {
                guard !(error is CancellationError), self.isCurrent(session) else { return }
                self.owner?.presentError(error)
            }
        }
    }
}
