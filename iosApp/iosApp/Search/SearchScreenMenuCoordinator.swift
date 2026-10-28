import UIKit

@MainActor
final class SearchScreenMenuCoordinator {
    private let menu = SearchOverflowMenuView()
    private var presentationID = UUID()

    var isPresented: Bool { menu.isPresented }
    /// Visibility only: observers may pause/resume content, but must not replay a menu action.
    var onPresentationChange: ((Bool) -> Void)?

    init() {
        menu.onVisibilityChange = { [weak self] isPresented in
            self?.onPresentationChange?(isPresented)
        }
    }

    func present(
        from presenter: UIViewController,
        anchor: UIView,
        scope: SearchScopeSelection,
        groups: [String],
        precisionSearch: Bool,
        onTogglePrecision: @escaping () -> Void,
        onScopeDialog: @escaping () -> Void,
        onScopeSelected: @escaping (SearchScopeSelection) -> Void
    ) {
        let menuScope: SearchScopeSelection
        switch scope {
        case .group(let group) where !groups.contains(group):
            menuScope = .allEnabled
        case .groups(let selected) where !groups.contains(where: { selected.contains($0) }):
            menuScope = .allEnabled
        default:
            menuScope = scope
        }
        // SearchActivity.onMenuOpened (146-149) clears a scope with no checked group.
        // Apply before assigning this presentation's ID: restarting search dismisses menus.
        if menuScope != scope { onScopeSelected(menuScope) }
        let id = UUID()
        presentationID = id
        menu.dismiss()
        guard presentationID == id else { return }
        // The real toolbar anchor is intentionally paused by onPresentationChange(true).
        let context = ReaderOverflowPresentationContext(anchor: presenter.view, host: presenter.view)
        menu.canActivateItem = { [weak self, weak presenter] in
            guard let self, self.presentationID == id, let presenter, context.isCurrent,
                presenter.navigationController?.topViewController === presenter,
                presenter.presentedViewController == nil
            else { return false }
            return true
        }
        var items: [SearchOverflowMenuView.Item] = [
            .init(id: "precision", title: L10n.Settings.precisionSearchTitle, selection: .checkbox, isSelected: precisionSearch),
            .init(id: "sources", title: L10n.Settings.sourceManagementTitle),
            .init(id: "scope", title: "多分组/书源"),
        ]
        var selections: [String: SearchScopeSelection] = [:]
        let selectedGroups: [String]
        switch menuScope {
        case .source(_, let name):
            items.append(.init(id: "currentSource", title: name, selection: .checkbox, isSelected: true))
            selections["currentSource"] = .allEnabled
            selectedGroups = []
        case .group(let group):
            selectedGroups = [group]
        case .groups(let values):
            selectedGroups = values
        case .allEnabled:
            selectedGroups = []
        }
        for group in groups where selectedGroups.contains(group) {
            let key = "selectedGroup.\(group)"
            items.append(.init(id: key, title: group, selection: .checkbox, isSelected: true))
            let remaining = selectedGroups.filter { $0 != group }
            selections[key] = remaining.isEmpty ? .allEnabled : (remaining.count == 1 ? .group(remaining[0]) : .groups(remaining))
        }
        items.append(.init(id: "all", title: "全部书源", selection: .radio, isSelected: menuScope == .allEnabled))
        selections["all"] = .allEnabled
        for group in groups where !selectedGroups.contains(group) {
            let key = "group.\(group)"
            items.append(.init(id: key, title: group, selection: .radio))
            selections[key] = .group(group)
        }
        items.append(.init(id: "log", title: L10n.Bookshelf.logTitle))
        menu.show(in: presenter.view, anchor: anchor, items: items) { [weak self, weak presenter] action in
            guard let self, self.presentationID == id, let presenter, context.isCurrent,
                presenter.navigationController?.topViewController === presenter,
                presenter.presentedViewController == nil
            else { return }
            self.dismiss()
            if let selection = selections[action] {
                onScopeSelected(selection)
                return
            }
            switch action {
            case "precision":
                onTogglePrecision()
            case "sources":
                presenter.view.endEditing(true)
                presenter.navigationController?.pushViewController(AndroidReplicaSourceManagementViewController(), animated: true)
            case "scope":
                onScopeDialog()
            case "log":
                presenter.view.endEditing(true)
                presenter.present(ReaderAppLogDialogViewController(), animated: true)
            default:
                break
            }
        }
    }

    func refreshAppearance(interfaceStyle: UIUserInterfaceStyle? = nil) {
        menu.refreshAppearance(interfaceStyle: interfaceStyle)
    }

    func dismiss() {
        presentationID = UUID()
        menu.dismiss()
    }
}
