import UIKit
import shared

@MainActor
final class ChangeSourceMenuCoordinator {
    enum Action {
        case manage, refresh
        case option(ChangeSourceOption)
        case group(String)
        case close
        case top(BookSourceChangeCandidate)
        case bottom(BookSourceChangeCandidate)
        case edit(BookSourceChangeCandidate)
        case disable(BookSourceChangeCandidate)
        case delete(BookSourceChangeCandidate)
    }

    var onAction: ((Action) -> Void)?
    var onDismiss: (() -> Void)?
    private var popup: ReaderOverflowMenuView?
    private let groupPopup = SearchOverflowMenuView()
    private var emptySearchGroup: String?
    private var emptySearchRequestID = UUID()
    private weak var emptySearchAlert: UIAlertController?
    var isVisible: Bool { popup != nil || groupPopup.superview != nil || emptySearchAlert != nil }

    init() {
        groupPopup.onVisibilityChange = { [weak self] visible in
            if !visible { self?.onDismiss?() }
        }
    }

    func offerAllGroupsAfterEmptySearch(group: String) {
        emptySearchGroup = group.isEmpty ? nil : group
    }

    func resetEmptySearchRecovery() {
        emptySearchRequestID = UUID()
        emptySearchGroup = nil
        emptySearchAlert?.dismiss(animated: false)
        emptySearchAlert = nil
    }

    func showEmptySearchRecovery(group: String, host: UIViewController, onConfirm: @escaping () -> Void) {
        guard let pendingGroup = emptySearchGroup else { return }
        guard group == pendingGroup else {
            resetEmptySearchRecovery()
            return
        }
        guard !isVisible, host.canPerformNavigationAction else { return }
        let id = emptySearchRequestID
        let alert = UIAlertController(
            title: "搜索结果为空", message: "\(group)分组搜索结果为空,是否切换到全部分组", preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "changeSource.emptyGroupConfirmation"
        alert.overrideUserInterfaceStyle = host.traitCollection.userInterfaceStyle
        emptySearchGroup = nil
        emptySearchAlert = alert
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                alert?.dismiss(animated: true) { [weak self] in
                    guard let self, self.emptySearchRequestID == id else { return }
                    self.emptySearchAlert = nil
                    self.onDismiss?()
                }
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak host, weak alert] _ in
                alert?.dismiss(animated: true) { [weak self, weak host] in
                    guard let self, self.emptySearchRequestID == id else { return }
                    self.emptySearchAlert = nil
                    self.onDismiss?()
                    guard host?.canPerformNavigationAction == true else { return }
                    onConfirm()
                }
            })
        host.present(alert, animated: true)
    }

    func show(state: ChangeSourceScreenState, anchor: UIView, host: UIView) {
        if popup != nil {
            dismiss()
            return
        }
        var items = [item("manage", "书源管理", .manage), item("refresh", "刷新列表", .refresh)]
        items += ChangeSourceOption.allCases.map { option in
            item(option.rawValue, option.title, .option(option), checked: option.value(in: state.config))
        }
        let title = state.config.searchGroup.isEmpty ? "分组" : "分组(\(state.config.searchGroup))"
        items.append(
            .init(identifier: "changeSource.menu.group", title: title) { [weak self, weak anchor, weak host] in
                guard let self, let anchor, let host else { return }
                self.showGroups(state: state, anchor: anchor, host: host)
            })
        items.append(item("close", "关闭", .close))
        present(items, anchor: anchor, host: host)
    }

    func show(candidate: BookSourceChangeCandidate, anchor: UIView, host: UIView) {
        dismiss()
        present(
            [
                item("top", "置顶书源", .top(candidate)), item("bottom", "置底书源", .bottom(candidate)),
                item("edit", "编辑书源", .edit(candidate)), item("disable", "禁用书源", .disable(candidate)),
                item("delete", "删除书源", .delete(candidate)),
            ], anchor: anchor, host: host)
    }

    func dismiss() {
        popup?.dismiss()
        popup = nil
        groupPopup.dismiss()
    }

    private func showGroups(state: ChangeSourceScreenState, anchor: UIView, host: UIView) {
        let groups = [""] + state.groups
        let selected = state.groups.contains(state.config.searchGroup) ? state.config.searchGroup : ""
        let items = groups.enumerated().map { index, group in
            SearchOverflowMenuView.Item(
                id: String(index), title: group.isEmpty ? "全部书源" : group, selection: .radio,
                isSelected: group == selected)
        }
        groupPopup.show(in: host, anchor: anchor, items: items) { [weak self] id in
            guard let index = Int(id), groups.indices.contains(index), groups[index] != selected else { return }
            self?.onAction?(.group(groups[index]))
        }
    }

    private func item(_ id: String, _ title: String, _ action: Action, checked: Bool? = nil)
        -> ReaderOverflowMenuView.Item
    {
        .init(identifier: "changeSource.menu." + id, title: title, isChecked: checked) { [weak self] in
            self?.onAction?(action)
        }
    }

    private func present(_ items: [ReaderOverflowMenuView.Item], anchor: UIView, host: UIView) {
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: anchor, interfaceStyle: host.traitCollection.userInterfaceStyle)
        popup = menu
        menu.onDismiss = { [weak self, weak menu] in
            guard self?.popup === menu else { return }
            self?.popup = nil
            self?.onDismiss?()
        }
        menu.present(in: host)
    }
}
