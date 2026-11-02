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
                            var userInfo: [String: Any] = [
                                NSLocalizedDescriptionKey: localizedErrorMessage(
                                    code: response.errorCode, message: response.errorMessage)
                            ]
                            if let code = response.errorCode { userInfo["errorCode"] = code }
                            completion(
                                nil,
                                NSError(
                                    domain: "io.legado.backup-preparation", code: 1,
                                    userInfo: userInfo))
                        }
                    })
            }
        } onCancel: {
            terminal.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    static func localizedWarnings(_ warnings: [String]) -> [String] {
        // Presentation only: match fixed shared warnings exactly and preserve all other text, order and duplicates.
        warnings.map { warning in
            switch warning {
            // AndroidBackupArchive
            case "服务器配置未恢复：备份密码不正确或加密数据已损坏。":
                return NSLocalizedString(
                    "backup.notice.restore_servers_not_restored", value: "服务器配置未恢复：备份密码不正确或加密数据已损坏。",
                    comment: "Server settings could not be restored from the Android backup")
            case "WebDAV 密码未恢复：备份密码不正确或密码数据未加密，请重新填写。":
                return NSLocalizedString(
                    "backup.notice.restore_webdav_password_not_restored", value: "WebDAV 密码未恢复：备份密码不正确或密码数据未加密，请重新填写。",
                    comment: "WebDAV password must be entered again after restoring")
            case "KMP metadata 无法读取；已忽略扩展快照，仅使用 Android 原生文件恢复。":
                return NSLocalizedString(
                    "backup.notice.restore_metadata_unreadable", value: "KMP metadata 无法读取；已忽略扩展快照，仅使用 Android 原生文件恢复。",
                    comment: "Unreadable KMP metadata was skipped in favor of native Android files")
            case "Android 自定义字体和背景图片文件未包含在备份中，已使用系统字体与默认背景；需要在 iOS 重新选择。":
                return NSLocalizedString(
                    "backup.notice.restore_fonts_backgrounds_missing",
                    value: "Android 自定义字体和背景图片文件未包含在备份中，已使用系统字体与默认背景；需要在 iOS 重新选择。",
                    comment: "Android font and background image files are absent from the backup")
            case "本地书籍仅恢复书架记录，Android 本地文件路径不会迁移；请重新导入原书文件，或在忽略项中跳过本地书籍。":
                return NSLocalizedString(
                    "backup.notice.restore_local_books_records_only",
                    value: "本地书籍仅恢复书架记录，Android 本地文件路径不会迁移；请重新导入原书文件，或在忽略项中跳过本地书籍。",
                    comment: "Local books require their original files after restoring bookshelf records")
            // AndroidBackupExport
            case "Android 备份不是整体加密：仅服务器列表与 WebDAV 密码按原生 BackupAES 加密，书源请求头、规则和变量仍为明文。":
                return NSLocalizedString(
                    "backup.notice.export_partial_encryption",
                    value: "Android 备份不是整体加密：仅服务器列表与 WebDAV 密码按原生 BackupAES 加密，书源请求头、规则和变量仍为明文。",
                    comment: "Android backup encryption does not cover source headers, rules or variables")
            case "KMP 扩展快照另存为 metadata；Android 不使用此文件，Android 重新备份后不会保留这些扩展。":
                return NSLocalizedString(
                    "backup.notice.export_metadata_android_ignored",
                    value: "KMP 扩展快照另存为 metadata；Android 不使用此文件，Android 重新备份后不会保留这些扩展。",
                    comment: "Android ignores and does not retain KMP metadata when backing up again")
            case "ZIP 不包含本地书原文件、字体、背景、封面或欢迎页图片，也不包含正文、Cookie 和独立脚本大变量缓存；资源需在目标设备另行导入。":
                return NSLocalizedString(
                    "backup.notice.export_external_resources_excluded",
                    value: "ZIP 不包含本地书原文件、字体、背景、封面或欢迎页图片，也不包含正文、Cookie 和独立脚本大变量缓存；资源需在目标设备另行导入。",
                    comment: "Files and caches excluded from the Android backup ZIP")
            case "本地书仅导出书架记录和进度，不包含原书文件；Android 本地路径不可迁移，需重新导入原书。":
                return NSLocalizedString(
                    "backup.notice.export_local_books_records_only",
                    value: "本地书仅导出书架记录和进度，不包含原书文件；Android 本地路径不可迁移，需重新导入原书。",
                    comment: "Local book exports contain records and progress but no original files")
            case "本地封面图片文件未迁移，书架和分组仅保留原封面引用；目标设备需重新选择图片。":
                return NSLocalizedString(
                    "backup.notice.export_local_covers_references_only",
                    value: "本地封面图片文件未迁移，书架和分组仅保留原封面引用；目标设备需重新选择图片。",
                    comment: "Local cover references are exported without their image files")
            // AndroidBackupPreferencesExport
            case "共享阅读排版快照无效，Android 备份已回退到原生共享配置或默认排版。":
                return NSLocalizedString(
                    "backup.notice.export_shared_layout_fallback", value: "共享阅读排版快照无效，Android 备份已回退到原生共享配置或默认排版。",
                    comment: "Invalid shared reader layout falls back to native or default Android layout")
            case "Android 原生直链上传规则为明文文件，可能包含上传凭据；请妥善保管备份。":
                return NSLocalizedString(
                    "backup.notice.export_direct_link_plaintext", value: "Android 原生直链上传规则为明文文件，可能包含上传凭据；请妥善保管备份。",
                    comment: "Plaintext direct link upload rules may expose upload credentials")
            case "Android 标题字号为整数，小数字号已取整；原值保留在 KMP metadata。":
                return NSLocalizedString(
                    "backup.notice.export_title_size_rounded", value: "Android 标题字号为整数，小数字号已取整；原值保留在 KMP metadata。",
                    comment: "Fractional title font sizes are converted to integers for Android")
            case "字体文件与 iOS 字体并未迁移；Android 仅保留字体名称或路径引用，需要在目标设备重新选择。":
                return NSLocalizedString(
                    "backup.notice.export_fonts_not_migrated",
                    value: "字体文件与 iOS 字体并未迁移；Android 仅保留字体名称或路径引用，需要在目标设备重新选择。",
                    comment: "Font names or references are exported without font files or iOS fonts")
            case "自定义阅读背景图片未迁移；Android 原生配置使用纯色背景，原路径保留在 KMP metadata。":
                return NSLocalizedString(
                    "backup.notice.export_backgrounds_not_migrated",
                    value: "自定义阅读背景图片未迁移；Android 原生配置使用纯色背景，原路径保留在 KMP metadata。",
                    comment: "Android uses a solid reader background when custom image files are not migrated")
            case "部分颜色值不符合 Android Color.parseColor 契约，原生配置使用默认颜色，原值保留在 KMP metadata。":
                return NSLocalizedString(
                    "backup.notice.export_invalid_colors_fallback",
                    value: "部分颜色值不符合 Android Color.parseColor 契约，原生配置使用默认颜色，原值保留在 KMP metadata。",
                    comment: "Colors incompatible with Android Color.parseColor use native defaults")
            case "页眉页脚颜色无效，Android 使用默认颜色；原值保留在 KMP metadata。":
                return NSLocalizedString(
                    "backup.notice.export_invalid_header_footer_colors_fallback", value: "页眉页脚颜色无效，Android 使用默认颜色；原值保留在 KMP metadata。",
                    comment: "Invalid header or footer colors use Android defaults")
            case "部分颜色与 Android 的跟随正文／默认分隔线标记重合；原颜色保留在 KMP metadata。":
                return NSLocalizedString(
                    "backup.notice.export_color_marker_collision", value: "部分颜色与 Android 的跟随正文／默认分隔线标记重合；原颜色保留在 KMP metadata。",
                    comment: "Some colors coincide with Android body-text or default-divider markers")
            // AndroidBackupExportPreferenceKeys
            case "部分 iOS 专用或类型不兼容的偏好仅保留在 KMP metadata，未写入 Android config.xml。":
                return NSLocalizedString(
                    "backup.notice.unsupported_preferences",
                    value: "部分 iOS 专用或类型不兼容的偏好仅保留在 KMP metadata，未写入 Android config.xml。",
                    comment: "Platform-specific or incompatible preferences are retained in KMP metadata only")
            // AndroidBackupExportMetadata
            case "KMP metadata 不匹配、损坏或密码不正确；已忽略扩展快照，仅使用 Android 原生文件恢复。":
                return NSLocalizedString(
                    "backup.notice.restore_metadata_invalid",
                    value: "KMP metadata 不匹配、损坏或密码不正确；已忽略扩展快照，仅使用 Android 原生文件恢复。",
                    comment: "Invalid KMP metadata was skipped in favor of native Android files")
            default:
                return warning
            }
        }
    }

    private static func localizedErrorMessage(code: String?, message: String?) -> String {
        // Only this exact code/message pair is fixed by AndroidBackupPreparationRequest and AndroidBackupArchive.
        if code == "INVALID_ANDROID_BACKUP",
            message == "Android 备份无法读取：文件损坏、格式无效或超过大小上限"
        {
            return NSLocalizedString(
                "backup.prepare.invalid_android_backup", value: "Android 备份无法读取：文件损坏、格式无效或超过大小上限",
                comment: "Stable INVALID_ANDROID_BACKUP preparation failure")
        }
        return message
            ?? NSLocalizedString(
                "backup.prepare.failed", value: "备份无法解析，请检查文件后重试",
                comment: "Backup preparation failed without an error message")
    }
}
