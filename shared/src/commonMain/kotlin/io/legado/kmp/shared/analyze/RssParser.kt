package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.model.RssArticle

/**
 * RSS Parser
 * Parses RSS/Atom feeds into RssArticle objects
 *
 * Simplified KMP implementation without Android XML Pull Parser
 */
class RssParser {

    /**
     * Parse RSS feed content
     *
     * @param content RSS XML content
     * @param origin Source URL of the RSS feed
     * @param sortName Name/sort for the articles
     * @return Pair of article list and optional error message
     */
    fun parseRss(
        content: String,
        origin: String,
        sortName: String
    ): Pair<List<RssArticle>, String?> {
        val articles = mutableListOf<RssArticle>()

        try {
            // Check if content is JSON (some RSS sources return JSON)
            if (content.trim().startsWith("{")) {
                return parseJsonFeed(content, origin, sortName)
            }

            // Parse XML-based RSS
            // For KMP, we'll use regex-based parsing (simplified)
            // A production version should use a proper XML parser

            // Find all <item> blocks
            val itemPattern = Regex("<item[^>]*>([\\s\\S]*?)</item>")
            val itemMatches = itemPattern.findAll(content)

            for (match in itemMatches) {
                val itemContent = match.groupValues[1]
                val article = parseRssItem(itemContent, origin, sortName)
                if (article.title.isNotEmpty() || article.link.isNotEmpty()) {
                    articles.add(article)
                }
            }
        } catch (e: Exception) {
            return Pair(articles, "Parse error: ${e.message}")
        }

        return Pair(articles, null)
    }

    /**
     * Parse a single RSS item
     */
    private fun parseRssItem(
        itemContent: String,
        origin: String,
        sortName: String
    ): RssArticle {
        // Build article with all extracted data
        var title = ""
        var link = ""
        var description: String? = null
        var content: String? = null
        var pubDate: String? = null
        var image: String? = null

        // Extract title
        extractTag(itemContent, "title")?.let {
            title = it.stripHtml().trim()
        }

        // Extract link
        extractTag(itemContent, "link")?.let {
            link = it.trim()
        }

        // Extract description
        extractTag(itemContent, "description")?.let {
            description = it.stripHtml().trim()
            content = description
        }

        // Extract content:encoded
        extractTag(itemContent, "content:encoded")?.let {
            content = it.stripHtml().trim()
        }

        // Extract pubDate
        extractTag(itemContent, "pubDate")?.let {
            pubDate = it.trim()
        }

        // Extract image from media:thumbnail
        extractAttribute(itemContent, "media:thumbnail", "url")?.let {
            image = it
        }

        // Extract image from enclosure
        extractEnclosureImage(itemContent)?.let {
            image = it
        }

        // Extract image from description content
        if (image == null) {
            description?.let { desc ->
                extractImageUrl(desc)?.let { image = it }
            }
        }

        return RssArticle(
            origin = origin,
            sort = sortName,
            title = title,
            link = link,
            description = description,
            content = content,
            pubDate = pubDate,
            image = image
        )
    }

    /**
     * Parse JSON feed (JSON Feed format)
     */
    private fun parseJsonFeed(
        content: String,
        origin: String,
        sortName: String
    ): Pair<List<RssArticle>, String?> {
        val articles = mutableListOf<RssArticle>()

        try {
            // For JSON feeds, we would need to parse JSON properly
            // For now, return empty list as this is a simplified implementation
        } catch (e: Exception) {
            return Pair(articles, "JSON parse error: ${e.message}")
        }

        return Pair(articles, null)
    }

    /**
     * Extract tag content from XML
     */
    private fun extractTag(
        content: String,
        tagName: String
    ): String? {
        val pattern = Regex("<$tagName[^>]*>([\\s\\S]*?)</$tagName>")
        val match = pattern.find(content)
        return match?.groupValues?.get(1)
    }

    /**
     * Extract attribute from XML tag
     */
    private fun extractAttribute(
        content: String,
        tagName: String,
        attributeName: String
    ): String? {
        val pattern = Regex("<$tagName[^>]*$attributeName\\s*=\\s*[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
        val match = pattern.find(content)
        return match?.groupValues?.get(1)
    }

    /**
     * Extract image from enclosure tag
     */
    private fun extractEnclosureImage(content: String): String? {
        val pattern = Regex("<enclosure[^>]*type\\s*=\\s*[\"']image/[^\"']+['\"][^>]*url\\s*=\\s*[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
        val match = pattern.find(content)
        if (match != null) {
            return match.groupValues[1]
        }

        // Try alternative format
        val pattern2 = Regex("<enclosure[^>]*url\\s*=\\s*[\"']([^\"']+)[\"'][^>]*type\\s*=\\s*[\"']image/", RegexOption.IGNORE_CASE)
        val match2 = pattern2.find(content)
        return match2?.groupValues?.get(1)
    }

    /**
     * Extract image URL from HTML content
     */
    private fun extractImageUrl(html: String): String? {
        val imgPattern = Regex("<img[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
        val match = imgPattern.find(html)
        return match?.groupValues?.get(1)
    }

    /**
     * Strip HTML tags from string
     */
    private fun String.stripHtml(): String {
        return this.replace(Regex("<[^>]+>"), "")
            .replace(Regex("&\\w+;"), "")
            .trim()
    }

    companion object {
        /**
         * Parse RSS content
         */
        fun parse(content: String, origin: String, sortName: String = ""): List<RssArticle> {
            return RssParser().parseRss(content, origin, sortName).first
        }
    }
}
