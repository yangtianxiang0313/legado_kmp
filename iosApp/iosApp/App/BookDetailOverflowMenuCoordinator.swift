import UIKit
import shared

/// book_info.xml at Legado 5f5d314. Only commands backed by the current shared core are exposed.
enum BookDetailOverflowAction: String {
    case refresh = "menu_refresh"
    case login = "menu_login"
    case pin = "menu_top"
    case sourceVariable = "menu_set_source_variable"
    case bookVariable = "menu_set_book_variable"
    case copyBookURL = "menu_copy_book_url"
    case copyTocURL = "menu_copy_toc_url"
    case canUpdate = "menu_can_update"
    case deleteAlert = "menu_delete_alert"
    case clearCache = "menu_clear_cache"
    case log = "menu_log"

    static func visibleActions(hasSource: Bool, loginURL: String?, loginUI: String? = nil) -> [Self] {
        let hasLogin =
            loginURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || loginUI?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return [.refresh]
            + (hasSource && hasLogin ? [.login] : [])
            + [.pin] + (hasSource ? [.sourceVariable, .bookVariable] : [])
            + [.copyBookURL, .copyTocURL] + (hasSource ? [.canUpdate] : []) + [.deleteAlert, .clearCache, .log]
    }

    var title: String {
        switch self {
        case .refresh: return L10n.Common.refresh
        case .login: return L10n.SourceEdit.loginAction
        case .pin: return L10n.BookDetail.pinToTop
        case .sourceVariable: return "设置源变量"
        case .bookVariable: return "设置书籍变量"
        case .copyBookURL: return L10n.BookDetail.copyBookUrl
        case .copyTocURL: return L10n.BookDetail.copyTocUrl
        case .canUpdate: return L10n.Bookshelf.enableUpdate
        case .deleteAlert: return "删除提醒"
        case .clearCache: return L10n.BookDetail.clearCache
        case .log: return L10n.Bookshelf.logTitle
        }
    }
}

@MainActor
final class BookDetailOverflowMenuCoordinator {
    private struct Context: Equatable {
        let bookURL: String
        let origin: String
    }

    private weak var presenter: UIViewController?
    private let adapter: AndroidReplicaBookDetailAdapter
    private let currentBook: () -> Book?
    private let canPresent: () -> Bool
    private let waitForDetailLoad: () async -> Void
    private let onBusyChange: (Bool) -> Void
    private let onCommitted: (Book) -> Void
    private let onRefresh: () -> Void
    private var menu: ReaderOverflowMenuView?
    private var preparationTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?

    init(
        presenter: UIViewController, adapter: AndroidReplicaBookDetailAdapter,
        currentBook: @escaping () -> Book?, canPresent: @escaping () -> Bool,
        waitForDetailLoad: @escaping () async -> Void,
        onBusyChange: @escaping (Bool) -> Void,
        onCommitted: @escaping (Book) -> Void, onRefresh: @escaping () -> Void
    ) {
        self.presenter = presenter
        self.adapter = adapter
        self.currentBook = currentBook
        self.canPresent = canPresent
        self.waitForDetailLoad = waitForDetailLoad
        self.onBusyChange = onBusyChange
        self.onCommitted = onCommitted
        self.onRefresh = onRefresh
    }

    deinit { preparationTask?.cancel() }

    func dismiss() {
        preparationID = nil
        preparationTask?.cancel()
        preparationTask = nil
        menu?.dismiss()
        menu = nil
    }

    func present(anchor: UIView) {
        guard operationTask == nil, preparationTask == nil, let presenter,
            canPresent(), presenter.presentedViewController == nil,
            let book = currentBook(), anchor.window === presenter.viewIfLoaded?.window,
            anchor.window?.windowScene?.activationState == .foregroundActive
        else { return }
        if menu != nil {
            dismiss()
            return
        }
        let context = Context(bookURL: book.bookUrl, origin: book.origin)
        let id = UUID()
        preparationID = id
        preparationTask = Task { [weak self, weak anchor] in
            guard let self else { return }
            defer {
                if self.preparationID == id {
                    self.preparationID = nil
                    self.preparationTask = nil
                }
            }
            do {
                let source = try await self.adapter.loadMenuSource(expectedBookURL: context.bookURL)
                guard self.preparationID == id, let anchor, self.accepts(context),
                    let book = self.currentBook(), anchor.window === presenter.view.window
                else { return }
                self.show(book: book, source: source, context: context, anchor: anchor, presenter: presenter)
            } catch is CancellationError {
            } catch {
                guard self.preparationID == id, self.accepts(context) else { return }
                presenter.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func show(book: Book, source: BookSource?, context: Context, anchor: UIView, presenter: UIViewController) {
        let actions = BookDetailOverflowAction.visibleActions(
            hasSource: source != nil, loginURL: source?.loginUrl, loginUI: source?.loginUi)
        let items = actions.map { action in
            ReaderOverflowMenuView.Item(
                identifier: "bookDetail.\(action.rawValue)", title: action.title,
                isChecked: action == .canUpdate
                    ? book.canUpdate
                    : (action == .deleteAlert ? BookDetailRemovalPreferences().confirmsRemoval : nil)
            ) { [weak self] in
                guard let self, self.accepts(context) else { return }
                self.activate(action, context: context)
            }
        }
        let popup = ReaderOverflowMenuView(
            items: items, anchorView: anchor, interfaceStyle: presenter.traitCollection.userInterfaceStyle)
        popup.onDismiss = { [weak self, weak popup] in
            if self?.menu === popup { self?.menu = nil }
        }
        menu = popup
        popup.present(in: presenter.view)
    }

    private func activate(_ action: BookDetailOverflowAction, context: Context) {
        guard let presenter, let book = currentBook(), accepts(context), operationTask == nil else { return }
        switch action {
        case .refresh: onRefresh()
        case .copyBookURL:
            UIPasteboard.general.string = book.bookUrl
            presenter.showTransientMessage(L10n.BookDetail.copied)
        case .copyTocURL:
            UIPasteboard.general.string = book.tocUrl
            presenter.showTransientMessage(L10n.BookDetail.copied)
        case .log:
            let controller = ReaderAppLogDialogViewController()
            controller.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
            presenter.present(controller, animated: true)
        case .deleteAlert:
            let preferences = BookDetailRemovalPreferences()
            preferences.confirmsRemoval.toggle()
        case .pin, .canUpdate, .clearCache, .login, .sourceVariable, .bookVariable:
            perform(action, context: context)
        }
    }

    private func perform(_ action: BookDetailOverflowAction, context: Context) {
        let id = UUID()
        operationID = id
        onBusyChange(true)
        operationTask = Task { [self] in
            defer {
                if operationID == id {
                    operationID = nil
                    operationTask = nil
                    onBusyChange(false)
                }
            }
            do {
                await waitForDetailLoad()
                guard isSameBook(context), let presenter,
                    presenter.navigationController?.topViewController === presenter,
                    presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil,
                    !presenter.isMovingFromParent, !presenter.isBeingDismissed
                else { return }
                switch action {
                case .sourceVariable, .bookVariable:
                    let forSource = action == .sourceVariable
                    let snapshot = try await adapter.loadVariableEditor(
                        expectedBookURL: context.bookURL, sourceURL: context.origin, forSource: forSource)
                    guard isVisible(context), presenter.presentedViewController == nil else { return }
                    presentVariableEditor(snapshot, forSource: forSource, context: context, in: presenter)
                case .pin:
                    let updated = try await adapter.pinToTop(expectedBookURL: context.bookURL)
                    if isSameBook(context) { onCommitted(updated) }
                    if isVisible(context) { presenter.showTransientMessage(L10n.BookDetail.pinToTopDone) }
                case .canUpdate:
                    let updated = try await adapter.toggleCanUpdate(expectedBookURL: context.bookURL)
                    if isSameBook(context) { onCommitted(updated) }
                    if isVisible(context) {
                        presenter.showTransientMessage(
                            updated.canUpdate ? L10n.BookDetail.canUpdateOn : L10n.BookDetail.canUpdateOff)
                    }
                case .clearCache:
                    try await adapter.clearCache(expectedBookURL: context.bookURL)
                    if isVisible(context) { presenter.showTransientMessage(L10n.BookDetail.clearCacheDone) }
                case .login:
                    let source = try await adapter.loadMenuSource(expectedBookURL: context.bookURL)
                    guard let source, source.hasManagementLoginURL,
                        isVisible(context)
                    else { return }
                    guard isVisible(context), presenter.presentedViewController == nil else { return }
                    SourceLoginEntry.open(sourceURL: source.bookSourceUrl, from: presenter)
                default: break
                }
            } catch is CancellationError {
            } catch {
                if isVisible(context) { presenter?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func isSameBook(_ context: Context) -> Bool {
        currentBook()?.bookUrl == context.bookURL && currentBook()?.origin == context.origin
    }

    private func presentVariableEditor(
        _ snapshot: BookDetailVariableSnapshot, forSource: Bool, context: Context, in presenter: UIViewController
    ) {
        let fallback =
            forSource
            ? "源变量可在js中通过source.getVariable()获取"
            : "书籍变量可在js中通过book.getVariable(\"custom\")获取"
        let comment =
            snapshot.comment.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 + "\n" + fallback
            } ?? fallback
        let editor = BookDetailVariableDialogViewController(
            title: forSource ? BookDetailOverflowAction.sourceVariable.title : BookDetailOverflowAction.bookVariable.title,
            variable: snapshot.variable, comment: comment
        ) { [self] value in
            guard isVisible(context), operationTask == nil else { throw CancellationError() }
            onBusyChange(true)
            defer { onBusyChange(false) }
            let updated = try await adapter.saveVariable(
                expectedBookURL: context.bookURL, sourceURL: context.origin, forSource: forSource, value: value)
            if let updated, isSameBook(context) { onCommitted(updated) }
        }
        editor.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        editor.canSave = { [weak self, weak editor, weak presenter] in
            guard let self, let editor, let presenter else { return false }
            return self.isVisible(context) && presenter.presentedViewController === editor
        }
        presenter.present(editor, animated: true)
    }

    private func isVisible(_ context: Context) -> Bool {
        guard isSameBook(context), let presenter, !presenter.isMovingFromParent, !presenter.isBeingDismissed,
            presenter.navigationController?.topViewController === presenter,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    private func accepts(_ context: Context) -> Bool {
        canPresent() && isVisible(context) && presenter?.presentedViewController == nil
    }
}
