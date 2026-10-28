import Foundation

/// Local retention is independent of cloud history. A failed write preserves the previous backup.
actor LocalBackupStore {
    static let shared = LocalBackupStore()
    private let root: URL

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func save(base64: String, onlyLatest: Bool, configuredPath: String?) throws -> URL {
        try Task.checkCancellation()
        guard base64.utf8.count <= 180 * 1024 * 1024,
            let data = Data(base64Encoded: base64), data.count <= 128 * 1024 * 1024,
            data.starts(with: [0x50, 0x4b, 0x03, 0x04])
        else { throw failure("备份 ZIP 无效或超过 128 MB") }
        let manager = FileManager.default
        let directory = try destination(configuredPath)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath() == directory else { throw failure("备份目录不能是符号链接") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        var file = directory.appendingPathComponent(onlyLatest ? "backup.zip" : "backup\(formatter.string(from: Date())).zip")
        if !onlyLatest, manager.fileExists(atPath: file.path) {
            file = directory.appendingPathComponent("backup\(formatter.string(from: Date()))-\(UUID().uuidString).zip")
        }
        if manager.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("备份目标不是普通文件") }
        }
        try Task.checkCancellation()
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return file
    }

    private func destination(_ path: String?) throws -> URL {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return root.appendingPathComponent("Backups", isDirectory: true)
        }
        let url: URL
        if path.hasPrefix("file:") {
            guard let parsed = URL(string: path), parsed.isFileURL else { throw failure("备份目录无效") }
            url = parsed
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard !path.contains(":"), !path.contains("\\") else { throw failure("请选择应用文件目录内的备份路径") }
            url = root.appendingPathComponent(path, isDirectory: true)
        }
        let normalized = url.standardizedFileURL
        guard normalized.resolvingSymlinksInPath() == normalized,
            normalized == root || normalized.path.hasPrefix(root.path + "/"),
            !normalized.pathComponents.dropFirst(root.pathComponents.count).contains(where: { $0.hasPrefix(".") })
        else { throw failure("备份目录必须位于应用文件目录内") }
        return normalized
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.localBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
