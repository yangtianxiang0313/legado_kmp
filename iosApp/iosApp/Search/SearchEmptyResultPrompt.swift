import UIKit

/// SearchActivity.observeLiveBus: offer one recovery choice per completed search operation.
@MainActor
final class SearchEmptyResultPrompt {
    enum Action { case disablePrecision, switchToAll }

    struct Context: Equatable {
        let generation: UUID
        let keyword: String
        let scope: SearchScopeSelection
        let page: Int32
        let precisionSearch: Bool
    }

    private var revision = UUID()
    private var hasOffered = false
    private weak var dialog: ReaderRestoreProgressDialogViewController?

    func beginOperation() {
        invalidate()
        hasOffered = false
    }

    func invalidate() {
        revision = UUID()
        let current = dialog
        dialog = nil
        current?.dismiss(animated: false)
    }

    func presentIfNeeded(
        from presenter: UIViewController,
        context: Context?,
        isCurrent: @escaping (Context, UIViewController?) -> Bool,
        onConfirm: @escaping (Action) -> Void,
        onClose: @escaping () -> Void
    ) {
        guard !hasOffered, let context, context.scope != .allEnabled,
            isCurrent(context, nil)
        else { return }
        let requestID = revision
        let action: Action = context.precisionSearch ? .disablePrecision : .switchToAll
        let question = context.precisionSearch ? "关闭精准搜索" : "切换到全部分组"
        let alert = ReaderRestoreProgressDialogViewController(
            title: "搜索结果为空",
            message: "\(context.scope.displayName)分组搜索结果为空，是否\(question)？",
            accessibilityIdentifierPrefix: "search.emptyResult"
        ) { [weak self] accepted in
            guard accepted, let self, self.revision == requestID, isCurrent(context, nil) else { return }
            onConfirm(action)
        }
        alert.canConfirm = { [weak self, weak presenter, weak alert] in
            guard let self, self.revision == requestID, let presenter else { return false }
            return isCurrent(context, presenter.presentedViewController == nil ? nil : alert)
        }
        alert.onClose = { [weak self, weak alert] in
            if self?.dialog === alert { self?.dialog = nil }
            onClose()
        }
        // Set before presenting: the owner's presentation callback can synchronously re-enter.
        hasOffered = true
        dialog = alert
        presenter.present(alert, animated: true)
    }
}
