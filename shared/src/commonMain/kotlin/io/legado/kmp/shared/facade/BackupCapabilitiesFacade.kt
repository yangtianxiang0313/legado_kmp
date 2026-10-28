package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.*
import io.legado.kmp.shared.model.*
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*

/** Uses the same repositories as backup restore; restored records are immediately available. */
class BackupCapabilitiesFacade(
    private val subscriptions: RuleSubRepository,
    private val keyboards: KeyboardAssistRepository,
    private val servers: ServerRepository,
    private val engines: HttpTTSRepository,
    private val preferences: AppPreferencesStore,
    private val sources: SourceManagementFacade,
    private val rss: RssFacade,
    private val replacements: ReplaceRuleRepository,
    private val http: HttpUseCase,
) {
    private val json = Json { ignoreUnknownKeys = true }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadSubscriptions(): List<RuleSub> = runRecoverable("BackupCapabilities.subscriptions") {
        subscriptions.getAll().sortedBy { it.customOrder }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadKeyboardAssists(): List<KeyboardAssist> = runRecoverable("BackupCapabilities.keyboards") {
        keyboards.getByType(0).sortedBy { it.serialNo }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadAllKeyboardAssists(): List<KeyboardAssist> = runRecoverable("BackupCapabilities.allKeyboards") {
        keyboards.getAll().sortedBy { it.serialNo }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadServers(): List<Server> = runRecoverable("BackupCapabilities.servers") {
        servers.getAll().sortedBy { it.sortNumber }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadSpeechEngines(): List<HttpTTS> = runRecoverable("BackupCapabilities.engines") { engines.getAll() }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveSubscription(subscription: RuleSub, isNew: Boolean): RuleSub =
        mutate("saveSubscription") {
            mutationMutex.withLock {
                if (subscription.type !in 0..2) invalid("不支持此订阅类型")
                val existing = if (isNew) null else {
                    subscriptions.get(subscription.id) ?: invalid("订阅不存在，请重新加载")
                }
                val all = subscriptions.getAll()
                if (all.any { it.url == subscription.url && (isNew || it.id != existing?.id) }) {
                    invalid("此订阅地址已存在")
                }
                val saved = if (existing == null) {
                    subscription.copy(id = unusedId(all.map { it.id }), update = currentTimeMillis())
                } else {
                    existing.copy(
                        name = subscription.name, url = subscription.url, type = subscription.type,
                        autoUpdate = subscription.autoUpdate,
                    )
                }
                subscriptions.save(saved)
                saved
            }
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteSubscription(id: Long) = mutate("deleteSubscription") {
        mutationMutex.withLock { subscriptions.delete(id) }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveServer(server: Server, isNew: Boolean): Server = mutate("saveServer") {
        mutationMutex.withLock {
            val existing = if (isNew) null else {
                servers.get(server.id) ?: invalid("服务器不存在，请重新加载")
            }
            val editedConfig = configObject(server.config)
            val originalConfig = existing?.config?.let {
                runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull()
            }
            val mergedConfig = JsonObject(originalConfig.orEmpty() + editedConfig)
            // Decode for field types only; Android permits incomplete connection settings when saving.
            try {
                json.decodeFromJsonElement(Server.WebDavConfig.serializer(), mergedConfig)
            } catch (_: Exception) {
                invalid("WebDAV 配置格式无效，请检查地址、用户名和密码字段")
            }
            val saved = if (existing == null) {
                server.copy(id = unusedId(servers.getAll().map { it.id }), config = mergedConfig.toString())
            } else {
                existing.copy(name = server.name, type = server.type, config = mergedConfig.toString())
            }
            servers.save(saved)
            saved
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteServer(id: Long) = mutate("deleteServer") {
        mutationMutex.withLock { servers.delete(id) }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveSpeechEngine(engine: HttpTTS, isNew: Boolean): HttpTTS = mutate("saveSpeechEngine") {
        mutationMutex.withLock {
            val existing = if (isNew) null else {
                engines.get(engine.id) ?: invalid("朗读引擎不存在，请重新加载")
            }
            // URL, headers and login fields are Legado rules, not necessarily literal HTTP/JSON.
            val saved = if (existing == null) {
                engine.copy(id = unusedId(engines.getAll().map { it.id }), lastUpdateTime = currentTimeMillis())
            } else {
                existing.copy(
                    name = engine.name, url = engine.url, contentType = engine.contentType,
                    concurrentRate = engine.concurrentRate, loginUrl = engine.loginUrl,
                    loginUi = engine.loginUi, header = engine.header, jsLib = engine.jsLib,
                    enabledCookieJar = engine.enabledCookieJar, loginCheckJs = engine.loginCheckJs,
                    lastUpdateTime = currentTimeMillis(),
                )
            }
            engines.save(saved)
            saved
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun importSpeechEngine(engine: HttpTTS): HttpTTS = mutate("importSpeechEngine") {
        mutationMutex.withLock {
            if (engine.name.isBlank() || engine.url.isBlank()) invalid("朗读引擎名称和请求规则不能为空")
            // Imports upsert the original identity; editor creation intentionally allocates a new one.
            engines.save(engine)
            engine
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteSpeechEngine(id: Long) = mutate("deleteSpeechEngine") {
        mutationMutex.withLock { engines.delete(id) }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveKeyboardAssist(
        assist: KeyboardAssist,
        originalType: Int,
        originalKey: String?,
        isNew: Boolean,
    ): KeyboardAssist = mutate("saveKeyboardAssist") {
        mutationMutex.withLock {
            val all = keyboards.getAll()
            val existing = if (isNew) null else {
                all.firstOrNull { it.type == originalType && it.key == originalKey }
                    ?: invalid("键盘辅助项不存在，请重新加载")
            }
            if (all.any {
                it.type == assist.type && it.key == assist.key &&
                    (isNew || it.type != originalType || it.key != originalKey)
            }) {
                invalid("此类型下的辅助按键已存在")
            }
            val saved = assist.copy(serialNo = existing?.serialNo ?: nextSerialNo(all))
            keyboards.saveReplacing(saved, originalType, if (isNew) null else originalKey)
            saved
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteKeyboardAssist(type: Int, key: String) = mutate("deleteKeyboardAssist") {
        mutationMutex.withLock { keyboards.delete(type, key) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateSubscription(id: Long): Int = runRecoverable("BackupCapabilities.updateSubscription") {
        val subscription = requireNotNull(subscriptions.get(id)) { "订阅不存在" }
        require(subscription.type in 0..2) { "不支持此订阅类型：${subscription.type}" }
        val count = when (subscription.type) {
            0 -> sources.importSourcesByUrl(subscription.url).let { it.addedCount + it.updatedCount }
            1 -> rss.importRssSources(http.getAsString(subscription.url).getOrThrow())
            else -> {
                val rules = json.decodeFromString(ListSerializer(ReplaceRule.serializer()), http.getAsString(subscription.url).getOrThrow())
                rules.forEach { replacements.save(it) }
                rules.size
            }
        }
        mutationMutex.withLock {
            val current = subscriptions.get(id)
            if (current != null && current.url == subscription.url && current.type == subscription.type) {
                subscriptions.save(current.copy(update = currentTimeMillis()))
            }
        }
        count
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSubscriptionAutoUpdate(id: Long, enabled: Boolean) = mutate("subscriptionAutoUpdate") {
        mutationMutex.withLock {
            val subscription = subscriptions.get(id) ?: invalid("订阅不存在")
            subscriptions.save(subscription.copy(autoUpdate = enabled))
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun selectServer(id: Long) = mutate("selectServer") {
        val server = servers.get(id) ?: invalid("服务器不存在")
        val config = json.decodeFromJsonElement(Server.WebDavConfig.serializer(), configObject(server.config))
        if (!config.url.startsWith("https://") && !config.url.startsWith("http://")) invalid("WebDAV 地址无效")
        preferences.setWebDavUrl(config.url)
        preferences.setWebDavAccount(config.username)
        preferences.setWebDavPassword(config.password)
        preferences.setRemoteServerId(id)
    }

    private fun configObject(config: String?): JsonObject = try {
        config?.let { json.parseToJsonElement(it) as? JsonObject }
            ?: invalid("服务器配置须为 JSON 对象")
    } catch (error: RecoverableSharedException) {
        throw error
    } catch (_: Exception) {
        invalid("服务器配置须为 JSON 对象")
    }

    private fun unusedId(existingIds: List<Long>): Long {
        val used = existingIds.toSet()
        var id = currentTimeMillis().coerceAtLeast(1)
        while (id in used) id = if (id == Long.MAX_VALUE) 1 else id + 1
        return id
    }

    private fun nextSerialNo(assists: List<KeyboardAssist>): Int {
        val maximum = assists.maxOfOrNull { it.serialNo } ?: 0
        if (maximum == Int.MAX_VALUE) invalid("辅助按键排序值已达上限")
        return maximum + 1
    }

    private fun invalid(message: String): Nothing =
        throw RecoverableSharedException("BackupCapabilities.invalidRecord", message)

    private suspend fun <T> mutate(operation: String, block: suspend () -> T): T =
        runRecoverable("BackupCapabilities.$operation") {
            try {
                block()
            } catch (error: CancellationException) {
                throw error
            } catch (error: RecoverableSharedException) {
                throw error
            } catch (_: Exception) {
                // Do not expose database or decoder errors containing connection credentials.
                throw RecoverableSharedException("BackupCapabilities.$operation", "操作失败，请检查配置后重试")
            }
        }

    private companion object {
        val mutationMutex = Mutex()
    }
}
