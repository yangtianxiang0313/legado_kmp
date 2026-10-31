package io.legado.kmp.shared.facade

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.data.repository.restoreBackupTables
import io.legado.kmp.shared.domain.repository.*
import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.BackupPreferencesTransactionStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
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

    suspend fun createBackup(password: String? = null): String {
        val data = BackupPreferencesRestoreCoordinator.serialized(database, preferences) { snapshot() }
        return credentialCodec.encode(data, password)
    }

    suspend fun createArchive(password: String? = null): AndroidBackupExport = try {
        currentCoroutineContext().ensureActive()
        val data = BackupPreferencesRestoreCoordinator.serialized(database, preferences) { snapshot() }
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
        return BackupPreferencesRestoreCoordinator.serialized(database, preferences) { restoreValidated(data) }
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
        if ((rowCounts.any { it > 0 } || data.preferences != null) && database == null) {
            throw RecoverableSharedException("BACKUP_DATABASE_UNAVAILABLE", "备份数据库尚未就绪，未恢复任何数据")
        }
        val platform = if (data.preferences != null) {
            preferences as? BackupPreferencesTransactionStore ?: throw RecoverableSharedException(
                "BACKUP_PREFERENCES_TRANSACTION_UNAVAILABLE", "当前平台不支持设置事务，未恢复任何数据",
            )
        } else null
        val context = currentCoroutineContext()
        context.ensureActive()
        // The platform methods do not suspend while SQLite owns its transaction connection.
        return withContext(NonCancellable) {
            context.ensureActive()
            val restoredReadRecords = withContext(Dispatchers.Default) {
                val action = {
                    restoreTransaction(data.copy(bookshelf = restoredBooks), ignored, platform) { context.ensureActive() }
                }
                if (platform == null) action() else platform.withBackupPreferencesRestoreLock(action)
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

    private fun restoreTransaction(
        data: BackupData,
        ignored: Set<String>,
        platform: BackupPreferencesTransactionStore?,
        checkActive: () -> Unit,
    ): Int {
        checkActive()
        val prepared = try {
            data.preferences?.let { platform!!.prepareBackupPreferencesRestore(it, ignored) }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw RecoverableSharedException("BACKUP_PREFERENCES_PREPARATION_FAILED", "备份设置准备失败，未修改数据库或原设置")
        }
        checkActive()
        var journalId: String? = null
        var applyingPreferences = false
        try {
            if (prepared != null) journalId = BackupPreferencesRestoreCoordinator.begin(checkNotNull(database), prepared)
            val count = database?.let { db ->
                restoreBackupTables(db, data, checkActive) {
                    if (prepared != null) {
                        applyingPreferences = true
                        platform!!.applyPreparedBackupPreferencesRestore(prepared.after)
                        BackupPreferencesRestoreCoordinator.markCommitted(db, checkNotNull(journalId))
                    }
                }
            } ?: 0
            if (prepared != null) {
                platform!!.publishBackupPreferencesRestore()
                BackupPreferencesRestoreCoordinator.acknowledge(checkNotNull(database), checkNotNull(journalId))
            }
            return count
        } catch (error: Exception) {
            val outcome = BackupPreferencesRestoreCoordinator.recoverLocked(database, preferences)
            if (outcome == "COMMITTED") {
                throw RecoverableSharedException(
                    "BACKUP_RESTORE_COMMIT_CONFIRMED",
                    "恢复数据和设置已提交并完成补偿，但本次回执中断，请核对恢复结果",
                )
            }
            if (error is CancellationException) throw error
            if (journalId != null && outcome != "PREPARED") {
                throw RecoverableSharedException("BACKUP_RESTORE_STATE_UNCERTAIN", "恢复状态无法确认，请重新启动后重试")
            }
            throw RecoverableSharedException(
                if (applyingPreferences) "BACKUP_PREFERENCES_RESTORE_FAILED" else "BACKUP_DATABASE_RESTORE_FAILED",
                "备份恢复失败，本次数据库写入已回滚，原设置已保留或还原",
            )
        }
    }

    private fun requireRepository(rows: List<*>, repository: Any?, key: String) {
        if (rows.isNotEmpty() && repository == null) {
            throw RecoverableSharedException("BACKUP_REPOSITORY_UNAVAILABLE", "Backup repository unavailable: $key")
        }
    }

}
