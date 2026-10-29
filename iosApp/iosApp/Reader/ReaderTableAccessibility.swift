import UIKit

@MainActor
enum ReaderTableAccessibility {
    static func activate(_ cell: UITableViewCell) -> Bool {
        guard !cell.accessibilityTraits.contains(.notEnabled),
            let window = cell.window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive
        else { return false }

        var ancestor: UIView? = cell
        var table: UITableView?
        var opacity: CGFloat = 1
        while let view = ancestor {
            opacity *= view.alpha
            guard !view.isHidden, !view.accessibilityElementsHidden,
                view.isUserInteractionEnabled, opacity > 0.01
            else { return false }
            if let candidate = view as? UITableView { table = candidate }
            ancestor = view.superview
        }
        guard let table, table.window === window,
            !table.isTracking, !table.isDragging, !table.isDecelerating,
            table.isEditing ? table.allowsSelectionDuringEditing : table.allowsSelection,
            table.visibleCells.contains(where: { $0 === cell }),
            let indexPath = table.indexPath(for: cell),
            let delegate = table.delegate,
            let didSelect = delegate.tableView(_:didSelectRowAt:),
            hasActiveOwner(cell)
        else { return false }

        let target: IndexPath
        if let willSelect = delegate.tableView(_:willSelectRowAt:) {
            guard let approved = willSelect(table, indexPath) else { return false }
            target = approved
        } else {
            target = indexPath
        }
        guard target.section >= 0, target.section < table.numberOfSections,
            target.row >= 0, target.row < table.numberOfRows(inSection: target.section)
        else { return false }

        // Programmatic selection does not deliver the normal delegate callback.
        table.selectRow(at: target, animated: false, scrollPosition: .none)
        didSelect(table, target)
        return true
    }

    private static func hasActiveOwner(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var owner = responder as? UIViewController else { return false }
        while true {
            guard !owner.isBeingDismissed, !owner.isBeingPresented, !owner.isMovingFromParent,
                owner.presentedViewController == nil
            else { return false }
            if let navigation = owner.parent as? UINavigationController,
                navigation.topViewController !== owner
            {
                return false
            }
            guard let parent = owner.parent else { return true }
            owner = parent
        }
    }
}
