import Foundation
import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class BookshelfTransferCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private enum InputKind {
        case addURL
        case importBookshelf
    }

    private struct Counts {
        var added = 0
        var updated = 0
        var skipped = 0
        var failed = 0

        var message: String {
            let updates = updated > 0 ? "，更新 \(updated)" : ""
            return "新增 \(added)\(updates)，跳过 \(skipped)，失败 \(failed)"
        }
    }

    private weak var presenter: AndroidReplicaBookshelfViewController?
    private let screen: BookshelfScreenAdapter
    private var task: Task<Void, Never>?
    private var isBusy = false
    private var allowsPresentation = false
    private var stopAfterCurrentURL = false
    private var inputID: UUID?
    private var addDraft = ""
    private var importDraft = ""
    private var picker: UIDocumentPickerViewController?
    private var pickerGroupID: Int64 = 0
    private var pickerHandled = false
    private var progress: BookshelfTransferProgressViewController?
    private var activity: UIActivityViewController?
    private var shareFile: BookshelfTransferTemporaryFile?
    private var shareHandled = false
    private var visibilityObserver: BookshelfTransferVisibilityObserver?
    private var isPresentingProgress = false

    init(presenter: AndroidReplicaBookshelfViewController, screen: BookshelfScreenAdapter) {
        self.presenter = presenter
        self.screen = screen
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneEnteredBackground(_:)),
            name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    func addURLs() { presentInput(.addURL) }

    func importBookshelf() { presentInput(.importBookshelf) }

    func exportBookshelf() {
        guard canBegin, let books = presenter?.books else { return }
        reserveOperation()
        // These suspend APIs have no Kotlin cancellation handle. Retain this operation until it really finishes.
        task = Task { @MainActor [self] in
            defer { task = nil }
            guard await showProgress("导出中...") else {
                await finish(message: nil)
                return
            }
            var prepared: BookshelfTransferTemporaryFile?
            do {
                let facade = try SharedRuntime.bookshelfFacade().get()
                let payload = try await facade.exportBookListAsync(books: books)
                let file = try await BookshelfTransferFiles.makeExport(payload)
                prepared = file
                await dismissProgress()
                guard allowsPresentation, canPresent, let presenter else {
                    await BookshelfTransferFiles.remove(file)
                    releaseOperation()
                    return
                }
                let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
                controller.popoverPresentationController?.sourceView = presenter.bookshelfMoreAnchor
                controller.popoverPresentationController?.sourceRect = presenter.bookshelfMoreAnchor.bounds
                shareFile = file
                activity = controller
                shareHandled = false
                controller.completionWithItemsHandler = { [weak self, weak controller] _, completed, _, error in
                    Task { @MainActor [weak self] in
                        guard let self, let controller else {
                            await BookshelfTransferFiles.remove(file)
                            return
                        }
                        self.finishSharing(controller, completed: completed, error: error)
                    }
                }
                presenter.present(controller, animated: true)
                controller.presentationController?.delegate = self
            } catch {
                if let prepared { await BookshelfTransferFiles.remove(prepared) }
                await finish(message: error.localizedDescription)
            }
        }
    }

    private var canPresent: Bool {
        guard let presenter, presenter.isVisibleInNavigationStack,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            presenter.presentedViewController == nil,
            presenter.navigationController?.transitionCoordinator == nil
        else { return false }
        return true
    }

    private var canBegin: Bool { !isBusy && task == nil && canPresent }

    private func reserveOperation() {
        isBusy = true
        allowsPresentation = true
        stopAfterCurrentURL = false
        guard visibilityObserver == nil, let presenter else { return }
        let observer = BookshelfTransferVisibilityObserver()
        observer.onDisappear = { [weak self] in
            guard let self, !self.isPresentingProgress,
                self.progress != nil, self.progress?.expectsDismissal == false
            else { return }
            self.suppressPresentation()
        }
        visibilityObserver = observer
        presenter.addChild(observer)
        observer.view.isUserInteractionEnabled = false
        observer.view.accessibilityElementsHidden = true
        observer.view.frame = .zero
        presenter.view.addSubview(observer.view)
        observer.didMove(toParent: presenter)
    }

    private func releaseOperation() {
        isBusy = false
        guard let observer = visibilityObserver else { return }
        visibilityObserver = nil
        observer.onDisappear = nil
        observer.willMove(toParent: nil)
        observer.view.removeFromSuperview()
        observer.removeFromParent()
    }

    @objc private func sceneEnteredBackground(_ notification: Notification) {
        guard isBusy, let scene = notification.object as? UIScene,
            presenter?.viewIfLoaded?.window?.windowScene === scene
        else { return }
        suppressPresentation()
    }

    private func suppressPresentation() {
        allowsPresentation = false
        stopAfterCurrentURL = true
    }

    private func presentInput(_ kind: InputKind) {
        guard canBegin, let presenter else { return }
        let groupID = kind == .importBookshelf ? max(0, screen.currentSelectedGroupId) : 0
        let id = UUID()
        inputID = id
        let controller: BookshelfTransferInputViewController
        switch kind {
        case .addURL:
            controller = BookshelfTransferInputViewController(mode: .addURL, initialText: addDraft)
        case .importBookshelf:
            controller = BookshelfTransferInputViewController(mode: .importBookshelf, initialText: importDraft)
            controller.onSelectFile = { [weak self] in
                guard let self, self.consumeInput(id) else { return }
                self.selectFile(groupID: groupID)
            }
        }
        controller.onSubmit = { [weak self] text in
            guard let self, self.consumeInput(id) else { return }
            switch kind {
            case .addURL:
                self.addDraft = text
                self.startAdding(text, groupID: groupID)
            case .importBookshelf:
                self.importDraft = text
                self.startImporting(text, groupID: groupID)
            }
        }
        presenter.present(controller, animated: true)
    }

    private func consumeInput(_ id: UUID) -> Bool {
        guard inputID == id, canBegin else { return false }
        inputID = nil
        return true
    }

    private func startAdding(_ text: String, groupID: Int64) {
        guard canBegin else { return }
        let urls = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !urls.isEmpty else {
            presenter?.showMessage("Book URL is empty")
            return
        }
        reserveOperation()
        task = Task { @MainActor [self] in
            defer { task = nil }
            guard await showProgress("添加中...", canStopBetweenURLs: true) else {
                await finish(message: nil)
                return
            }
            var counts = Counts()
            var firstError: String?
            var retryURLs: [String] = []
            var attemptedWrite = false
            var processed = 0
            do {
                let facade = try SharedRuntime.bookshelfFacade().get()
                var knownBooks = try await facade.loadBooksAsync(groupId: BookshelfScreenAdapter.allGroupId)
                var knownURLs = Set(knownBooks.map(\.bookUrl))
                var submittedURLs: Set<String> = []
                for (index, url) in urls.enumerated() {
                    guard !stopAfterCurrentURL, isPresenterAttached else {
                        retryURLs.append(contentsOf: urls[index...])
                        break
                    }
                    progress?.setStatus("添加中... (\(index + 1)/\(urls.count))")
                    processed += 1
                    if !submittedURLs.insert(url).inserted || knownURLs.contains(url) {
                        counts.skipped += 1
                        continue
                    }
                    do {
                        attemptedWrite = true
                        let book = try await facade.addBookByUrlAsync(bookUrl: url, groupId: groupID)
                        let previous = knownBooks.firstIndex { existing in
                            existing.bookUrl == book.bookUrl || Self.sameIdentity(existing, book)
                        }
                        if book.isNotShelf {
                            counts.skipped += 1
                        } else if let previous {
                            counts.updated += 1
                            knownURLs.remove(knownBooks[previous].bookUrl)
                            knownBooks[previous] = book
                        } else {
                            counts.added += 1
                            knownBooks.append(book)
                        }
                        knownURLs.insert(url)
                        knownURLs.insert(book.bookUrl)
                    } catch {
                        counts.failed += 1
                        retryURLs.append(url)
                        firstError = firstError ?? error.localizedDescription
                        SharedRuntime.log("添加网址失败：\(url)\n\(error.localizedDescription)")
                    }
                }
                addDraft = retryURLs.joined(separator: "\n")
                var message = counts.message
                if processed < urls.count { message += "，未处理 \(urls.count - processed)" }
                if let firstError { message += "\n\(firstError)" }
                await finish(message: message, refreshBooks: attemptedWrite)
            } catch {
                await finish(message: error.localizedDescription, refreshBooks: attemptedWrite)
            }
        }
    }

    private static func sameIdentity(_ left: Book, _ right: Book) -> Bool {
        let name = left.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name == right.name.trimmingCharacters(in: .whitespacesAndNewlines)
            && left.author.trimmingCharacters(in: .whitespacesAndNewlines)
                == right.author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startImporting(_ text: String, groupID: Int64) {
        guard canBegin else { return }
        reserveOperation()
        task = Task { @MainActor [self] in
            defer { task = nil }
            guard await showProgress("导入中... 请等待本次操作结束") else {
                await finish(message: nil)
                return
            }
            await performImport(text, groupID: groupID)
        }
    }

    private func performImport(_ text: String, groupID: Int64, file: BookshelfTransferTemporaryFile? = nil) async {
        var attemptedWrite = false
        do {
            let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let facade = try SharedRuntime.bookshelfFacade().get()
            let result: BookshelfImportResult
            attemptedWrite = true
            if Self.isHTTPURL(payload) {
                result = try await facade.importBookshelfFromUrlAsync(url: payload, groupId: groupID)
            } else if let file {
                result = try await facade.importBookshelfFileAsync(path: file.url.path, groupId: groupID)
            } else {
                // Let the real parser report malformed/empty JSON, including its original error.
                result = try await facade.importBookshelfAsync(payload: payload, groupId: groupID)
            }
            if let file { await BookshelfTransferFiles.remove(file) }
            importDraft = result.failedCount > 0 ? text : ""
            let counts = Counts(added: Int(result.addedCount), skipped: Int(result.skippedCount), failed: Int(result.failedCount))
            await finish(message: counts.message, refreshBooks: true)
        } catch {
            if let file { await BookshelfTransferFiles.remove(file) }
            await finish(message: error.localizedDescription, refreshBooks: attemptedWrite)
        }
    }

    private static func isHTTPURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    private func selectFile(groupID: Int64) {
        guard canBegin, let presenter else { return }
        reserveOperation()
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .json], asCopy: true)
        controller.allowsMultipleSelection = false
        controller.delegate = self
        picker = controller
        pickerGroupID = groupID
        pickerHandled = false
        presenter.present(controller, animated: true)
        controller.presentationController?.delegate = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicking(controller, url: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicking(controller, url: nil)
    }

    private func finishPicking(_ controller: UIDocumentPickerViewController, url: URL?) {
        guard picker === controller, !pickerHandled, task == nil else { return }
        pickerHandled = true
        let groupID = pickerGroupID
        task = Task { @MainActor [self] in
            defer { task = nil }
            await Self.dismiss(controller)
            picker = nil
            guard let url, allowsPresentation, canPresent else {
                releaseOperation()
                return
            }
            guard await showProgress("正在读取文件...") else {
                await finish(message: nil)
                return
            }
            var prepared: BookshelfTransferTemporaryFile?
            do {
                let file = try await BookshelfTransferFiles.copyImport(url)
                prepared = file
                let text = try await BookshelfTransferFiles.read(file)
                importDraft = text
                guard allowsPresentation, isPresenterAttached else {
                    await BookshelfTransferFiles.remove(file)
                    await finish(message: nil)
                    return
                }
                progress?.setStatus("导入中... 请等待本次操作结束")
                // Reuse the already-presented wait dialog rather than presenting during its transition.
                await performImport(text, groupID: groupID, file: file)
            } catch {
                if let prepared { await BookshelfTransferFiles.remove(prepared) }
                await finish(message: error.localizedDescription)
            }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let picker, presentationController.presentedViewController === picker {
            finishPicking(picker, url: nil)
        } else if let activity, presentationController.presentedViewController === activity {
            finishSharing(activity, completed: false, error: nil)
        }
    }

    private func finishSharing(_ controller: UIActivityViewController, completed: Bool, error: Error?) {
        guard activity === controller, !shareHandled, task == nil else { return }
        shareHandled = true
        let file = shareFile
        task = Task { @MainActor [self] in
            defer { task = nil }
            await Self.dismiss(controller)
            if let file { await BookshelfTransferFiles.remove(file) }
            activity = nil
            shareFile = nil
            releaseOperation()
            guard allowsPresentation, canPresent else { return }
            if let error {
                presenter?.showMessage(error.localizedDescription)
            } else if completed {
                presenter?.showMessage("导出成功")
            }
        }
    }

    private var isPresenterAttached: Bool {
        guard let presenter, presenter.isVisibleInNavigationStack,
            !presenter.isBeingDismissed, !presenter.isMovingFromParent
        else {
            suppressPresentation()
            return false
        }
        return true
    }

    private func showProgress(_ text: String, canStopBetweenURLs: Bool = false) async -> Bool {
        guard allowsPresentation, canPresent, let presenter else { return false }
        let controller = BookshelfTransferProgressViewController(status: text, canStopBetweenURLs: canStopBetweenURLs)
        controller.onStop = { [weak self] in self?.stopAfterCurrentURL = true }
        controller.onUnexpectedDismiss = { [weak self] in
            self?.suppressPresentation()
        }
        progress = controller
        isPresentingProgress = true
        await withCheckedContinuation { continuation in
            presenter.present(controller, animated: true) { continuation.resume() }
        }
        isPresentingProgress = false
        return allowsPresentation && isPresenterAttached
    }

    private func finish(message: String?, refreshBooks: Bool = false) async {
        var message = message
        if refreshBooks {
            let groupID = screen.currentSelectedGroupId
            do {
                let books = try await screen.loadBooks(groupId: groupID)
                if screen.currentSelectedGroupId == groupID, let presenter {
                    presenter.books = books
                    presenter.updateEmptyState()
                }
            } catch {
                message = [message, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            }
            presenter?.reloadGroupPages()
        }
        await dismissProgress()
        releaseOperation()
        guard allowsPresentation, canPresent, let message else { return }
        presenter?.showMessage(message)
    }

    private func dismissProgress() async {
        guard let controller = progress else { return }
        controller.expectsDismissal = true
        await Self.dismiss(controller)
        if progress === controller { progress = nil }
    }

    private static func dismiss(_ controller: UIViewController) async {
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let registered = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                if !registered { continuation.resume() }
            }
        } else if controller.presentingViewController != nil {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class BookshelfTransferVisibilityObserver: UIViewController {
    var onDisappear: (() -> Void)?

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDisappear?()
    }
}

private final class BookshelfTransferTemporaryFile: Sendable {
    let id: UUID
    let directory: URL
    let url: URL

    init(id: UUID, directory: URL, url: URL) {
        self.id = id
        self.directory = directory
        self.url = url
    }

    deinit { BookshelfTransferFiles.removeSynchronously(self) }
}

private enum BookshelfTransferFiles {
    private static let queue = DispatchQueue(label: "io.legado.bookshelf-transfer-files", qos: .userInitiated)
    private static let maximumImportBytes = 8 * 1024 * 1024

    static func copyImport(_ source: URL) async throws -> BookshelfTransferTemporaryFile {
        try await perform {
            guard source.isFileURL, ["txt", "json"].contains(source.pathExtension.lowercased()) else {
                throw fileError("请选择 TXT 或 JSON 文件")
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let file = try makeTemporaryFile(name: "bookshelf.\(source.pathExtension.lowercased())")
            do {
                var coordinationError: NSError?
                var result: Result<Void, Error>?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    readingItemAt: source, options: .withoutChanges, error: &coordinationError
                ) { readable in
                    result = Result { try copyBounded(from: readable, to: file.url) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw fileError("无法读取文件") }
                try result.get()
                return file
            } catch {
                removeSynchronously(file)
                throw error
            }
        }
    }

    static func read(_ file: BookshelfTransferTemporaryFile) async throws -> String {
        try await perform {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumImportBytes) else {
                throw fileError("书单文件超过 8 MiB")
            }
            return try String(contentsOf: file.url, encoding: .utf8)
        }
    }

    static func makeExport(_ payload: String) async throws -> BookshelfTransferTemporaryFile {
        try await perform {
            let file = try makeTemporaryFile(name: "bookshelf.json")
            do {
                try Data(payload.utf8).write(to: file.url, options: .atomic)
                return file
            } catch {
                removeSynchronously(file)
                throw error
            }
        }
    }

    static func remove(_ file: BookshelfTransferTemporaryFile) async {
        await withCheckedContinuation { continuation in
            queue.async {
                removeSynchronously(file)
                continuation.resume()
            }
        }
    }

    private static func makeTemporaryFile(name: String) throws -> BookshelfTransferTemporaryFile {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookshelfTransfer-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return BookshelfTransferTemporaryFile(id: id, directory: directory, url: directory.appendingPathComponent(name))
    }

    private static func copyBounded(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw fileError("请选择有效的常规文件")
        }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumImportBytes) else {
            throw fileError("书单文件超过 8 MiB")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard manager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw fileError("无法创建书单副本")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maximumImportBytes - copied else { throw fileError("书单文件超过 8 MiB") }
            copied += chunk.count
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    fileprivate static func removeSynchronously(_ file: BookshelfTransferTemporaryFile) {
        let directory = file.directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL,
            directory.lastPathComponent == "BookshelfTransfer-\(file.id.uuidString)",
            file.url.deletingLastPathComponent().standardizedFileURL == directory
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func fileError(_ message: String) -> NSError {
        NSError(domain: "io.legado.kmp.bookshelf-transfer", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}
