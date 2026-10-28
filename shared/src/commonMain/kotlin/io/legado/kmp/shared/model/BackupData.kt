package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable
import io.legado.kmp.shared.preferences.PreferencesBackupData

/**
 * Container for full app backup data.
 * Each field corresponds to one database table that is backed up.
 */
@Serializable
data class BackupData(
    val bookshelf: List<Book> = emptyList(),
    val bookSource: List<BookSource> = emptyList(),
    val rssSource: List<RssSource> = emptyList(),
    val replaceRule: List<ReplaceRule> = emptyList(),
    val bookGroup: List<BookGroup> = emptyList(),
    val bookmark: List<Bookmark> = emptyList(),
    val txtTocRule: List<TxtTocRule> = emptyList(),
    val dictRule: List<DictRule> = emptyList(),
    val readRecord: List<ReadRecord> = emptyList(),
    val rssStar: List<RssStar> = emptyList(),
    val sourceSub: List<RuleSub> = emptyList(),
    val httpTTS: List<HttpTTS> = emptyList(),
    val keyboardAssists: List<KeyboardAssist> = emptyList(),
    val servers: List<Server> = emptyList(),
    val preferences: PreferencesBackupData? = null,
    val searchHistory: List<SearchKeyword> = emptyList(),
)
