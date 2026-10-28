import UIKit
import shared

@MainActor
final class MangaReaderExitFlow {
    private weak var owner: UIViewController?
    private let adapter: MangaReaderAdapter
    private let canNavigate: () -> Bool
    private let prepare: () -> Void
    private let stateDidChange: (Bool) -> Void
    private var task: Task<Void, Never>?
    private(set) var isExiting = false

    init(
        owner: UIViewController, adapter: MangaReaderAdapter,
        canNavigate: @escaping () -> Bool, prepare: @escaping () -> Void,
        stateDidChange: @escaping (Bool) -> Void
    ) {
        self.owner = owner
        self.adapter = adapter
        self.canNavigate = canNavigate
        self.prepare = prepare
        self.stateDidChange = stateDidChange
    }

    deinit { task?.cancel() }

    func begin() {
        guard !isExiting, canNavigate(), let owner, owner.presentedViewController == nil else { return }
        prepare()
        isExiting = true
        stateDidChange(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                let book = try await self.adapter.resolveForExit()
                try Task.checkCancellation()
                guard self.canNavigate() else { throw CancellationError() }
                if let book, book.isNotShelf, ReaderExitPreferences().showsAddToShelfPrompt {
                    self.presentPrompt(book)
                } else {
                    try await self.finish(book: book, addToShelf: false)
                }
            } catch {
                self.failed(error)
            }
        }
    }

    func cancelPendingWork() { task?.cancel() }

    private func presentPrompt(_ book: Book) {
        guard let owner else { failed(CancellationError()); return }
        let prompt = UIAlertController(title: "加入书架", message: "是否将《\(book.name)》放入书架？", preferredStyle: .alert)
        for (title, add) in [("加入并返回", true), ("不加入并返回", false)] {
            prompt.addAction(
                UIAlertAction(title: title, style: .default) { [weak self] _ in
                    guard let self, self.canNavigate() else { self?.failed(CancellationError()); return }
                    self.task = Task { [weak self] in
                        guard let self else { return }
                        defer { self.task = nil }
                        do { try await self.finish(book: book, addToShelf: add) } catch { self.failed(error) }
                    }
                })
        }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.failed(CancellationError()) })
        owner.present(prompt, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func finish(book: Book?, addToShelf: Bool) async throws {
        try Task.checkCancellation()
        guard canNavigate() else { throw CancellationError() }
        if let book { try await adapter.completeExit(expectedOrigin: book.origin, addToShelf: addToShelf) }
        try Task.checkCancellation()
        await adapter.finish()
        try Task.checkCancellation()
        guard canNavigate(), let owner else { throw CancellationError() }
        if let navigation = owner.navigationController, navigation.viewControllers.first !== owner {
            navigation.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            owner.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func failed(_ error: Error) {
        isExiting = false
        stateDidChange(false)
        guard !(error is CancellationError), canNavigate(), let owner, owner.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "进度尚未保存", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        owner.present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
