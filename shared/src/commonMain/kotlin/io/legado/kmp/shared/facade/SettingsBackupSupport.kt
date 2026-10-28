package io.legado.kmp.shared.facade

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.data.repository.restoreBackupTables
import io.legado.kmp.shared.domain.repository.*
import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** Writes restored rows through the repositories observed by the live application. */
internal class SettingsBackupSupport(
    private val preferences: AppPreferencesStore,
    private val txtRules: TxtTocRuleRepository,
    private val dictRules: DictRuleRepository?,
    private val books: BookRepository?,
    private val bookSources: BookSourceRepository?,
    private val rssSources: RssSourceRepository?,
    private val replaceRules: ReplaceRuleRepository?,
    private val groups: BookGroupRepository?,
    private val bookmarks: BookmarkRepository?,
    private val searchHistory: SearchKeywordRepository?,
    private val readRecords: ReadRecordRepository?,
    private val rssStars: RssStarRepository?,
    private val subscriptions: RuleSubRepository?,
    private val tts: HttpTTSRepository?,
    private val keyboard: KeyboardAssistRepository?,
    private val servers: ServerRepository?,
    private val database: LegadoDatabase?,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }
    private val credentialCodec = BackupCredentialCodec()

    suspend fun createBackup(password: String? = null): String = credentialCodec.encode(snapshot(), password)

    suspend fun createArchive(password: String? = null): AndroidBackupExport = try {
        currentCoroutineContext().ensureActive()
        val data = snapshot()
        currentCoroutineContext().ensureActive()
        val result = AndroidBackupArchive().exportData(data, password)
        currentCoroutineContext().ensureActive()
        result
    } catch (error: CancellationException) {
        throw error
    } catch (error: RecoverableSharedException) {
        throw error
    } catch (_: Exception) {
        throw RecoverableSharedException("ANDROID_BACKUP_EXPORT_FAILED", "Android 备份快照读取或导出失败，未修改任何数据")
    }

    private suspend fun snapshot(): BackupData = BackupData(
        bookshelf = books?.getAllBooks().orEmpty(),
        bookSource = bookSources?.getAllBookSources().orEmpty(),
        rssSource = rssSources?.getAll().orEmpty(),
        replaceRule = replaceRules?.getAllRules().orEmpty(),
        bookGroup = groups?.getAllBookGroups().orEmpty(),
        bookmark = bookmarks?.getAllBookmarks().orEmpty(),
        txtTocRule = txtRules.getAll(),
        dictRule = dictRules?.getAll().orEmpty(),
        searchHistory = searchHistory?.getAll().orEmpty(),
        readRecord = readRecords?.getAll().orEmpty(),
        rssStar = rssStars?.getAll().orEmpty(),
        sourceSub = subscriptions?.getAll().orEmpty(),
        httpTTS = tts?.getAll().orEmpty(),
        keyboardAssists = keyboard?.getAll().orEmpty(),
        servers = servers?.getAll().orEmpty(),
        preferences = preferences.exportBackupPreferences(),
    )

    suspend fun restore(payload: String, password: String? = null): BackupRestoreResult {
        val data = try {
            val original = json.parseToJsonElement(payload) as? JsonObject
                ?: error("备份必须为 JSON 对象")
            val root = credentialCodec.decode(original, password)
            val keys = setOf("bookshelf", "bookSource", "rssSource", "replaceRule", "bookGroup", "bookmark",
                "txtTocRule", "dictRule", "searchHistory", "readRecord", "rssStar", "sourceSub", "httpTTS",
                "keyboardAssists", "servers", "preferences")
            require(root.keys.any { it in keys }) { "JSON 中没有可识别的备份数据" }
            root.filterKeys { it in keys && it != "preferences" }.forEach { (field, element) ->
                validateBackupRows(field, element as? JsonArray ?: error("$field 必须是数组"))
            }
            json.decodeFromJsonElement(BackupData.serializer(), root)
        } catch (error: CancellationException) {
            throw error
        } catch (error: RecoverableSharedException) {
            throw error
        } catch (error: Exception) {
            throw RecoverableSharedException("INVALID_BACKUP_JSON", "备份 JSON 格式或数据不正确，未恢复任何数据")
        }
        return restoreMutex.withLock { restoreValidated(data) }
    }

    private suspend fun restoreValidated(data: BackupData): BackupRestoreResult {
        val ignored = preferences.runtimeConfig.first().backupRestoreIgnoredKeys
        val restoredBooks = data.bookshelf.filterNot { "localBook" in ignored && it.isLocal }
        // Validate dependencies before making any changes; never report silently dropped rows as restored.
        requireRepository(restoredBooks, books, "bookshelf")
        requireRepository(data.bookSource, bookSources, "bookSource")
        requireRepository(data.rssSource, rssSources, "rssSource")
        requireRepository(data.replaceRule, replaceRules, "replaceRule")
        requireRepository(data.bookGroup, groups, "bookGroup")
        requireRepository(data.bookmark, bookmarks, "bookmark")
        requireRepository(data.dictRule, dictRules, "dictRule")
        requireRepository(data.searchHistory, searchHistory, "searchHistory")
        requireRepository(data.readRecord, readRecords, "readRecord")
        requireRepository(data.rssStar, rssStars, "rssStar")
        requireRepository(data.sourceSub, subscriptions, "sourceSub")
        requireRepository(data.httpTTS, tts, "httpTTS")
        requireRepository(data.keyboardAssists, keyboard, "keyboardAssists")
        requireRepository(data.servers, servers, "servers")
        val rowCounts = listOf(restoredBooks.size, data.bookSource.size, data.rssSource.size, data.replaceRule.size,
            data.bookGroup.size, data.bookmark.size, data.txtTocRule.size, data.dictRule.size, data.searchHistory.size,
            data.readRecord.size, data.rssStar.size, data.sourceSub.size, data.httpTTS.size, data.keyboardAssists.size,
            data.servers.size)
        require(rowCounts.all { it <= 100_000 } && rowCounts.sumOf { it.toLong() } <= 200_000L) {
            "备份记录超过恢复上限（单表十万条，总计二十万条），未恢复任何数据"
        }
        if (rowCounts.any { it > 0 } && database == null) {
            throw RecoverableSharedException("BACKUP_DATABASE_UNAVAILABLE", "备份数据库尚未就绪，未恢复任何数据")
        }
        val context = currentCoroutineContext()
        context.ensureActive()
        // Keep the accepted commit and its settings application together even if the UI leaves afterwards.
        return withContext(NonCancellable) {
            context.ensureActive()
            val restoredReadRecords = try {
                withContext(Dispatchers.Default) {
                    database?.let { restoreBackupTables(it, data.copy(bookshelf = restoredBooks)) { context.ensureActive() } } ?: 0
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                throw RecoverableSharedException("BACKUP_DATABASE_RESTORE_FAILED", "数据库恢复失败，本次数据库写入已回滚，设置未应用")
            }
            try {
                data.preferences?.let { preferences.restoreBackupPreferences(it, ignored) }
            } catch (_: Exception) {
                // Defaults are not part of SQLite: never misreport an already committed database as untouched.
                throw RecoverableSharedException("BACKUP_PREFERENCES_RESTORE_FAILED", "数据库已恢复，但设置恢复失败，请重新应用设置")
            }
            BackupRestoreResult(
                bookCount = restoredBooks.size,
                bookSourceCount = data.bookSource.size,
                rssSourceCount = data.rssSource.size,
                replaceRuleCount = data.replaceRule.size,
                bookGroupCount = data.bookGroup.size,
                bookmarkCount = data.bookmark.size,
                txtTocRuleCount = data.txtTocRule.size,
                dictRuleCount = data.dictRule.size,
                searchHistoryCount = data.searchHistory.size,
                readRecordCount = restoredReadRecords,
                rssStarCount = data.rssStar.size,
                sourceSubCount = data.sourceSub.size,
                httpTTSCount = data.httpTTS.size,
                keyboardAssistCount = data.keyboardAssists.size,
                serverCount = data.servers.size,
                preferencesRestored = data.preferences != null,
            )
        }
    }

    private fun requireRepository(rows: List<*>, repository: Any?, key: String) {
        if (rows.isNotEmpty() && repository == null) {
            throw RecoverableSharedException("BACKUP_REPOSITORY_UNAVAILABLE", "Backup repository unavailable: $key")
        }
    }

    private companion object {
        val restoreMutex = Mutex()
    }
}
