import Foundation

/// Per-process aggregate quota also bounds simultaneous reader/book audio assets.
final class MediaAudioSpool {
    private final class Budget: @unchecked Sendable {
        let lock = NSLock()
        var reservedBytes: Int64 = 0
        var cleanedStaleFiles = false
    }
    private static let budget = Budget()
    private static let quota: Int64 = 256 * 1024 * 1024
    private static let prefix = "legado-audio-"

    private let url: URL
    private var file: FileHandle?
    private var reservation: Int64 = 0

    init() throws {
        Self.budget.lock.lock()
        if !Self.budget.cleanedStaleFiles {
            Self.budget.cleanedStaleFiles = true
            let temporary = FileManager.default.temporaryDirectory
            let stale = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
            for url in stale where url.lastPathComponent.hasPrefix(Self.prefix) && url.pathExtension == "spool" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        Self.budget.lock.unlock()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).spool")
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else {
            throw MediaAudioError.storage
        }
        do { file = try FileHandle(forUpdating: url) } catch {
            try? FileManager.default.removeItem(at: url); throw MediaAudioError.storage
        }
    }

    func append(_ data: Data) throws {
        guard let file else { throw MediaAudioError.storage }
        let count = Int64(data.count)
        Self.budget.lock.lock()
        let allowed = count <= Self.quota - Self.budget.reservedBytes
        if allowed { Self.budget.reservedBytes += count; reservation += count }
        Self.budget.lock.unlock()
        guard allowed else { throw MediaAudioError.tooLarge }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard let file, offset >= 0 else { throw MediaAudioError.storage }
        try file.seek(toOffset: UInt64(offset))
        guard let data = try file.read(upToCount: count), !data.isEmpty else { throw MediaAudioError.storage }
        return data
    }

    func close() {
        try? file?.close()
        file = nil
        try? FileManager.default.removeItem(at: url)
        Self.budget.lock.lock()
        Self.budget.reservedBytes -= reservation
        reservation = 0
        Self.budget.lock.unlock()
    }

    deinit { close() }
}
