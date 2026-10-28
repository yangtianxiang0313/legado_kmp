package io.legado.kmp.shared.facade

data class BackupRestoreResult(
    val bookCount: Int = 0,
    val bookSourceCount: Int = 0,
    val rssSourceCount: Int = 0,
    val replaceRuleCount: Int = 0,
    val bookGroupCount: Int = 0,
    val bookmarkCount: Int = 0,
    val txtTocRuleCount: Int = 0,
    val dictRuleCount: Int = 0,
    val readRecordCount: Int = 0,
    val rssStarCount: Int = 0,
    val sourceSubCount: Int = 0,
    val httpTTSCount: Int = 0,
    val keyboardAssistCount: Int = 0,
    val serverCount: Int = 0,
    val preferencesRestored: Boolean = false,
    val searchHistoryCount: Int = 0,
) {
    val totalCount: Int
        get() = bookCount + bookSourceCount + rssSourceCount + replaceRuleCount +
                bookGroupCount + bookmarkCount + txtTocRuleCount + dictRuleCount + searchHistoryCount +
                readRecordCount + rssStarCount + sourceSubCount + httpTTSCount + keyboardAssistCount + serverCount
}
