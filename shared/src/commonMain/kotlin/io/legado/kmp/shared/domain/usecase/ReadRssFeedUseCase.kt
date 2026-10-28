package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.analyze.RssParser
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.LegadoHttpClient

/**
 * Use case for reading RSS feeds
 */
class ReadRssFeedUseCase(
    private val httpClient: LegadoHttpClient = LegadoHttpClient()
) {
    /**
     * Read RSS feed from a source
     *
     * @param source RSS source to read
     * @param page Page number for pagination (optional)
     * @return Result containing list of RSS articles
     */
    suspend operator fun invoke(
        source: RssSource,
        page: Int = 1
    ): Result<List<RssArticle>> {
        return try {
            val url = buildRssUrl(source, page)
            val response = httpClient.get(url, emptyMap())

            if (response.isSuccessful) {
                val parser = RssParser()
                val (articles, error) = parser.parseRss(
                    content = response.bodyText,
                    origin = source.sourceUrl,
                    sortName = source.sourceName
                )

                if (error != null) {
                    Result.failure(Exception(error))
                } else {
                    Result.success(articles)
                }
            } else {
                Result.failure(Exception("HTTP request failed: ${response.statusCode}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Read RSS feed from URL
     *
     * @param url RSS feed URL
     * @param origin Origin identifier
     * @param sortName Name for sorting
     * @return Result containing list of RSS articles
     */
    suspend fun invoke(
        url: String,
        origin: String = url,
        sortName: String = ""
    ): Result<List<RssArticle>> {
        return try {
            val response = httpClient.get(url, emptyMap())

            if (response.isSuccessful) {
                val parser = RssParser()
                val (articles, error) = parser.parseRss(
                    content = response.bodyText,
                    origin = origin,
                    sortName = sortName
                )

                if (error != null) {
                    Result.failure(Exception(error))
                } else {
                    Result.success(articles)
                }
            } else {
                Result.failure(Exception("HTTP request failed: ${response.statusCode}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Build RSS URL with pagination
     */
    private fun buildRssUrl(source: RssSource, page: Int): String {
        var url = source.sourceUrl

        // Add page parameter if needed
        if (page > 1) {
            val separator = if (url.contains("?")) "&" else "?"
            url = "$url${separator}page=$page"
        }

        return url
    }
}
