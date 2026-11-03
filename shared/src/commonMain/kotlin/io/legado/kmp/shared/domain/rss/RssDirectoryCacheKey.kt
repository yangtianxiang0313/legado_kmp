package io.legado.kmp.shared.domain.rss

import okio.ByteString.Companion.encodeUtf8

internal fun rssDirectoryCachePrefix(sourceUrl: String): String =
    "rss-directory:v1:" + sourceUrl.encodeUtf8().sha256().hex() + ":"
