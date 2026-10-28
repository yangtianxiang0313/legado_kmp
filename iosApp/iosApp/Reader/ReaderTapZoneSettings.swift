import Foundation
import shared

@MainActor
final class ReaderTapZoneSettings {
    private struct Edit {
        let zone: ReaderTapZoneSlot
        let action: ReaderTapZoneAction

        func applying(to actions: ReaderTapZoneActions) -> ReaderTapZoneActions {
            actions.updating(zone, action: action.rawValue).androidMenuSafeActions
        }
    }

    private let screen: ReaderAppearanceScreenAdapter
    private var pending: [Edit] = []
    private var writeTask: Task<Void, Never>?
    private var ownsSnapshot = false
    private(set) var actions: ReaderTapZoneActions?

    var onChange: ((ReaderTapZoneActions) -> Void)?
    var onError: ((Error) -> Void)?

    init(screen: ReaderAppearanceScreenAdapter) {
        self.screen = screen
    }

    func receive(_ observedActions: ReaderTapZoneActions) {
        // The adapter queues unversioned observer snapshots. Once editing begins,
        // only completed writes may advance this dialog's authoritative snapshot.
        guard !ownsSnapshot else { return }
        actions = observedActions.androidMenuSafeActions
        if let actions { onChange?(actions) }
    }

    /// Returns whether the reachable-menu safeguard restored the center action.
    @discardableResult
    func select(_ action: ReaderTapZoneAction, for zone: ReaderTapZoneSlot) -> Bool {
        guard let actions else { return false }
        let projected = pending.reduce(actions) { $1.applying(to: $0) }
        let requested = projected.updating(zone, action: action.rawValue)
        let restoresMenu = !requested.hasReachableMenuEntry
        guard requested.androidMenuSafeActions != projected else { return restoresMenu }
        ownsSnapshot = true
        pending.append(Edit(zone: zone, action: action))
        startWriteIfNeeded()
        return restoresMenu
    }

    private func startWriteIfNeeded() {
        guard writeTask == nil, !pending.isEmpty else { return }
        // Keep accepted edits alive through picker presentation or editor dismissal;
        // ReaderSettingsBoundViewController's cancellable setting tasks are not used.
        writeTask = Task { [self] in
            while let edit = pending.first, let committed = actions {
                let next = edit.applying(to: committed)
                do {
                    if next != committed {
                        try await screen.setTapZoneActions(actions: next)
                        actions = next
                        pending.removeFirst()
                        onChange?(next)
                        NotificationCenter.default.post(name: .readerTapZoneActionsDidChange, object: next)
                    } else {
                        pending.removeFirst()
                    }
                } catch {
                    // Drop only the failed edit. Later zone edits are rebased on the
                    // last successful write, never on an unpersisted full snapshot.
                    pending.removeFirst()
                    onError?(error)
                }
            }
            writeTask = nil
        }
    }
}
