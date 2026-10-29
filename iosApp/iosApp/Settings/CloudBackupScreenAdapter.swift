import Foundation
import shared

@MainActor
final class CloudBackupScreenAdapter {
    private var facade: CloudBackupFacade?

    func list() async throws -> [CloudBackupFile] {
        let facade = try resolve()
        let result = try await request { facade.listBackupsRequest(onResult: $0) }
        guard let files = result.files else { throw Self.invalidResult() }
        return files
    }

    func upload(password: String) async throws -> CloudBackupUpload {
        let facade = try resolve()
        let result = try await request { facade.uploadBackupRequest(password: password, onResult: $0) }
        guard let upload = result.upload else { throw Self.invalidResult() }
        return upload
    }

    func restore(file: CloudBackupFile, password: String) async throws -> CloudBackupRestore {
        let prepared = try await prepareRestore(file: file, password: password)
        defer { prepared.discard() }
        return try await restore(prepared: prepared)
    }

    func prepareRestore(file: CloudBackupFile, password: String) async throws -> PreparedCloudBackup {
        let facade = try resolve()
        let result = try await terminalRequest {
            facade.prepareRestoreBackupFileRequest(file: file, password: password, onResult: $0)
        }
        guard let prepared = result.prepared else { throw Self.invalidResult() }
        if Task.isCancelled {
            prepared.discard()
            throw CancellationError()
        }
        return prepared
    }

    func restore(prepared: PreparedCloudBackup) async throws -> CloudBackupRestore {
        try Task.checkCancellation()
        let facade = try resolve()
        let result = try await terminalRequest { facade.restorePreparedBackupRequest(prepared: prepared, onResult: $0) }
        guard let restored = result.restored else { throw Self.invalidResult() }
        return restored
    }

    func checkNewBackup() async throws -> CloudBackupFile? {
        let facade = try resolve()
        return try await request { facade.checkNewBackupRequest(onResult: $0) }.newBackup
    }

    func acknowledge(_ file: CloudBackupFile) async throws {
        let facade = try resolve()
        try await SharedAsync.void { facade.acknowledgeBackup(file: file, completionHandler: $0) }
    }

    func markLocalBackupCreated() async throws {
        let facade = try resolve()
        try await SharedAsync.void { facade.markLocalBackupCreated(completionHandler: $0) }
    }

    private func resolve() throws -> CloudBackupFacade {
        if let facade { return facade }
        let resolved = try BootstrapApiKt.sharedCloudBackupFacade()
        facade = resolved
        return resolved
    }

    private func request(
        _ start: (@escaping (CloudBackupRequestResult) -> Void) -> FlowSubscription
    ) async throws -> CloudBackupRequestResult {
        let result: CloudBackupRequestResult = try await SharedCancellableAsync.value { completion in
            start { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if !result.completed || result.errorMessage != nil {
                    completion(nil, Self.invalidResult(result.errorMessage))
                } else {
                    completion(result, nil)
                }
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func terminalRequest(
        _ start: (@escaping (CloudBackupRequestResult) -> Void) -> FlowSubscription
    ) async throws -> CloudBackupRequestResult {
        let terminal = BackupRestoreTerminalRequest()
        // A cancelled Swift task must still observe the real shared terminal result.
        return try await withTaskCancellationHandler {
            try await SharedAsync.value { completion in
                terminal.install(
                    start { result in
                        terminal.finish()
                        if result.completed, result.errorMessage == nil {
                            completion(result, nil)
                        } else if result.isCancelled {
                            result.prepared?.discard()
                            completion(nil, CancellationError())
                        } else {
                            result.prepared?.discard()
                            completion(nil, Self.invalidResult(result.errorMessage))
                        }
                    })
            }
        } onCancel: {
            terminal.cancel()
        }
    }

    private static func invalidResult(_ message: String? = nil) -> NSError {
        NSError(
            domain: "io.legado.cloudBackup", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message ?? "备份服务暂不可用，请重试"])
    }
}
