package io.legado.kmp.shared.data.database

import app.cash.sqldelight.db.SqlDriver

/**
 * Main database class for Legado KMP
 * Wraps the generated SQLDelight database
 *
 * Note: Using the generated invoke function directly
 */
class LegadoDatabase(private val driver: SqlDriver) {
    // Use the generated database's invoke function
    private val database = io.legado.kmp.`data`.database.LegadoDatabase(driver)

    // Expose DAOs
    val bookChapterQueries = database.bookChapterQueries
    val bookChapterReviewQueries = database.bookChapterReviewQueries
    val bookQueries = database.bookQueries
    val bookSourceQueries = database.bookSourceQueries
    val bookGroupQueries = database.bookGroupQueries
    val bookmarkQueries = database.bookmarkQueries
    val cacheQueries = database.cacheQueries
    val cookieQueries = database.cookieQueries
    val readRecordQueries = database.readRecordQueries
    val replaceRuleQueries = database.replaceRuleQueries
    val rssArticleQueries = database.rssArticleQueries
    val rssReadRecordQueries = database.rssReadRecordQueries
    val rssSourceQueries = database.rssSourceQueries
    val rssStarQueries = database.rssStarQueries
    val searchBookQueries = database.searchBookQueries
    val searchKeywordQueries = database.searchKeywordQueries
    val dictRuleQueries = database.dictRuleQueries
    val httpTTSQueries = database.httpTTSQueries
    val keyboardAssistQueries = database.keyboardAssistQueries
    val ruleSubQueries = database.ruleSubQueries
    val serverQueries = database.serverQueries
    val txtTocRuleQueries = database.txtTocRuleQueries

    /**
     * Execute VACUUM to compact the database file and reclaim unused space.
     */
    fun vacuum() {
        driver.execute(null, "VACUUM", 0)
    }

    companion object {
        const val DATABASE_NAME = "legado.db"

        /**
         * Get the SQL schema for database creation
         */
        val Schema = io.legado.kmp.`data`.database.LegadoDatabase.Schema
    }
}
