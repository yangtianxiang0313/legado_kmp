import Foundation
import shared

/// A single request owns this writer. Cancellation can never delete the user's previous daily ZIP.
final class AutomaticBackupNativeWriter: NSObject, AutomaticBackupLocalWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var task: Task<Void, Never>?

    func save(
        archive: AndroidBackupExport,
        configuration: AutomaticBackupConfiguration,
        onResult: @escaping (AutomaticBackupLocalResult) -> Void
    ) {
        lock.lock()
        guard !started, !cancelled else {
            lock.unlock()
            onResult(AutomaticBackupLocalResult(file: nil, cancelled: true))
            return
        }
        started = true
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let file = try await LocalBackupStore.shared.save(
                    base64: archive.base64Zip, onlyLatest: configuration.onlyLatest,
                    configuredPath: configuration.configuredPath)
                let destination: URL
                if configuration.onlyLatest {
                    destination = file
                } else {
                    // LocalBackupStore validates the directory and atomically stages this request's ZIP.
                    destination = file.deletingLastPathComponent().appendingPathComponent(configuration.archiveName)
                    do {
                        try Task.checkCancellation()
                        let manager = FileManager.default
                        let directory = file.deletingLastPathComponent().standardizedFileURL
                        guard directory.resolvingSymlinksInPath() == directory else {
                            throw CocoaError(.fileWriteNoPermission)
                        }
                        if manager.fileExists(atPath: destination.path) {
                            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                                throw CocoaError(.fileWriteNoPermission)
                            }
                            _ = try manager.replaceItemAt(destination, withItemAt: file)
                        } else {
                            try manager.moveItem(at: file, to: destination)
                        }
                    } catch {
                        // Only the uniquely named file returned by this save belongs to this request.
                        try? FileManager.default.removeItem(at: file)
                        throw error
                    }
                }
                try Task.checkCancellation()
                onResult(AutomaticBackupLocalResult(file: destination.path, cancelled: false))
            } catch is CancellationError {
                onResult(AutomaticBackupLocalResult(file: nil, cancelled: true))
            } catch {
                // Neither filesystem errors nor a payload are forwarded across the callback boundary.
                onResult(AutomaticBackupLocalResult(file: nil, cancelled: false))
            }
        }
        task = work
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let work = task
        lock.unlock()
        work?.cancel()
    }

    func waitUntilFinished() async {
        if let work = currentTask() { await work.value }
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}
