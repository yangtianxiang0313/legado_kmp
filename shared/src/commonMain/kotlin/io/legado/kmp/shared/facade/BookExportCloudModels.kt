package io.legado.kmp.shared.facade

/**
 * success means PUT returned 200, 201 or 204, not that a subsequent GET verified the contents.
 * mayHaveUploaded includes acknowledged success and an uncertain remote outcome after dispatch.
 * Late cancellation/configuration changes can coexist with success: never discard that evidence.
 * A batch is not atomic; earlier files and any collections already created are not rolled back.
 */
data class BookExportCloudUploadResult(
    val success: Boolean = false,
    val conflict: Boolean = false,
    val isCancelled: Boolean = false,
    val mayHaveUploaded: Boolean = false,
    val errorMessage: String? = null,
)

internal enum class BookExportCloudMessage(val text: String) {
    CONFIGURATION("WebDAV 配置无效，请检查后重试"),
    CONFIGURATION_CHANGED("WebDAV 配置已变化，请停止本批次并重新开始"),
    CLOSED("书籍云端导出会话已关闭，请重新开始"),
    BUSY("同一会话只能逐文件上传，请等待当前文件结束"),
    FILE_NAME("书籍文件名无效或 UTF-8 长度超过 160 字节"),
    FILE_TYPE("仅支持 TXT、ZIP 或 EPUB 书籍文件"),
    FILE_SIZE("书籍文件为空或超过 128 MiB，未上传"),
    COLLECTION("WebDAV 未确认导出目录为有效目录，未上传书籍"),
    RESPONSE("WebDAV 返回无效响应，请检查服务状态"),
    AUTHORIZATION("WebDAV 认证或访问权限不足，请检查账号和配置"),
    REDIRECT("WebDAV 返回重定向，请填写最终服务地址后重试"),
    STORAGE("WebDAV 云端存储空间不足"),
    CONFLICT("云端已有同名文件；只有明确确认覆盖后才能重新上传"),
    TIMED_OUT("书籍上传超时，请确认云端状态后重试"),
    FAILED("书籍上传失败，请检查网络、证书和 WebDAV 服务状态"),
}

internal class BookExportCloudFailure(val reason: BookExportCloudMessage) : Exception(reason.text)

internal fun bookExportCloudHttpFailure(status: Int): Nothing = throw BookExportCloudFailure(
    when (status) {
        401, 403 -> BookExportCloudMessage.AUTHORIZATION
        507 -> BookExportCloudMessage.STORAGE
        in 300..399 -> BookExportCloudMessage.REDIRECT
        else -> BookExportCloudMessage.FAILED
    },
)
