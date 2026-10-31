package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.scripting.LegacyImageDecoder
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Acquires original image bytes and applies source decoding; callers retain cache and local-book policies. */
internal class BookImageBytes(
    private val gateway: LegacyJsConnectGateway,
    private val decoder: LegacyImageDecoder,
) {
    suspend fun fetchAndDecode(
        src: String,
        isCover: Boolean,
        baseUrl: String,
        source: BookSource? = null,
        book: Book? = null,
        chapter: BookChapter? = null,
    ): ByteArray? {
        currentCoroutineContext().ensureActive()
        val bytes = if (src.startsWith("data:", ignoreCase = true)) {
            // An invalid embedded payload must never become a network request.
            checkNotNull(AnalyzeUrl.getByteArrayIfDataUri(src)) { "Invalid image data URI" }
        } else {
            val response = gateway.executeBookResource(
                urlRule = src,
                source = source,
                baseUrl = baseUrl,
                ruleData = book?.toImageRuleVariables().orEmpty(),
                chapter = chapter,
            )
            check(response.statusCode in 200..299) { "Image request failed: ${response.statusCode}" }
            response.body
        }
        currentCoroutineContext().ensureActive()
        val decoded = decoder.decode(
            src = src,
            bytes = bytes,
            isCover = isCover,
            source = source,
            book = book,
        )
        currentCoroutineContext().ensureActive()
        return decoded
    }
}
