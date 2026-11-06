import Foundation
import UIKit
import shared

@MainActor
final class WebBookFileCoordinator {
    private weak var owner: UIViewController?
    private let onChange: () -> Void
    private let onImported: (BookDetailRefreshResult, Bool) -> Void
    private var facade: WebBookFileFacade?
    private var task: Task<Void, Never>?
    private var loader: WebBookFileLoader?
    private var importer: LocalBookImportCoordinator?
    private var menu: UIAlertController?
    private var busy: UIAlertController?
    private var confirmation: CheckedContinuation<Bool, Never>?
    private var generation = UUID()
    private var backgroundObserver: NSObjectProtocol?

    var isBusy: Bool { task != nil || menu != nil || importer != nil }

    init(
        owner: UIViewController, onChange: @escaping () -> Void,
        onImported: @escaping (BookDetailRefreshResult, Bool) -> Void
    ) {
        self.owner = owner
        self.onChange = onChange
        self.onImported = onImported
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancel() } }
    }

    deinit {
        task?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    func start(book: Book, openAfterImport: Bool) {
        guard !isBusy, book.isWebFile, let owner, owner.canPerformNavigationAction,
            AppLockManager.shared.isUnlocked(in: owner.view.window)
        else { return }
        let token = UUID()
        generation = token
        task = Task { @MainActor [self] in
            defer { finishTask(token) }
            do {
                let facade = try WebBookFileFacade.companion.create()
                self.facade = facade
                try showBusy(WebBookFileCopy.preparingOptions, token: token)
                let options: [WebBookFileOption] = try await SharedCancellableAsync.value { completion in
                    facade.prepareFilesRequest(bookUrl: book.bookUrl) { result in
                        if result.isCancelled {
                            completion(nil, CancellationError())
                        } else if result.errorMessage == nil {
                            completion(result.options, nil)
                        } else {
                            completion(nil, Self.failure(result.errorMessage ?? WebBookFileCopy.optionsFailed))
                        }
                    }
                }
                try Task.checkCancellation()
                try checkOwner(token)
                await closeBusy()
                try checkOwner(token)
                showOptions(options, book: book, openAfterImport: openAfterImport, token: token)
            } catch {
                await closeBusy()
                if !(error is CancellationError), isCurrent(token) {
                    showFailure(error)
                }
            }
        }
        onChange()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        loader?.cancel()
        importer?.cancel()
        finishConfirmation(false)
        busy?.message = WebBookFileCopy.cancelling
        busy?.actions.forEach { $0.isEnabled = false }
        if let menu {
            self.menu = nil
            menu.dismiss(animated: false)
        }
        onChange()
    }

    private func showOptions(_ options: [WebBookFileOption], book: Book, openAfterImport: Bool, token: UUID) {
        guard !options.isEmpty, let owner, owner.presentedViewController == nil else {
            owner?.showTransientMessage(WebBookFileCopy.noOptions)
            return
        }
        let controller = UIAlertController(title: WebBookFileCopy.optionsTitle, message: nil, preferredStyle: .actionSheet)
        controller.view.accessibilityIdentifier = "webBookFile.options"
        for option in options {
            controller.addAction(
                UIAlertAction(title: option.fileName, style: .default) { [weak self, weak controller] _ in
                    guard let self, self.isCurrent(token), let controller else { return }
                    self.download(option, book: book, openAfterImport: openAfterImport, after: controller, token: token)
                })
        }
        controller.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in
                self?.menu = nil
                self?.onChange()
            })
        controller.popoverPresentationController?.sourceView = owner.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
        menu = controller
        owner.present(controller, animated: true)
        onChange()
    }

    private func download(
        _ option: WebBookFileOption, book: Book, openAfterImport: Bool,
        after menu: UIAlertController, token: UUID
    ) {
        guard task == nil, let facade else { return }
        task = Task { @MainActor [self] in
            defer { finishTask(token) }
            await Self.dismiss(menu)
            if self.menu === menu { self.menu = nil }
            do {
                try checkOwner(token)
                if !LocalBookFormats.importExtensions.contains(option.suffix.lowercased()), option.suffix != "bin" {
                    guard await confirmDownloadOnly(option, token: token) else { throw CancellationError() }
                    try checkOwner(token)
                }
                try showBusy(option.isInlineData ? WebBookFileCopy.readingInline : WebBookFileCopy.downloading, token: token)
                let file = try await loadFile(option, book: book, facade: facade, token: token)
                try Task.checkCancellation()
                try checkOwner(token)
                await closeBusy()
                try checkOwner(token)
                if LocalBookFormats.importExtensions.contains(file.pathExtension.lowercased()) {
                    startImport(file, onlineBook: book, openAfterImport: openAfterImport, token: token)
                } else if let owner, owner.canPerformNavigationAction {
                    owner.navigationController?.pushViewController(FileDocumentViewController(url: file), animated: true)
                }
            } catch {
                await closeBusy()
                if !(error is CancellationError), isCurrent(token) {
                    showFailure(error)
                }
            }
        }
        onChange()
    }

    private func loadFile(
        _ option: WebBookFileOption, book: Book, facade: WebBookFileFacade, token: UUID
    ) async throws -> URL {
        let loader = WebBookFileLoader()
        self.loader = loader
        let progress: (Int64, Int64?) -> Void = { [weak self] received, total in
            guard let self, self.isCurrent(token) else { return }
            let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            let expected = total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            self.busy?.message = expected.map { "\(size) / \($0)" } ?? size
        }
        if option.isInlineData {
            let data: WebBookFileInlineData = try await SharedCancellableAsync.value { completion in
                facade.prepareInlineDownloadRequest(bookUrl: book.bookUrl, urlRule: option.urlRule) { result in
                    if result.isCancelled {
                        completion(nil, CancellationError())
                    } else if let data = result.data {
                        completion(data, nil)
                    } else {
                        completion(nil, Self.failure(result.errorMessage ?? WebBookFileCopy.inlinePreparationFailed))
                    }
                }
            }
            try checkOwner(token)
            return try await loader.loadInline(data, onProgress: progress)
        }
        let session = try facade.beginDownload(bookUrl: book.bookUrl, urlRule: option.urlRule)
        return try await withTaskCancellationHandler {
            do {
                let prepared = try await session.request()
                try Task.checkCancellation()
                try checkOwner(token)
                let file = try await loader.load(
                    prepared,
                    prepareRedirect: { [weak self] current, target in
                        guard let self else { throw CancellationError() }
                        try self.checkOwner(token)
                        return try await facade.prepareRedirect(request: current, targetUrl: target.absoluteString)
                    },
                    recordResponseCookies: { [weak self] current, responseURL, fields in
                        guard let self else { throw CancellationError() }
                        try self.checkOwner(token)
                        try await facade.recordResponseCookies(
                            request: current, responseUrl: responseURL.absoluteString, setCookieHeaders: fields)
                    },
                    onResponseHeaders: { session.headersReceived() },
                    onProgress: progress)
                try? await session.finish()
                return file
            } catch {
                try? await session.finish()
                throw error
            }
        } onCancel: {
            session.cancel()
        }
    }

    private func startImport(_ file: URL, onlineBook: Book, openAfterImport: Bool, token: UUID) {
        guard let owner, owner.canPerformNavigationAction else { return }
        let importer = LocalBookImportCoordinator(presenter: owner) { _ in }
        var summary: LocalBookImportSummary?
        importer.onBatchCompleted = { result in summary = result }
        importer.onFinished = { [weak self] in
            guard let self else { return }
            self.importer = nil
            self.onChange()
            guard let summary, self.isCurrent(token), self.owner?.canPerformNavigationAction == true else { return }
            if summary.isCancelled || summary.books.count != 1 || !summary.failures.isEmpty {
                if let owner = self.owner { LocalBookImportResultViewController(summary: summary).present(from: owner) }
                return
            }
            self.prepareImportedBook(summary.books[0], onlineBook: onlineBook, openAfterImport: openAfterImport, token: token)
        }
        self.importer = importer
        importer.start(url: file, groupID: onlineBook.group)
        onChange()
    }

    private func prepareImportedBook(_ book: Book, onlineBook: Book, openAfterImport: Bool, token: UUID) {
        task = Task { @MainActor [self] in
            defer { finishTask(token) }
            var merged = false
            do {
                try checkOwner(token)
                try showBusy(WebBookFileCopy.preparingReading, token: token)
                let imported = try await WebBookFileImportFacade.companion.create().mergeImportedBook(
                    expectedOnlineBook: onlineBook, expectedLocalBook: book)
                merged = true
                try checkOwner(token)
                let result = try await SharedRuntime.bookDetailFacade().get().preloadChapters(bookUrl: imported.bookUrl)
                try Task.checkCancellation()
                await closeBusy()
                try checkOwner(token)
                task = nil
                onChange()
                onImported(result, openAfterImport)
            } catch {
                await closeBusy()
                if !(error is CancellationError), isCurrent(token), let owner {
                    owner.showTransientMessage(
                        WebBookFileCopy.importedFailure(merged: merged, message: WebBookFileErrorCopy.message(error)))
                }
            }
        }
        onChange()
    }

    private func showBusy(_ title: String, token: UUID) throws {
        try checkOwner(token)
        guard let owner, owner.presentedViewController == nil else { throw CancellationError() }
        let alert = UIAlertController(title: title, message: WebBookFileCopy.preparing, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "webBookFile.progress"
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.cancel() })
        busy = alert
        owner.present(alert, animated: true)
    }

    private func showFailure(_ error: Error) {
        guard let owner, owner.canPerformNavigationAction else { return }
        owner.showTransientMessage(WebBookFileErrorCopy.message(error), duration: 3.5)
    }

    private func confirmDownloadOnly(_ option: WebBookFileOption, token: UUID) async -> Bool {
        let alert = UIAlertController(
            title: WebBookFileCopy.downloadOnlyTitle,
            message: WebBookFileCopy.unsupportedFile(option.fileName), preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "webBookFile.downloadOnly"
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.finishConfirmation(false) })
        alert.addAction(UIAlertAction(title: WebBookFileCopy.download, style: .default) { [weak self] _ in self?.finishConfirmation(true) })
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrent(token), let owner, owner.presentedViewController == nil else {
                    continuation.resume(returning: false)
                    return
                }
                confirmation = continuation
                menu = alert
                owner.present(alert, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishConfirmation(false) }
        }
        await Self.dismiss(alert)
        if menu === alert { menu = nil }
        return accepted
    }

    private func finishConfirmation(_ accepted: Bool) {
        let continuation = confirmation
        confirmation = nil
        continuation?.resume(returning: accepted)
    }

    private func finishTask(_ token: UUID) {
        task = nil
        loader = nil
        onChange()
    }

    private func closeBusy() async {
        guard let busy else { return }
        await Self.dismiss(busy)
        if self.busy === busy { self.busy = nil }
    }

    private func checkOwner(_ token: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        guard generation == token, let owner, owner.isVisibleInNavigationStack,
            !owner.isBeingDismissed, !owner.isMovingFromParent,
            UIApplication.shared.applicationState == .active,
            let window = owner.viewIfLoaded?.window, window.isKeyWindow,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    private static func dismiss(_ controller: UIViewController) async {
        while controller.isBeingPresented || controller.isBeingDismissed {
            guard let transition = controller.transitionCoordinator else { break }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
        }
        if controller.presentingViewController != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web-book-file", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum WebBookFileCopy {
    static let preparingOptions = L10n.text("web_file.consumer.preparing_options", "正在读取下载文件")
    static let optionsFailed = L10n.text("web_file.consumer.options_failed", "无法读取下载文件")
    static let cancelling = L10n.text("web_file.consumer.cancelling", "正在取消，已完成的文件会保留")
    static let noOptions = L10n.text("web_file.consumer.no_options", "书源没有可下载的文件")
    static let optionsTitle = L10n.text("web_file.consumer.options_title", "下载并导入文件")
    static let readingInline = L10n.text("web_file.consumer.reading_inline", "正在读取内嵌书籍")
    static let downloading = L10n.text("web_file.consumer.downloading", "正在下载书籍")
    static let inlinePreparationFailed = L10n.text("web_file.consumer.inline_preparation_failed", "内嵌文件准备失败")
    static let preparingReading = L10n.text("web_file.consumer.preparing_reading", "正在准备阅读")
    static let preparing = L10n.text("web_file.consumer.preparing", "正在准备…")
    static let downloadFailed = L10n.text("web_file.consumer.download_failed", "文件下载失败")
    static let downloadOnlyTitle = L10n.text("web_file.consumer.download_only_title", "下载文件")
    static let download = L10n.text("web_file.consumer.download", "下载")

    static func unsupportedFile(_ fileName: String) -> String {
        L10n.format("web_file.consumer.unsupported_file", "此应用不支持直接阅读文件 %@，可下载后交给其他应用打开。", fileName)
    }

    static func importedFailure(merged: Bool, message: String) -> String {
        if merged {
            return L10n.format(
                "web_file.consumer.imported_reading_failed", "文件已导入，可从书架重试阅读：%@", message)
        }
        return L10n.format(
            "web_file.consumer.imported_merge_failed", "文件已导入，但在线信息合并失败，可从书架打开：%@", message)
    }
}
