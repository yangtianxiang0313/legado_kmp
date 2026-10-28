package io.legado.kmp.shared.source

import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.Cache
import io.legado.kmp.shared.model.Cookie
import io.legado.kmp.shared.network.extractCookieDomain
import io.legado.kmp.shared.network.mapToCookieString
import io.legado.kmp.shared.util.currentTimeMillis
import io.legado.kmp.shared.network.mergeCookieStrings
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlin.coroutines.cancellation.CancellationException

class SourceStateStore(
    private val cacheRepository: CacheRepository,
    private val cookieRepository: CookieRepository,
    private val stateCipher: SourceStateCipher? = null
) {

    suspend fun getLoginHeader(sourceKey: String): String? {
        return cacheRepository.getValue(loginHeaderKey(sourceKey))
    }

    suspend fun getLoginHeaderMap(sourceKey: String): Map<String, String>? {
        val header = getLoginHeader(sourceKey) ?: return null
        return parseHeaderJson(header)
    }

    suspend fun putLoginHeader(sourceKey: String, header: String) {
        cacheRepository.insert(
            Cache(
                key = loginHeaderKey(sourceKey),
                value = header,
                deadline = 0L
            )
        )
        val headerMap = parseHeaderJson(header).orEmpty()
        val cookieValue = headerMap.getHeaderValue("Cookie")
        if (!cookieValue.isNullOrBlank()) {
            val cookieDomain = extractCookieDomain(sourceKey)
            val existing = cookieRepository.get(cookieDomain)?.cookie
            val merged = mergeCookieStrings(existing, cookieValue).orEmpty()
            if (merged.isNotBlank()) {
                cookieRepository.insert(Cookie(cookieDomain, merged))
            }
        }
    }

    suspend fun removeLoginHeader(sourceKey: String) {
        cacheRepository.delete(loginHeaderKey(sourceKey))
        cookieRepository.delete(extractCookieDomain(sourceKey))
    }

    suspend fun getLoginInfo(sourceKey: String): String? {
        val cipher = stateCipher ?: return null
        return loginInfoMutex.withLock {
            try {
                currentCoroutineContext().ensureActive()
                val stored = cacheRepository.get(userInfoKey(sourceKey))
                    ?.takeIf { it.isValid(currentTimeMillis()) } ?: return@withLock null
                val encoded = stored.value ?: return@withLock null
                val plainText = cipher.decrypt(encoded)
                if (cipher.needsMigration(encoded)) {
                    val replacement = cipher.encrypt(plainText)
                    check(!cipher.needsMigration(replacement) && cipher.decrypt(replacement) == plainText)
                    currentCoroutineContext().ensureActive()
                    // A restore or another process may have replaced this row while Keychain was accessed.
                    if (!cacheRepository.replaceValueIfUnchanged(stored, replacement)) return@withLock null
                }
                currentCoroutineContext().ensureActive()
                plainText
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
        }
    }

    suspend fun getLoginInfoMap(sourceKey: String): Map<String, String>? {
        val info = getLoginInfo(sourceKey) ?: return null
        return parseHeaderJson(info)
    }

    suspend fun putLoginInfo(sourceKey: String, info: String): Boolean {
        val cipher = stateCipher ?: return false
        return loginInfoMutex.withLock {
            try {
                currentCoroutineContext().ensureActive()
                val encrypted = cipher.encrypt(info)
                currentCoroutineContext().ensureActive()
                cacheRepository.insert(
                    Cache(
                        key = userInfoKey(sourceKey),
                        value = encrypted,
                        deadline = 0L
                    )
                )
                currentCoroutineContext().ensureActive()
                true
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                false
            }
        }
    }

    suspend fun removeLoginInfo(sourceKey: String) {
        loginInfoMutex.withLock {
            try {
                currentCoroutineContext().ensureActive()
                cacheRepository.delete(userInfoKey(sourceKey))
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                throw IllegalStateException("Source credential storage unavailable")
            }
        }
    }

    suspend fun getSourceVariable(sourceKey: String): String? {
        return cacheRepository.getValue(sourceVariableKey(sourceKey))
    }

    suspend fun getSourceVariableMap(sourceKey: String): Map<String, String> {
        return ruleVariableMutex.withLock {
            currentCoroutineContext().ensureActive()
            readBigVariables(RuleBigVariableScope(sourceKey)) +
                parseVariableMap(getSourceVariable(sourceKey).orEmpty())
        }
    }

    suspend fun setSourceVariable(sourceKey: String, value: String?) {
        ruleVariableMutex.withLock {
            currentCoroutineContext().ensureActive()
            // Once accepted, finish both representations before another reader/writer can proceed.
            withContext(NonCancellable) {
                val scope = RuleBigVariableScope(sourceKey)
                val entries = parseVariableMap(value.orEmpty())
                removeBigVariables(scope)
                entries.filterValues { it.length >= 10000 }.forEach { (key, item) ->
                    writeBigVariable(scope, key, item)
                }
                val small = entries.filterValues { it.length < 10000 }
                if (value == null) cacheRepository.delete(sourceVariableKey(sourceKey)) else {
                    cacheRepository.insert(Cache(
                        key = sourceVariableKey(sourceKey),
                        value = if (small.size == entries.size) value else mapToVariableString(small),
                        deadline = 0L
                    ))
                }
            }
        }
    }

    suspend fun removeSourceVariable(sourceKey: String) {
        setSourceVariable(sourceKey, null)
    }

    suspend fun putSourceVariable(sourceKey: String, key: String, value: String?) {
        ruleVariableMutex.withLock {
            currentCoroutineContext().ensureActive()
            withContext(NonCancellable) {
                val variableMap = parseVariableMap(getSourceVariable(sourceKey).orEmpty()).toMutableMap()
                if (value == null || value.length >= 10000) variableMap.remove(key) else variableMap[key] = value
                writeBigVariable(RuleBigVariableScope(sourceKey), key, value?.takeIf { it.length >= 10000 })
                cacheRepository.insert(Cache(sourceVariableKey(sourceKey), mapToVariableString(variableMap), 0L))
            }
        }
    }

    suspend fun getBigVariable(scope: RuleBigVariableScope, key: String): String? =
        ruleVariableMutex.withLock {
            currentCoroutineContext().ensureActive()
            cacheRepository.getValue(scope.key(key))
        }

    /** Each value has its own row, so concurrent chapters never replace a stale whole-map snapshot. */
    suspend fun putBigVariable(scope: RuleBigVariableScope, key: String, value: String?) {
        ruleVariableMutex.withLock {
            currentCoroutineContext().ensureActive()
            writeBigVariable(scope, key, value)
        }
    }

    suspend fun clearBigVariables(scope: RuleBigVariableScope) {
        ruleVariableMutex.withLock {
            currentCoroutineContext().ensureActive()
            removeBigVariables(scope)
        }
    }

    private suspend fun writeBigVariable(scope: RuleBigVariableScope, key: String, value: String?) {
        if (value == null) cacheRepository.delete(scope.key(key)) else {
            cacheRepository.insert(Cache(scope.key(key), value, 0L))
        }
    }

    private suspend fun readBigVariables(scope: RuleBigVariableScope): Map<String, String> = buildMap {
        cacheRepository.getByPrefix(scope.prefix).forEach { row ->
            if (row.isValid(currentTimeMillis())) {
                val key = (json.parseToJsonElement(row.key.removePrefix(scope.prefix)) as? JsonPrimitive)
                    ?.contentOrNull
                if (key != null && row.value != null) put(key, row.value)
            }
        }
    }

    private suspend fun removeBigVariables(scope: RuleBigVariableScope) {
        currentCoroutineContext().ensureActive()
        cacheRepository.deleteByPrefix(scope.prefix)
    }

    suspend fun getStoredValue(sourceKey: String, key: String): String? {
        return cacheRepository.getValue(storedValueKey(sourceKey, key))
    }

    suspend fun putStoredValue(
        sourceKey: String,
        key: String,
        value: String?,
        saveTimeSeconds: Int = 0
    ) {
        if (value == null) {
            removeStoredValue(sourceKey, key)
        } else {
            val deadline = if (saveTimeSeconds <= 0) {
                0L
            } else {
                currentTimeMillis() + saveTimeSeconds * 1000L
            }
            cacheRepository.insert(
                Cache(
                    key = storedValueKey(sourceKey, key),
                    value = value,
                    deadline = deadline
                )
            )
        }
    }

    suspend fun removeStoredValue(sourceKey: String, key: String) {
        cacheRepository.delete(storedValueKey(sourceKey, key))
    }

    suspend fun clearAllSourceState(sourceKey: String) {
        loginInfoMutex.withLock {
            try {
                currentCoroutineContext().ensureActive()
                ruleVariableMutex.withLock {
                    cacheRepository.deleteSourceVariables(sourceKey)
                    val prefix = RuleBigVariableScope.sourcePrefix(sourceKey)
                    currentCoroutineContext().ensureActive()
                    cacheRepository.deleteByPrefix(prefix)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                throw IllegalStateException("Source state storage unavailable")
            }
        }
    }

    private fun parseHeaderJson(header: String): Map<String, String>? {
        if (header.isBlank()) return null
        val (isJson, jsonMap) = parseJsonObjectMap(header)
        if (isJson) return jsonMap
        return parsePlainMap(header, preserveCookieHeaderValue = true).takeIf { it.isNotEmpty() }
    }

    private fun parseVariableMap(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        val (isJson, jsonMap) = parseJsonObjectMap(raw)
        if (isJson) return jsonMap.orEmpty()
        return parsePlainMap(raw, preserveCookieHeaderValue = false)
    }

    private fun parseJsonObjectMap(raw: String): Pair<Boolean, Map<String, String>?> {
        return runCatching {
            val root = json.parseToJsonElement(raw) as? JsonObject
                ?: return@runCatching true to null
            true to root.entries.mapNotNull { entry ->
                (entry.value as? JsonPrimitive)?.contentOrNull?.let { entry.key to it }
            }.toMap(LinkedHashMap())
        }.getOrElse {
            false to null
        }
    }

    private fun parsePlainMap(
        raw: String,
        preserveCookieHeaderValue: Boolean
    ): Map<String, String> {
        val map = LinkedHashMap<String, String>()
        raw.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .forEach { line ->
                parseColonPair(line)?.let { (key, value) ->
                    map[key] = value
                    return@forEach
                }
                if (preserveCookieHeaderValue) {
                    parseCookieEqualsHeader(line)?.let { (key, value) ->
                        map[key] = value
                        return@forEach
                    }
                }
                line.split(';').forEach { segment ->
                    parseEqualsPair(segment)?.let { (key, value) ->
                        map[key] = value
                    }
                }
            }
        return map
    }

    private fun parseColonPair(line: String): Pair<String, String>? {
        val separator = line.indexOf(':')
        if (separator <= 0) return null
        val key = line.substring(0, separator).trim()
        if (!isPlainMapKey(key)) return null
        return key to line.substring(separator + 1).trim()
    }

    private fun parseCookieEqualsHeader(line: String): Pair<String, String>? {
        val separator = line.indexOf('=')
        if (separator <= 0) return null
        val key = line.substring(0, separator).trim()
        if (!key.equals("Cookie", ignoreCase = true)) return null
        return key to line.substring(separator + 1).trim()
    }

    private fun parseEqualsPair(segment: String): Pair<String, String>? {
        val pair = segment.trim()
        val separator = pair.indexOf('=')
        if (separator <= 0) return null
        val key = pair.substring(0, separator).trim()
        if (key.isEmpty()) return null
        return key to pair.substring(separator + 1).trim()
    }

    private fun isPlainMapKey(key: String): Boolean {
        return key.isNotEmpty() && key.none { it.isWhitespace() || it == '=' }
    }

    private fun Map<String, String>.getHeaderValue(name: String): String? {
        return entries.firstOrNull { (key, _) ->
            key.equals(name, ignoreCase = true)
        }?.value
    }

    private fun mapToVariableString(variableMap: Map<String, String>): String {
        if (variableMap.isEmpty()) return ""
        return runCatching {
            JsonObject(variableMap.mapValues { (_, value) -> JsonPrimitive(value) }).toString()
        }.getOrElse {
            mapToCookieString(variableMap).orEmpty()
        }
    }

    private fun loginHeaderKey(sourceKey: String): String = "loginHeader_$sourceKey"

    private fun sourceVariableKey(sourceKey: String): String = "sourceVariable_$sourceKey"

    private fun userInfoKey(sourceKey: String): String = "userInfo_$sourceKey"

    private fun storedValueKey(sourceKey: String, key: String): String = "v_${sourceKey}_$key"

    private companion object {
        // Shared by store instances so a migration cannot overwrite a concurrent credential save/remove.
        private val loginInfoMutex = Mutex()
        private val ruleVariableMutex = Mutex()
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
    }
}
