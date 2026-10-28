import UIKit

enum ExternalOpenRoute: Equatable {
    case file(URL)
    case bookSource(URL)
    case rules(URL, ExternalRuleImportKind?)
    case readerConfig(URL)
    case bookLink(String)

    static func parse(_ url: URL) throws -> ExternalOpenRoute {
        guard url.absoluteString.utf8.count <= 32 * 1024 else { throw error("导入地址过长") }
        if url.isFileURL {
            guard LocalBookFormats.importExtensions.union(["json"]).contains(url.pathExtension.lowercased()) else {
                throw error("不支持的文件类型")
            }
            return .file(url)
        }
        guard ["legado", "yuedu"].contains(url.scheme?.lowercased() ?? ""),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil, components.password == nil,
            let query = components.queryItems?.filter({ $0.name == "src" }), query.count == 1,
            let source = query.first?.value
        else { throw error("无法处理此导入链接") }
        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        if (host == "import" && path == "/addtobookshelf") || (host == "addtobookshelf" && path == "/importonline") {
            guard ExternalBookLinkCoordinator.accepts(source) else { throw error("书籍地址或书源选项无效") }
            return .bookLink(source)
        }
        guard let address = URL(string: source), ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
            let addressHost = address.host, !addressHost.isEmpty, address.user == nil, address.password == nil
        else { throw error("导入地址必须是 HTTP 或 HTTPS 地址") }
        if (host == "import" && path == "/readconfig") || (host == "readconfig" && path == "/importonline") {
            return .readerConfig(address)
        }
        let kind: ExternalRuleImportKind?
        if path == "/importonline" {
            // Legacy unknown hosts delegate to content detection, as Android does.
            kind = ExternalRuleImportKind(route: host)
        } else if host == "import", path == "/" || path.isEmpty {
            kind = nil
        } else if host == "import", path.hasPrefix("/"),
            let routedKind = ExternalRuleImportKind(route: String(path.dropFirst()))
        {
            kind = routedKind
        } else {
            throw error("不支持此导入类型")
        }
        return kind == .bookSource ? .bookSource(address) : .rules(address, kind)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "io.legado.externalOpen", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Incoming requests wait for both startup and app-lock dismissal. Import always needs confirmation.
@MainActor
final class ExternalDocumentCoordinator {
    private final class Request {
        let key: URL
        let url: URL
        let lease: SandboxFileReadLease?
        weak var navigation: UINavigationController?
        var started = false
        var copyResult: Result<URL, Error>?

        init(_ url: URL) {
            self.url = url
            key = url.isFileURL ? url.standardizedFileURL : url
            lease = url.isFileURL ? SandboxFileReadLease(url) : nil
        }
    }

    private enum ProcessingStep {
        case stop
        case wait
        case completed
        case copy(Request, SandboxFileReadLease)
    }

    private weak var window: UIWindow?
    private var isUnlocked = false
    private var pending: [Request] = []
    private var retiringReads: [SandboxFileReadLease] = []
    private var processing: Task<Void, Never>?
    private var processingID: UUID?
    private var generation = UUID()
    private var isDisconnected = false
    private var activeURL: URL?
    private var ruleImport: ExternalRuleImportCoordinator?
    private var readerConfigImport: ExternalReaderConfigImportCoordinator?
    private var bookLink: ExternalBookLinkCoordinator?

    deinit {
        processing?.cancel()
        pending.forEach { $0.lease?.cancel() }
        retiringReads.forEach { $0.cancel() }
    }

    private var isPreparing: Bool {
        ruleImport?.isPreparing == true || readerConfigImport?.isPreparing == true || bookLink?.isPreparing == true
    }

    func attach(window: UIWindow) {
        guard self.window !== window || isDisconnected else { return }
        disconnect()
        self.window = window
        isDisconnected = false
    }

    func receive(_ urls: [URL]) {
        guard !isDisconnected, window != nil else { return }
        retiringReads.removeAll { !$0.isReading }
        if processing == nil, !isPreparing,
            let navigation = window?.rootViewController as? UINavigationController,
            navigation.presentedViewController == nil, navigation.topViewController?.presentedViewController == nil
        {
            activeURL = nil
        }
        for url in urls {
            let key = url.isFileURL ? url.standardizedFileURL : url
            guard key != activeURL, !pending.contains(where: { $0.key == key }),
                !retiringReads.contains(where: { $0.source.standardizedFileURL == key })
            else { continue }
            // The active request stays in pending; cancelled reads still occupy a slot until they exit.
            guard pending.count + retiringReads.count < 8 else { break }
            pending.append(Request(url))
        }
        resume()
    }

    func appDidUnlock() { isUnlocked = true; resume() }
    func disconnect() {
        isDisconnected = true
        isUnlocked = false
        generation = UUID()
        processingID = nil
        processing?.cancel()
        processing = nil
        for request in pending {
            request.lease?.cancel()
            if let lease = request.lease, lease.isReading { retiringReads.append(lease) }
        }
        pending.removeAll()
        retiringReads.removeAll { !$0.isReading }
        ruleImport?.cancel()
        ruleImport = nil
        readerConfigImport?.cancel()
        readerConfigImport = nil
        bookLink?.cancel()
        bookLink = nil
        activeURL = nil
        window = nil
    }

    func resume() {
        guard processing == nil, !pending.isEmpty, !isDisconnected,
            let window, let scene = window.windowScene, contentIsUnlocked(in: window)
        else { return }
        let id = UUID()
        let expectedGeneration = generation
        processingID = id
        processing = Task { [weak self, weak window, weak scene] in
            defer { self?.processingDidFinish(id: id, generation: expectedGeneration) }
            while !Task.isCancelled {
                let step = self?.nextStep(id: id, generation: expectedGeneration, window: window, scene: scene) ?? .stop
                do {
                    switch step {
                    case .stop:
                        return
                    case .wait:
                        try await Task.sleep(nanoseconds: 200_000_000)
                    case .completed:
                        try await Task.sleep(nanoseconds: 300_000_000)
                    case .copy(let request, let lease):
                        let result: Result<URL, Error>
                        do {
                            let store = SandboxFileStore.shared
                            let file = try await withTaskCancellationHandler {
                                try await store.importFile(lease, into: store.root, uniquing: true)
                            } onCancel: {
                                lease.cancel()
                            }
                            result = .success(file)
                        } catch {
                            result = .failure(error)
                        }
                        self?.didCopy(
                            result, request: request, id: id, generation: expectedGeneration,
                            window: window, scene: scene)
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func contentIsUnlocked(in window: UIWindow) -> Bool {
        isUnlocked && UIApplication.shared.applicationState == .active
            && window.windowScene?.activationState == .foregroundActive
            && AppLockManager.shared.isUnlocked(in: window)
    }

    private func ownsProcessing(id: UUID, generation: UUID, window: UIWindow?, scene: UIWindowScene?) -> Bool {
        guard let window, let scene else { return false }
        return !isDisconnected && !Task.isCancelled && self.generation == generation && processingID == id
            && self.window === window && window.windowScene === scene
    }

    private func processingDidFinish(id: UUID, generation: UUID) {
        guard self.generation == generation, processingID == id else { return }
        processingID = nil
        processing = nil
    }

    private func nextStep(id: UUID, generation: UUID, window: UIWindow?, scene: UIWindowScene?) -> ProcessingStep {
        guard ownsProcessing(id: id, generation: generation, window: window, scene: scene),
            let window, let request = pending.first
        else { return .stop }
        if request.started, request.navigation !== window.rootViewController {
            finish(request)
            return .completed
        }
        guard contentIsUnlocked(in: window) else { return .stop }
        guard !isPreparing,
            let navigation = window.rootViewController as? UINavigationController,
            let top = navigation.topViewController, top.viewIfLoaded?.window === window,
            top.canPerformNavigationAction, navigation.presentedViewController == nil, top.presentedViewController == nil
        else { return .wait }
        activeURL = request.key
        do {
            switch try ExternalOpenRoute.parse(request.url) {
            case .file:
                if let result = request.copyResult {
                    let file = try result.get()
                    navigation.pushViewController(FileDocumentViewController(url: file), animated: true)
                } else if let lease = request.lease {
                    request.navigation = navigation
                    request.started = true
                    return .copy(request, lease)
                }
            case .bookSource(let address):
                // Explicit book-source links keep the full shared URL/import grammar.
                let screen = SourceImportScreenAdapter()
                try screen.bootstrap().get()
                let preview = SourceImportPreviewViewController {
                    try await screen.preparePreview(source: .url(address.absoluteString))
                }
                preview.onConfirm = { sources, options in
                    _ = try await screen.importSelected(sources: sources, options: options)
                }
                top.present(preview, animated: true)
            case .rules(let address, let kind):
                openRules(address, kind: kind, owner: top)
            case .readerConfig(let address):
                let coordinator = ExternalReaderConfigImportCoordinator(owner: top)
                coordinator.onImported = { [weak top] in top?.showTransientMessage("阅读配置导入完成") }
                readerConfigImport = coordinator
                coordinator.start(input: .remote(address))
            case .bookLink(let address):
                let coordinator = ExternalBookLinkCoordinator(owner: top)
                bookLink = coordinator
                coordinator.start(address: address)
            }
        } catch is CancellationError {
        } catch {
            top.showTransientMessage(error.userFacingMessage)
        }
        finish(request)
        return .completed
    }

    private func didCopy(
        _ result: Result<URL, Error>, request: Request, id: UUID, generation: UUID,
        window: UIWindow?, scene: UIWindowScene?
    ) {
        guard ownsProcessing(id: id, generation: generation, window: window, scene: scene),
            pending.first === request
        else { return }
        // Retain the committed path across lock/background; never read the provider again to present it.
        request.copyResult = result
    }

    private func finish(_ request: Request) {
        guard pending.first === request else { return }
        request.lease?.cancel()
        pending.removeFirst()
    }

    private func openRules(_ address: URL, kind: ExternalRuleImportKind?, owner: UIViewController) {
        let coordinator = ExternalRuleImportCoordinator(owner: owner)
        coordinator.onImported = { [weak owner] in owner?.showTransientMessage("规则导入完成") }
        ruleImport = coordinator
        coordinator.start(input: .remote(address), expected: kind)
    }
}
