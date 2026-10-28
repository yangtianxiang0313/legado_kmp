@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import io.ktor.http.Url
import io.legado.kmp.shared.network.normalizePlatformRequestUrl
import platform.Foundation.NSHTTPURLResponse

internal fun systemDownloadUrl(value: String): String {
    val text = value.trim()
    require(text.isNotEmpty() && text.length <= 16_384 && text.none { it.code < 32 || it.code == 127 }) {
        "请输入有效下载地址"
    }
    val url = runCatching { Url(normalizePlatformRequestUrl(text)) }.getOrNull()
    require(url != null && url.protocol.name in setOf("http", "https") && url.host.isNotBlank() &&
        url.user == null && url.password == null
    ) { "仅支持不含账号密码的 HTTP 或 HTTPS 下载地址" }
    return url.toString()
}

internal fun requireSystemDownloadResponse(response: NSHTTPURLResponse, size: Long) {
    require(size >= 0) { "无法读取下载文件长度" }
    val encoding = response.valueForHTTPHeaderField("Content-Encoding")
    val identity = encoding.isNullOrBlank() || encoding.equals("identity", true)
    when (response.statusCode.toInt()) {
        206 -> {
            // Foundation owns resumption and validator handling; delivery must still contain the complete file.
            val range = response.valueForHTTPHeaderField("Content-Range") ?: ""
            val match = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(range)
            val start = match?.groupValues?.get(1)?.toLongOrNull()
            val end = match?.groupValues?.get(2)?.toLongOrNull()
            val total = match?.groupValues?.get(3)?.toLongOrNull()
            require(start != null && end != null && total != null && start >= 0 && end >= start &&
                end < total && (!identity || total == size)
            ) { "分段下载未形成完整文件" }
        }
        in 200..299 -> {
            // Encoded Content-Length describes the wire body, not Foundation's decoded file.
            val length = if (identity) response.valueForHTTPHeaderField("Content-Length")?.toLongOrNull() else null
            require(length == null || length == size) { "下载文件长度与服务器声明不符" }
        }
        else -> error("服务器返回 HTTP ${response.statusCode}，文件未保存")
    }
}
