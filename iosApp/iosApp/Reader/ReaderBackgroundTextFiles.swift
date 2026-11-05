import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import shared

enum ReaderBackgroundTextFiles {
    private static let importLock = NSLock()
    private static var pendingImports: [FileIdentity: PendingImport] = [:]

    final class ImportLease {
        let storedPath: String
        private let id: UUID
        private let identity: FileIdentity?

        fileprivate init(storedPath: String, id: UUID, identity: FileIdentity?) {
            self.storedPath = storedPath
            self.id = id
            self.identity = identity
        }

        func commit() {
            ReaderBackgroundTextFiles.locked {
                guard let identity, let pending = ReaderBackgroundTextFiles.pendingImports[identity],
                    pending.leases.contains(id)
                else { return }
                ReaderBackgroundTextFiles.pendingImports.removeValue(forKey: identity)
            }
        }

        func rollback() throws {
            try ReaderBackgroundTextFiles.locked {
                guard let identity, var pending = ReaderBackgroundTextFiles.pendingImports[identity],
                    pending.leases.contains(id)
                else { return }
                if pending.leases.count > 1 {
                    pending.leases.remove(id)
                    ReaderBackgroundTextFiles.pendingImports[identity] = pending
                    return
                }
                // Keep the last hold until deletion succeeds so rollback can be retried.
                do {
                    let current = try ReaderBackgroundTextFiles.fileIdentity(at: pending.url)
                    if current == identity {
                        try FileManager.default.removeItem(at: pending.url)
                    }
                } catch {
                    let value = error as NSError
                    guard value.domain == NSCocoaErrorDomain,
                        [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
                    else { throw error }
                }
                ReaderBackgroundTextFiles.pendingImports.removeValue(forKey: identity)
            }
        }

        deinit {
            do { try rollback() } catch {
                NSLog("ReaderBackgroundTextFiles rollback: %@", error.localizedDescription)
            }
        }
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while let chunk = try file.read(upToCount: min(65_536, limit - result.count + 1)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= limit else { throw invalidConfig }
        }
        return result
    }

    static var invalidConfig: NSError {
        NSError(
            domain: "io.legado.reader.background", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("reader.preset.consumer.config_invalid", value: "阅读配置格式无效", comment: "")
            ])
    }

    static func importImage(_ data: Data) throws -> String {
        try importImage(data, leaseID: nil).storedPath
    }

    static func leaseImageImport(_ data: Data) throws -> ImportLease {
        let id = UUID()
        let resource = try importImage(data, leaseID: id)
        return ImportLease(storedPath: resource.storedPath, id: id, identity: resource.identity)
    }

    static func leaseImage(forStoredPath path: String) throws -> ImportLease {
        try locked {
            guard path.hasPrefix("legado-background-file:"),
                let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: path)
            else { throw invalidConfig }
            let identity = try fileIdentity(at: url)
            let id = UUID()
            if var pending = pendingImports[identity] {
                pending.leases.insert(id)
                pendingImports[identity] = pending
                return ImportLease(storedPath: path, id: id, identity: identity)
            }
            // Existing persistent images are borrowed without cleanup ownership.
            return ImportLease(storedPath: path, id: id, identity: nil)
        }
    }

    private static func importImage(_ data: Data, leaseID: UUID?) throws -> (storedPath: String, identity: FileIdentity?) {
        guard data.count <= 32 * 1024 * 1024, let image = UIImage(data: data),
            image.size.width > 0, image.size.height > 0,
            let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
            let ext = UTType(type as String)?.preferredFilenameExtension
        else {
            throw NSError(
                domain: "io.legado.reader.background", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("reader.preset.consumer.image_unreadable", value: "无法读取背景图片", comment: "")
                ])
        }
        return try locked {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            .appendingPathComponent("ReaderBackgrounds", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var fileName = UUID().uuidString + "." + ext
            while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
                fileName = UUID().uuidString + "." + ext
            }
            let url = directory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            let storedPath = "legado-background-file:" + fileName
            guard let leaseID else { return (storedPath, nil) }
            do {
                let identity = try fileIdentity(at: url)
                pendingImports[identity] = PendingImport(url: url, leases: [leaseID])
                return (storedPath, identity)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let device = attributes[.systemNumber] as? NSNumber,
            let number = attributes[.systemFileNumber] as? NSNumber
        else { throw invalidConfig }
        // Case variants can resolve to the same file on the local filesystem.
        return FileIdentity(device: device.uint64Value, number: number.uint64Value)
    }

    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        importLock.lock()
        defer { importLock.unlock() }
        return try body()
    }

    fileprivate struct FileIdentity: Hashable {
        let device: UInt64
        let number: UInt64
    }

    private struct PendingImport {
        let url: URL
        var leases: Set<UUID>
    }

    static func restoreTemplates(facade: SettingsFacade, bundle: Bundle = .main) throws -> [ReaderPreset] {
        guard let url = bundle.url(forResource: "readConfig", withExtension: "json", subdirectory: "ReaderBackgrounds") else {
            throw invalidConfig
        }
        let data = try Data(contentsOf: url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw invalidConfig }
        let codec = ReaderPresetTransferCodec()
        return try rows.map { row in
            let normalized = try JSONSerialization.data(withJSONObject: row)
            return try codec.decode(jsonString: String(decoding: normalized, as: UTF8.self))
        }
    }
}
