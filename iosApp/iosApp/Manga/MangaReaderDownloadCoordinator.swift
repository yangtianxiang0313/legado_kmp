import UIKit
import shared

@MainActor
final class MangaReaderDownloadCoordinator {
    struct Status {
        let message: String
        let isActive: Bool
        let failed: Bool
    }

    private struct Context {
        let book: Book
        let chapterIndex: Int
        let chapterCount: Int
        let isCurrent: () -> Bool
    }

    private let bookURL: String
    private let downloads = CacheDownloadCoordinator.shared
    private var observation: UUID?
    private var snapshot: CacheDownloadCoordinator.Snapshot?
    private var options: UIAlertController?
    private var optionsHeading: String?
    private var downloadActions: [UIAlertAction] = []
    private weak var stopAction: UIAlertAction?
    var onStatusChange: ((Status?) -> Void)?
    var onFeedback: ((String) -> Void)?

    init(bookURL: String) {
        self.bookURL = bookURL
    }

    deinit {
        Task { @MainActor [downloads, observation] in
            if let observation { downloads.removeObserver(observation) }
        }
    }

    func observe() {
        guard observation == nil else { return }
        observation = downloads.observe { [weak self] snapshots in
            guard let self else { return }
            let previous = self.snapshot
            self.snapshot = snapshots[self.bookURL]
            let status = self.status
            self.onStatusChange?(status)
            self.updateOptions()
            if previous?.isActive == true, let status, !status.isActive {
                self.onFeedback?(status.message)
            }
        }
    }

    func present(
        from presenter: UIViewController, chapter: MangaReaderChapter, anchor: UIView,
        isCurrent: @escaping () -> Bool
    ) {
        guard presenter.presentedViewController == nil, chapter.book.bookUrl == bookURL, isCurrent() else { return }
        guard !chapter.book.isLocal else {
            onFeedback?(L10n.Reader.downloadLocalUnavailable)
            return
        }
        let index = Int(chapter.chapterIndex)
        guard chapter.chapters.indices.contains(index) else {
            onFeedback?("当前没有可下载的章节")
            return
        }
        let context = Context(
            book: chapter.book, chapterIndex: index, chapterCount: chapter.chapters.count,
            isCurrent: isCurrent)
        let alert = UIAlertController(title: "漫画离线缓存", message: nil, preferredStyle: .actionSheet)
        alert.overrideUserInterfaceStyle = .dark
        let current = UIAlertAction(title: "缓存本章", style: .default) { [weak self, weak presenter, weak alert] _ in
            self?.afterDismissal(of: alert, from: presenter, context: context) { [weak self] _ in
                self?.start(context: context, startIndex: index, endIndex: index)
            }
        }
        let remaining = UIAlertAction(title: "缓存本章及后续", style: .default) { [weak self, weak presenter, weak alert] _ in
            self?.afterDismissal(of: alert, from: presenter, context: context) { [weak self] _ in
                self?.start(context: context, startIndex: index, endIndex: context.chapterCount - 1)
            }
        }
        let range = UIAlertAction(title: "选择章节范围…", style: .default) { [weak self, weak presenter, weak alert] _ in
            self?.afterDismissal(of: alert, from: presenter, context: context) { [weak self] presenter in
                self?.presentRange(from: presenter, context: context)
            }
        }
        let stop = UIAlertAction(title: "停止本书缓存", style: .destructive) { [weak self, weak presenter, weak alert] _ in
            self?.afterDismissal(of: alert, from: presenter, context: context) { [weak self] _ in
                guard let self, self.downloads.snapshots[self.bookURL]?.phase == .running else { return }
                self.downloads.stop(bookURL: self.bookURL)
                self.onFeedback?("正在停止本书缓存，已缓存内容将保留")
            }
        }
        for action in [current, remaining, range, stop] { alert.addAction(action) }
        alert.addAction(
            UIAlertAction(title: "返回阅读", style: .cancel) { [weak self] _ in
                self?.clearOptions()
            })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        options = alert
        optionsHeading = "\(chapter.book.name)\n当前第 \(index + 1) / \(context.chapterCount) 章"
        downloadActions = [current, remaining, range]
        stopAction = stop
        updateOptions()
        presenter.present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private var status: Status? {
        guard let snapshot else { return nil }
        let fallback: String
        switch snapshot.phase {
        case .running: fallback = snapshot.hasProgress ? "正在缓存图片" : "正在准备下载…"
        case .stopping: fallback = "正在停止下载"
        case .completed: fallback = "所选范围图片缓存完成"
        case .failed: fallback = "缓存失败"
        case .stopped: fallback = "缓存已停止，已缓存内容已保留"
        }
        var message = snapshot.message ?? fallback
        if snapshot.hasProgress {
            // CacheDownloadCoordinator reports whole-book measured counts, not this range's length.
            message += "\n全书已缓存 \(snapshot.cached) / \(snapshot.total) 章"
        }
        return Status(message: message, isActive: snapshot.isActive, failed: snapshot.phase == .failed)
    }

    private func updateOptions() {
        guard let options else { return }
        options.message = [optionsHeading, status?.message].compactMap { $0 }.joined(separator: "\n\n")
        for action in downloadActions { action.isEnabled = snapshot?.isActive != true }
        stopAction?.isEnabled = snapshot?.phase == .running
    }

    private func clearOptions() {
        options = nil
        optionsHeading = nil
        downloadActions.removeAll()
        stopAction = nil
    }

    private func afterDismissal(
        of alert: UIAlertController?, from presenter: UIViewController?, context: Context,
        perform: @escaping (UIViewController) -> Void
    ) {
        // UIKit may forward the presentation to the reader's navigation controller.
        guard let alert, let presenter, options === alert else { return }
        clearOptions()
        let finish = { [weak self, weak presenter] in
            guard let self, let presenter, self.canInteract(with: presenter, context: context) else { return }
            perform(presenter)
        }
        // UIAlertAction can run after UIKit has already detached its alert from the presenter.
        if alert.isBeingDismissed, let transition = alert.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { transition in
                if !transition.isCancelled { finish() }
            }
        } else if alert.presentingViewController != nil {
            alert.dismiss(animated: !UIAccessibility.isReduceMotionEnabled, completion: finish)
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    private func canInteract(with presenter: UIViewController, context: Context) -> Bool {
        guard context.isCurrent(), presenter.presentedViewController == nil,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            presenter.navigationController?.isBeingDismissed != true
        else { return false }
        return presenter.navigationController.map { $0.topViewController === presenter } ?? true
    }

    private func presentRange(from presenter: UIViewController, context: Context) {
        guard canInteract(with: presenter, context: context) else { return }
        let dialog = ReaderDownloadChoiceDialogViewController(
            currentChapterIndex: context.chapterIndex, chapterCount: context.chapterCount
        ) { [weak self, weak presenter] start, end in
            guard let self, let presenter, self.canInteract(with: presenter, context: context) else { return }
            self.start(context: context, startIndex: start, endIndex: end)
        }
        dialog.overrideUserInterfaceStyle = .dark
        presenter.present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func start(context: Context, startIndex: Int, endIndex: Int) {
        guard context.isCurrent(), context.book.bookUrl == bookURL,
            startIndex >= 0, startIndex <= endIndex, endIndex < context.chapterCount,
            Int32(exactly: startIndex) != nil, Int32(exactly: endIndex) != nil
        else {
            onFeedback?("章节状态已变化，请重新选择缓存范围")
            return
        }
        if downloads.start(book: context.book, startIndex: startIndex, endIndex: endIndex) {
            onFeedback?("已提交第 \(startIndex + 1) - \(endIndex + 1) 章缓存，正在准备下载")
        } else {
            onFeedback?(status?.message ?? "缓存任务未能启动，请重新打开缓存入口后重试")
        }
        // Only the shared coordinator owns the job; neither dialog dismissal nor reader exit stops it.
    }
}
