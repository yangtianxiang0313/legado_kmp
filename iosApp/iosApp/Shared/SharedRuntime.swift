import Foundation
import shared

enum SharedRuntimeState: Equatable {
    case idle
    case bootstrapping
    case ready
    case failed(String)
}

struct SharedRuntimeError: LocalizedError {
    let operation: String
    let message: String
    let underlying: Error?

    var errorDescription: String? {
        "[Legado iOS] \(operation): \(message)"
    }
}

enum SharedRuntime {
    private static let lock = NSLock()
    private static var stateStorage: SharedRuntimeState = .idle

    static var startupState: SharedRuntimeState {
        lock.withLock { stateStorage }
    }

    static func bootstrap() -> Result<Void, SharedRuntimeError> {
        lock.lock()
        let currentState = stateStorage
        if case .ready = currentState {
            lock.unlock()
            log("shared runtime already ready")
            return .success(())
        }
        stateStorage = .bootstrapping
        lock.unlock()

        log("shared runtime bootstrap started")
        do {
            _ = try BootstrapApiKt.startSharedRuntimeOrThrow()
            if let payload = Bundle.main.legadoDefaultRssSourcesPayload(), payload.isEmpty == false {
                _ = try BootstrapApiKt.seedBundledRssSourcesIfEmpty(payload: payload)
            }
            let health = BootstrapApiKt.sharedRuntimeHealthCheck()
            setState(.ready)
            log("shared runtime bootstrap finished: \(health.status)")
            return .success(())
        } catch {
            let runtimeError = makeError(
                operation: "bootstrap",
                defaultMessage: "Shared runtime failed to start",
                underlying: error
            )
            setState(.failed(runtimeError.message))
            log("shared runtime bootstrap failed: \(runtimeError.message)")
            return .failure(runtimeError)
        }
    }

    static func reset() {
        setState(.idle)
        BootstrapApiKt.stopSharedRuntime()
        log("shared runtime reset")
    }

    static func bookshelfFacade() -> Result<BookshelfFacade, SharedRuntimeError> {
        resolveFacade("BookshelfFacade") { try BootstrapApiKt.sharedBookshelfFacade() }
    }

    static func searchFacade() -> Result<SearchFacade, SharedRuntimeError> {
        resolveFacade("SearchFacade") { try BootstrapApiKt.sharedSearchFacade() }
    }

    static func bookDetailFacade() -> Result<BookDetailFacade, SharedRuntimeError> {
        resolveFacade("BookDetailFacade") { try BootstrapApiKt.sharedBookDetailFacade() }
    }

    static func bookImageFacade() -> Result<BookImageFacade, SharedRuntimeError> {
        resolveFacade("BookImageFacade") { try BootstrapApiKt.sharedBookImageFacade() }
    }

    static func readerFacade() -> Result<ReaderFacade, SharedRuntimeError> {
        resolveFacade("ReaderFacade") { try BootstrapApiKt.sharedReaderFacade() }
    }

    static func dictionaryFacade() -> Result<DictionaryFacade, SharedRuntimeError> {
        resolveFacade("DictionaryFacade") { try BootstrapApiKt.sharedDictionaryFacade() }
    }

    static func discoveryFacade() -> Result<DiscoveryFacade, SharedRuntimeError> {
        resolveFacade("DiscoveryFacade") { try BootstrapApiKt.sharedDiscoveryFacade() }
    }

    static func rssFacade() -> Result<RssFacade, SharedRuntimeError> {
        resolveFacade("RssFacade") { try BootstrapApiKt.sharedRssFacade() }
    }

    static func settingsFacade() -> Result<SettingsFacade, SharedRuntimeError> {
        resolveFacade("SettingsFacade") { try BootstrapApiKt.sharedSettingsFacade() }
    }

    static func runtimeFacade() -> Result<RuntimeFacade, SharedRuntimeError> {
        resolveFacade("RuntimeFacade") { try BootstrapApiKt.sharedRuntimeFacade() }
    }

    static func remoteBookFacade() -> Result<RemoteBookFacade, SharedRuntimeError> {
        resolveFacade("RemoteBookFacade") { try BootstrapApiKt.sharedRemoteBookFacade() }
    }

    static func sourceManagementFacade() -> Result<SourceManagementFacade, SharedRuntimeError> {
        resolveFacade("SourceManagementFacade") { try BootstrapApiKt.sharedSourceManagementFacade() }
    }

    static func sourceLoginFacade() -> Result<SourceLoginFacade, SharedRuntimeError> {
        resolveFacade("SourceLoginFacade") { try BootstrapApiKt.sharedSourceLoginFacade() }
    }

    static func bookSourceDebugFacade() -> Result<BookSourceDebugFacade, SharedRuntimeError> {
        resolveFacade("BookSourceDebugFacade") { try BootstrapApiKt.sharedBookSourceDebugFacade() }
    }

    static func replaceRuleFacade() -> Result<ReplaceRuleFacade, SharedRuntimeError> {
        resolveFacade("ReplaceRuleFacade") { try BootstrapApiKt.sharedReplaceRuleFacade() }
    }

    static func bookmarkFacade() -> Result<BookmarkFacade, SharedRuntimeError> {
        resolveFacade("BookmarkFacade") { try BootstrapApiKt.sharedBookmarkFacade() }
    }

    static func cacheFacade() -> Result<CacheFacade, SharedRuntimeError> {
        resolveFacade("CacheFacade") { try BootstrapApiKt.sharedCacheFacade() }
    }

    static func logFacade() -> Result<LogFacade, SharedRuntimeError> {
        resolveFacade("LogFacade") { try BootstrapApiKt.sharedLogFacade() }
    }

    static func audioPlayFacade() -> Result<AudioPlayFacade, SharedRuntimeError> {
        resolveFacade("AudioPlayFacade") { try BootstrapApiKt.sharedAudioPlayFacade() }
    }

    static func log(_ message: String) {
        NSLog("[Legado iOS] %@", message)
    }

    private static func resolveFacade<T>(
        _ name: String,
        loader: () throws -> T
    ) -> Result<T, SharedRuntimeError> {
        switch bootstrap() {
        case .failure(let error):
            return .failure(error)
        case .success:
            do {
                let facade = try loader()
                log("resolved facade: \(name)")
                return .success(facade)
            } catch {
                let runtimeError = makeError(
                    operation: "resolve \(name)",
                    defaultMessage: "Failed to resolve shared facade",
                    underlying: error
                )
                log("facade resolution failed: \(name) - \(runtimeError.message)")
                return .failure(runtimeError)
            }
        }
    }

    private static func setState(_ state: SharedRuntimeState) {
        lock.withLock {
            stateStorage = state
        }
    }

    private static func makeError(
        operation: String,
        defaultMessage: String,
        underlying: Error
    ) -> SharedRuntimeError {
        let message = (underlying as NSError).localizedDescription
        return SharedRuntimeError(
            operation: operation,
            message: message.isEmpty ? defaultMessage : message,
            underlying: underlying
        )
    }
}

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T {
        lock()
        defer { unlock() }
        return action()
    }
}
