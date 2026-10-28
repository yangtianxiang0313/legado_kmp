import Foundation
import UIKit
import shared

enum ExternalRuleImportLoader {
    static let maximumBytes = 32 * 1024 * 1024

    static func load(_ input: ExternalRuleImportInput, limit: Int = 32 * 1024 * 1024) async throws -> Data {
        guard (1...ReaderPresetTransferResources.archiveLimit).contains(limit) else {
            throw ExternalRuleImportDocument.failure("导入文件大小限制无效")
        }
        let sizeError = "导入文件超过 \(limit / 1024 / 1024) MB"
        switch input {
        case .file(let url):
            let read = Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                var result = Data()
                while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    guard result.count <= limit - chunk.count else {
                        throw ExternalRuleImportDocument.failure(sizeError)
                    }
                    result.append(chunk)
                }
                return result
            }
            return try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
        case .remote(let address):
            guard let parts = URLComponents(url: address, resolvingAgainstBaseURL: false),
                ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
            else { throw ExternalRuleImportDocument.failure("导入地址必须是 HTTP 或 HTTPS 地址") }
            var components = parts
            let withoutUserAgent = components.fragment == "requestWithoutUA"
            components.fragment = nil
            guard let url = components.url else { throw ExternalRuleImportDocument.failure("导入地址无效") }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            if withoutUserAgent { request.setValue("null", forHTTPHeaderField: "User-Agent") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw ExternalRuleImportDocument.failure("规则下载失败：HTTP \(status)")
                }
                guard response.expectedContentLength <= Int64(limit) else {
                    throw ExternalRuleImportDocument.failure(sizeError)
                }
                var result = Data()
                result.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(limit)))))
                for try await byte in bytes {
                    guard result.count < limit else { throw ExternalRuleImportDocument.failure(sizeError) }
                    result.append(byte)
                    if result.count % (64 * 1024) == 0 { try Task.checkCancellation() }
                }
                try Task.checkCancellation()
                return result
            } catch is CancellationError { throw CancellationError() } catch let error as NSError {
                if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { throw CancellationError() }
                if error.domain == "io.legado.externalRuleImport" { throw error }
                // Transport descriptions may contain source URLs or embedded credentials.
                throw ExternalRuleImportDocument.failure("规则下载失败，请检查网络后重试")
            }
        }
    }
}

@MainActor
final class ExternalRuleImportAdapter {
    private var rss: RssFacade?
    private var replacements: ReplaceRuleFacade?
    private var speech: BackupCapabilitiesFacade?
    private var settings: SettingsFacade?

    func save(_ row: ExternalRuleImportRow) async throws {
        try Task.checkCancellation()
        switch row.value {
        case .rss(let payload):
            let facade = try rss ?? SharedRuntime.rssFacade().get()
            rss = facade
            let object = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            let data = try JSONSerialization.data(withJSONObject: [object])
            let count = try await facade.importRssSourcesAsync(payload: String(decoding: data, as: UTF8.self))
            guard count == 1 else { throw ExternalRuleImportDocument.failure("RSS 源未通过有效性检查") }
        case .replace(let rule):
            let facade = try replacements ?? SharedRuntime.replaceRuleFacade().get()
            replacements = facade
            try await facade.saveRulesAsync(rules: [rule])
        case .speech(let engine):
            let facade = try speech ?? BootstrapApiKt.sharedBackupCapabilitiesFacade()
            speech = facade
            let _: HttpTTS = try await SharedAsync.value {
                facade.importSpeechEngine(engine: engine, completionHandler: $0)
            }
        case .theme(let payload):
            let facade = try settings ?? SharedRuntime.settingsFacade().get()
            settings = facade
            try await SharedAsync.void { facade.themeSettings.importPreset(json: payload, completionHandler: $0) }
        case .txtToc(let rule):
            let facade = try settings ?? SharedRuntime.settingsFacade().get()
            settings = facade
            let _: TxtTocRule = try await SharedAsync.value { facade.importTxtTocRule(rule: rule, completionHandler: $0) }
        case .dictionary(let rule):
            let facade = try settings ?? SharedRuntime.settingsFacade().get()
            settings = facade
            _ = try await facade.saveDictRuleAsync(rule: rule)
        }
    }
}

/// Owns preparation only. No persistence is called until a preview's explicit confirmation.
@MainActor
final class ExternalRuleImportCoordinator {
    private weak var owner: UIViewController?
    private weak var expectedWindow: UIWindow?
    private weak var expectedRoot: UIViewController?
    private weak var expectedNavigation: UINavigationController?
    private var preparation: Task<Void, Never>?
    private weak var loading: UIAlertController?
    private var generation = UUID()
    private var readerConfigImport: ExternalReaderConfigImportCoordinator?
    var onImported: (() -> Void)?
    var isPreparing: Bool { preparation != nil || readerConfigImport?.isPreparing == true }

    init(owner: UIViewController) {
        self.owner = owner
        expectedWindow = owner.viewIfLoaded?.window
        expectedRoot = expectedWindow?.rootViewController
        expectedNavigation = owner.navigationController
    }

    deinit { preparation?.cancel() }

    func start(input: ExternalRuleImportInput, expected: ExternalRuleImportKind? = nil) {
        guard preparation == nil, let owner, hasCurrentOwner,
            owner.presentedViewController == nil, owner.canPerformNavigationAction
        else { return }
        let token = UUID()
        generation = token
        let dialog = UIAlertController(title: "正在读取规则", message: "", preferredStyle: .alert)
        dialog.view.accessibilityIdentifier = "externalRuleImport.loading"
        dialog.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.cancel() })
        loading = dialog
        owner.present(dialog, animated: true)
        preparation = Task { [weak self] in
            do {
                let limit = expected == nil ? ReaderPresetTransferResources.archiveLimit : ExternalRuleImportLoader.maximumBytes
                let data = try await ExternalRuleImportLoader.load(input, limit: limit)
                try Task.checkCancellation()
                if expected == nil, data.starts(with: [0x50, 0x4B]) {
                    guard let self else { return }
                    let owner = try await self.finishLoading(token: token)
                    let coordinator = ExternalReaderConfigImportCoordinator(owner: owner)
                    coordinator.onImported = { [weak self] in self?.onImported?() }
                    self.readerConfigImport = coordinator
                    self.preparation = nil
                    coordinator.start(data: data)
                    return
                }
                let parse = Task.detached(priority: .userInitiated) {
                    try ExternalRuleImportDocument.parse(data, expected: expected)
                }
                let document = try await withTaskCancellationHandler(
                    operation: { try await parse.value }, onCancel: { parse.cancel() })
                try Task.checkCancellation()
                let preview: UIViewController
                if document.kind == .bookSource {
                    let screen = SourceImportScreenAdapter()
                    try screen.bootstrap().get()
                    let sourcePreview = try await screen.preparePreview(source: .payload(document.payload))
                    try Task.checkCancellation()
                    let page = SourceImportPreviewViewController(preview: sourcePreview)
                    page.onConfirm = { sources, options in _ = try await screen.importSelected(sources: sources, options: options)
                    }
                    page.onImported = { [weak self] in self?.onImported?() }
                    preview = page
                } else {
                    let page = ExternalRuleImportPreviewViewController(document: document)
                    page.onImported = { [weak self] in self?.onImported?() }
                    preview = UINavigationController(rootViewController: page)
                }
                guard let self else { return }
                let owner = try await self.finishLoading(token: token)
                owner.present(preview, animated: true)
                self.preparation = nil
            } catch {
                guard let self, self.generation == token else { return }
                if !(error is CancellationError) {
                    do { try await self.waitUntilPresentable(token: token) } catch {
                        if self.generation == token { self.preparation = nil }
                        return
                    }
                }
                self.preparation = nil
                self.loading?.dismiss(animated: true) { [weak self] in
                    guard !(error is CancellationError) else { return }
                    self?.owner?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func finishLoading(token: UUID) async throws -> UIViewController {
        try await waitUntilPresentable(token: token)
        guard let loading else { throw CancellationError() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loading.dismiss(animated: true) { continuation.resume() }
        }
        try await waitUntilOwnerReady(token: token)
        guard let owner else { throw CancellationError() }
        return owner
    }

    private func waitUntilPresentable(token: UUID) async throws {
        while true {
            try Task.checkCancellation()
            guard generation == token, hasCurrentOwner, let owner,
                let loading, owner.presentedViewController === loading
            else { throw CancellationError() }
            if owner.viewIfLoaded?.window?.isKeyWindow == true,
                owner.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active,
                !loading.isBeingPresented, !loading.isBeingDismissed,
                owner.transitionCoordinator == nil, expectedNavigation?.transitionCoordinator == nil,
                expectedRoot?.transitionCoordinator == nil
            {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func waitUntilOwnerReady(token: UUID) async throws {
        while true {
            try Task.checkCancellation()
            guard generation == token, hasCurrentOwner, let owner else { throw CancellationError() }
            if owner.viewIfLoaded?.window?.isKeyWindow == true,
                owner.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active,
                owner.presentedViewController == nil, owner.canPerformNavigationAction
            {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private var hasCurrentOwner: Bool {
        guard let owner, let window = expectedWindow, let root = expectedRoot, let navigation = expectedNavigation,
            window.rootViewController === root, owner.viewIfLoaded?.window === window,
            owner.navigationController === navigation, owner.isVisibleInNavigationStack,
            !owner.isBeingDismissed, !owner.isMovingFromParent,
            !navigation.isBeingDismissed, !root.isBeingDismissed
        else { return false }
        return true
    }

    func cancel() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        loading?.dismiss(animated: true)
        readerConfigImport?.cancel()
    }
}
