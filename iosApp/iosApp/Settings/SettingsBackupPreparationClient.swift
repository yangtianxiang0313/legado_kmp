import Foundation
import shared

enum SettingsBackupPreparationClient {
    static func prepare(data: Data, password: String) async throws -> AndroidBackupImport {
        let encoding = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = data.base64EncodedString()
            try Task.checkCancellation()
            return value
        }
        let base64 = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: {
            encoding.cancel()
        }
        try Task.checkCancellation()
        let terminal = BackupRestoreTerminalRequest()
        let result: AndroidBackupImport = try await withTaskCancellationHandler {
            try await SharedAsync.value { completion in
                terminal.install(
                    AndroidBackupPreparationRequest().prepare(base64Zip: base64, password: password) { response in
                        terminal.finish()
                        if response.isCancelled {
                            completion(nil, CancellationError())
                        } else if let value = response.prepared {
                            completion(value, nil)
                        } else {
                            completion(
                                nil,
                                NSError(
                                    domain: "io.legado.backup-preparation", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: response.errorMessage ?? "备份无法解析，请检查文件后重试"]))
                        }
                    })
            }
        } onCancel: {
            terminal.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}
