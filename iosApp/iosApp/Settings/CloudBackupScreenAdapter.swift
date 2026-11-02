import Foundation
import shared

@MainActor
final class CloudBackupScreenAdapter {
    private var facade: CloudBackupFacade?

    func configuration() throws -> AutomaticBackupConfiguration {
        try resolve().automaticBackups().configuration()
    }

    func matchesConfiguration(_ expected: AutomaticBackupConfiguration) -> Bool {
        guard let current = try? configuration() else { return false }
        return expected.matchesConfiguration(other: current)
    }

    func list(configuration: AutomaticBackupConfiguration) async throws -> [CloudBackupFile] {
        try requireConfiguration(configuration)
        let facade = try resolve()
        let result = try await request { facade.listBackupsRequest(onResult: $0) }
        try requireConfiguration(configuration)
        guard let files = result.files else { throw Self.invalidResult() }
        return files
    }

    func upload(password: String, configuration: AutomaticBackupConfiguration) async throws -> CloudBackupUpload {
        try Task.checkCancellation()
        let facade = try resolve()
        let result = try await terminalRequest(configuration: configuration) {
            facade.uploadBackupForConfigurationRequest(configuration: configuration, password: password, onResult: $0)
        }
        guard let upload = result.upload else { throw Self.invalidResult() }
        return upload
    }

    func restore(file: CloudBackupFile, password: String) async throws -> CloudBackupRestore {
        let prepared = try await prepareRestore(file: file, password: password, configuration: configuration())
        defer { prepared.discard() }
        return try await restore(prepared: prepared)
    }

    func prepareRestore(
        file: CloudBackupFile, password: String, configuration: AutomaticBackupConfiguration
    ) async throws -> PreparedCloudBackup {
        try Task.checkCancellation()
        let facade = try resolve()
        let result = try await terminalRequest(configuration: configuration) {
            facade.prepareRestoreBackupFileRequest(file: file, password: password, onResult: $0)
        }
        guard let prepared = result.prepared else { throw Self.invalidResult() }
        if Task.isCancelled || !matchesConfiguration(configuration) {
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

    func checkNewBackup(configuration: AutomaticBackupConfiguration) async throws -> CloudBackupFile? {
        try requireConfiguration(configuration)
        let facade = try resolve()
        let result = try await request { facade.checkNewBackupRequest(onResult: $0) }
        try requireConfiguration(configuration)
        return result.newBackup
    }

    func acknowledge(_ file: CloudBackupFile, configuration: AutomaticBackupConfiguration) async throws {
        try Task.checkCancellation()
        try requireConfiguration(configuration)
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
        configuration: AutomaticBackupConfiguration? = nil,
        _ start: (@escaping (CloudBackupRequestResult) -> Void) -> FlowSubscription
    ) async throws -> CloudBackupRequestResult {
        let terminal = BackupRestoreTerminalRequest()
        // A cancelled Swift task must still observe the real shared terminal result.
        return try await withTaskCancellationHandler {
            try await SharedAsync.value { completion in
                do {
                    try Task.checkCancellation()
                    if let configuration { try requireConfiguration(configuration) }
                } catch {
                    terminal.finish()
                    completion(nil, error)
                    return
                }
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

    private func requireConfiguration(_ expected: AutomaticBackupConfiguration) throws {
        guard matchesConfiguration(expected) else {
            throw Self.invalidResult(
                NSLocalizedString(
                    "backup.cloud.configuration_changed", value: "备份目标或策略已变化，请刷新后重试。",
                    comment: "Cloud backup configuration changed"))
        }
    }

    private static func invalidResult(_ message: String? = nil) -> NSError {
        NSError(
            domain: "io.legado.cloudBackup", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message
                    ?? NSLocalizedString(
                        "backup.cloud.service_unavailable", value: "备份服务暂不可用，请重试", comment: "Backup service unavailable")
            ])
    }
}

enum CloudBackupCopy {
    static var title: String { NSLocalizedString("backup.cloud.title", value: "云端备份", comment: "Cloud backup title") }
    static var uploadAction: String { NSLocalizedString("backup.cloud.upload.action", value: "备份到云端", comment: "Upload backup action") }
    static var loading: String { NSLocalizedString("backup.cloud.list.loading", value: "正在加载…", comment: "Cloud backup list loading") }
    static var empty: String { NSLocalizedString("backup.cloud.list.empty", value: "暂无云端备份", comment: "Empty cloud backup list") }
    static var retry: String { NSLocalizedString("backup.cloud.list.retry", value: "加载失败，点击重试", comment: "Retry cloud backup list") }
    static var refreshFailed: String {
        NSLocalizedString("backup.cloud.list.refresh_failed", value: "刷新失败，当前保留上次列表。", comment: "Showing previous cloud backup list")
    }
    static var unknownTime: String { NSLocalizedString("backup.cloud.time_unknown", value: "时间未知", comment: "Unknown backup timestamp") }
    static var selectionChanged: String {
        NSLocalizedString("backup.cloud.selection_changed", value: "云端备份已变化，请重新选择", comment: "Cloud backup selection changed")
    }
    static var configurationChanged: String {
        NSLocalizedString("backup.cloud.configuration_changed", value: "备份目标或策略已变化，请刷新后重试。", comment: "Cloud backup configuration changed")
    }
    static var restoreTitle: String {
        NSLocalizedString("backup.cloud.restore.title", value: "恢复云端备份", comment: "Restore cloud backup title")
    }
    static var restoreMessage: String {
        NSLocalizedString("backup.cloud.restore.message", value: "先下载并预检所选备份，确认内容后才会恢复。", comment: "Cloud backup preflight explanation")
    }
    static var optionalPassword: String {
        NSLocalizedString("backup.cloud.password.optional", value: "备份密码（未设置可留空）", comment: "Optional backup password")
    }
    static var uploading: String { NSLocalizedString("backup.cloud.upload.progress", value: "正在上传备份", comment: "Uploading cloud backup") }
    static var uploadCancellationNotice: String {
        NSLocalizedString(
            "backup.cloud.upload.cancel_notice", value: "取消后仍需等待请求结束；已上传的云端文件不会自动撤销。",
            comment: "Upload cancellation cannot undo remote writes")
    }
    static var uploaded: String {
        NSLocalizedString("backup.cloud.upload.completed", value: "已备份到云端：%@", comment: "Uploaded backup filename")
    }
    static var uploadCancelled: String {
        NSLocalizedString(
            "backup.cloud.upload.cancelled", value: "上传请求已结束，请刷新确认云端状态；已上传的文件不会自动撤销。", comment: "Upload request settled after cancellation")
    }
    static var preparing: String {
        NSLocalizedString("backup.cloud.prepare.progress", value: "正在下载并预检备份", comment: "Downloading and checking backup")
    }
    static var preparingMessage: String {
        NSLocalizedString("backup.cloud.prepare.message", value: "此阶段未恢复任何数据，可以取消。", comment: "Backup preparation is cancellable")
    }
    static var cancelPreparation: String {
        NSLocalizedString("backup.cloud.prepare.cancel", value: "取消预检", comment: "Cancel backup preparation")
    }
    static var preparationCancelled: String {
        NSLocalizedString(
            "backup.cloud.prepare.cancelled", value: "预检已取消，未恢复任何数据。", comment: "Preparation cancelled without restoring data")
    }
    static var confirmRestore: String {
        NSLocalizedString("backup.cloud.restore.confirm", value: "确认恢复备份", comment: "Confirm prepared backup restore")
    }
    static var restoreAction: String { NSLocalizedString("backup.cloud.restore.action", value: "恢复", comment: "Restore backup action") }
    static var restoring: String { NSLocalizedString("backup.cloud.restore.progress", value: "正在恢复备份", comment: "Restoring backup") }
    static var committingMessage: String {
        NSLocalizedString(
            "backup.cloud.restore.committing", value: "正在提交恢复，请等待完成。此阶段不能取消或回滚已恢复的数据。",
            comment: "Restore commit cannot be cancelled or rolled back")
    }
    static var restored: String { NSLocalizedString("backup.cloud.restore.completed", value: "恢复完成", comment: "Backup restore completed") }
    static var restoreEnded: String {
        NSLocalizedString(
            "backup.cloud.restore.ended", value: "恢复请求已结束，请核对当前书架和设置；已提交的数据不会自动回滚。", comment: "Restore request settled after cancellation")
    }
    static var restoreCheck: String {
        NSLocalizedString(
            "backup.cloud.restore.check", value: "请核对当前书架和设置；已提交的数据不会自动回滚。", comment: "Check local data after incomplete restore")
    }

    static func preparedSummary(_ prepared: PreparedCloudBackup) -> String {
        let file = prepared.file
        let date =
            file.lastModified > 0
            ? DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: Double(file.lastModified) / 1000), dateStyle: .medium, timeStyle: .short)
            : unknownTime
        var sections = [
            file.name + "\n" + date + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
            NSLocalizedString("backup.cloud.prepare.completed", value: "预检完成，尚未恢复任何数据。", comment: "Backup preparation completed")
                + "\n" + restoreSummary(prepared.summary),
        ]
        if !prepared.warnings.isEmpty {
            sections.append(
                NSLocalizedString("backup.cloud.warnings", value: "说明：", comment: "Backup warnings heading")
                    + "\n" + SettingsBackupPreparationClient.localizedWarnings(prepared.warnings).joined(separator: "\n"))
        }
        sections.append(
            NSLocalizedString(
                "backup.cloud.restore.merge_notice",
                value: "将合并恢复并覆盖同身份的数据，设置按恢复忽略项处理。数据库和设置分开保存，不保证跨存储同时成功；已提交的数据不会自动回滚。",
                comment: "Cloud backup merge and partial commit warning"))
        return sections.joined(separator: "\n\n")
    }

    static func restoreSummary(_ result: BackupRestoreResult) -> String {
        let counts: [(String, Int32)] = [
            (NSLocalizedString("backup.cloud.data.books", value: "书架", comment: "Backup books"), result.bookCount),
            (NSLocalizedString("backup.cloud.data.book_sources", value: "书源", comment: "Backup book sources"), result.bookSourceCount),
            (NSLocalizedString("backup.cloud.data.rss_sources", value: "RSS 源", comment: "Backup RSS sources"), result.rssSourceCount),
            (
                NSLocalizedString("backup.cloud.data.replace_rules", value: "替换规则", comment: "Backup replacement rules"),
                result.replaceRuleCount
            ),
            (NSLocalizedString("backup.cloud.data.book_groups", value: "书籍分组", comment: "Backup book groups"), result.bookGroupCount),
            (NSLocalizedString("backup.cloud.data.bookmarks", value: "书签", comment: "Backup bookmarks"), result.bookmarkCount),
            (
                NSLocalizedString("backup.cloud.data.txt_toc_rules", value: "TXT 目录规则", comment: "Backup TXT TOC rules"),
                result.txtTocRuleCount
            ),
            (
                NSLocalizedString("backup.cloud.data.dictionary_rules", value: "词典规则", comment: "Backup dictionary rules"),
                result.dictRuleCount
            ),
            (
                NSLocalizedString("backup.cloud.data.search_history", value: "搜索历史", comment: "Backup search history"),
                result.searchHistoryCount
            ),
            (
                NSLocalizedString("backup.cloud.data.reading_records", value: "阅读记录", comment: "Backup reading records"),
                result.readRecordCount
            ),
            (NSLocalizedString("backup.cloud.data.rss_favorites", value: "RSS 收藏", comment: "Backup RSS favorites"), result.rssStarCount),
            (
                NSLocalizedString("backup.cloud.data.source_subscriptions", value: "源订阅", comment: "Backup source subscriptions"),
                result.sourceSubCount
            ),
            (NSLocalizedString("backup.cloud.data.http_tts", value: "HTTP 朗读配置", comment: "Backup HTTP TTS settings"), result.httpTTSCount),
            (
                NSLocalizedString("backup.cloud.data.keyboard_assists", value: "键盘辅助", comment: "Backup keyboard assists"),
                result.keyboardAssistCount
            ),
            (NSLocalizedString("backup.cloud.data.servers", value: "服务器配置", comment: "Backup server settings"), result.serverCount),
        ]
        let format = NSLocalizedString("backup.cloud.summary.count", value: "%@：%d", comment: "Backup category and count")
        let nonzero = counts.filter { $0.1 > 0 }.map { String(format: format, $0.0, $0.1) }
        let data =
            nonzero.isEmpty
            ? NSLocalizedString("backup.cloud.summary.empty", value: "15 类数据均为空", comment: "All backup data categories are empty")
            : nonzero.joined(separator: "\n")
        let preferences =
            result.preferencesRestored
            ? NSLocalizedString(
                "backup.cloud.summary.preferences_included", value: "偏好设置：包含（按恢复忽略项处理）", comment: "Backup includes preferences")
            : NSLocalizedString("backup.cloud.summary.preferences_excluded", value: "偏好设置：不包含", comment: "Backup excludes preferences")
        return data + "\n" + preferences
    }
}
