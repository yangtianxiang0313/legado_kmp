package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.Cookie
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.model.CookieHostSnapshot
import io.legado.kmp.shared.network.SessionCookieStore
import io.legado.kmp.shared.network.cookieDomainMatches
import io.legado.kmp.shared.network.cookieHost
import io.legado.kmp.shared.network.cookieScopeHost
import io.legado.kmp.shared.network.httpCookieUrl
import io.legado.kmp.shared.network.legacyCookieMatchesHost
import io.legado.kmp.shared.network.matchesHost
import io.legado.kmp.shared.network.matchesUrl
import io.legado.kmp.shared.network.mergeRequestCookieHeader
import io.legado.kmp.shared.network.normalizedForHost
import io.legado.kmp.shared.network.storedCookieRequestOrder
import io.legado.kmp.shared.network.shadowsSecureCookie
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class CookieRepositoryImpl(
    private val database: LegadoDatabase
) : CookieRepository {

    override suspend fun getCookiesForUrl(url: String): List<StoredHttpCookie> = withCookieLock {
        val parsed = httpCookieUrl(url) ?: return@withCookieLock emptyList()
        readJar().all().filter { it.matchesUrl(parsed) }.sortedWith(storedCookieRequestOrder)
    }

    override suspend fun getCookiesForHost(url: String): List<StoredHttpCookie> = withCookieLock {
        val host = cookieScopeHost(url) ?: return@withCookieLock emptyList()
        readJar().all().filter { it.matchesHost(host) }.sortedWith(storedCookieRequestOrder)
    }

    override suspend fun saveCookies(
        url: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean,
        persistCookies: Boolean
    ) {
        val parsed = httpCookieUrl(url) ?: return
        withCookieLock {
            val jar = readJar()
            val host = cookieHost(parsed.host)
            val normalized = cookies.mapNotNull { it.normalizedForHost(host) }
            val accepted = if (parsed.protocol.name == "https") normalized else normalized.filter { incoming ->
                // An insecure response cannot overwrite, delete or path-shadow an existing Secure cookie.
                !incoming.secure && jar.all().none { incoming.shadowsSecureCookie(it) }
            }
            mergeCookies(jar, host, accepted, persistSession, persistCookies)
            writeJar(jar)
        }
    }

    override suspend fun replaceCookiesForHost(
        url: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean,
        persistCookies: Boolean
    ) {
        val host = cookieScopeHost(url) ?: return
        withCookieLock {
            val jar = readJar()
            val previousPersistent = jar.persistent.toMap()
            val previous = jar.all().associateBy { it.key() }
            jar.persistent.entries.removeAll { it.value.matchesHost(host) }
            jar.session.entries.removeAll { it.value.matchesHost(host) }
            mergeCookies(jar, host, cookies, persistSession, persistCookies, previous, previousPersistent)
            // Opaque strings cannot be reconciled against an attributed snapshot.
            // An absent WK cookie must not revive through the compatibility channel.
            database.cacheQueries.transaction {
                deleteLegacyRows { legacyCookieMatchesHost(it, host) }
                writePersistentJar(jar)
            }
            SessionCookieStore.removeForHost(host)
            rememberJar(jar)
        }
    }

    override suspend fun requestCookieHeader(url: String): String? = withCookieLock {
        val parsed = httpCookieUrl(url) ?: return@withCookieLock null
        val host = cookieHost(parsed.host)
        val structured = readJar().all().filter { it.matchesUrl(parsed) }.sortedWith(storedCookieRequestOrder)
            .joinToString("; ") { "${it.name}=${it.value}" }.ifBlank { null }
        var header = structured
        database.cookieQueries.selectAll().executeAsList()
            .filter { legacyCookieMatchesHost(it.url, host) }
            .sortedBy { it.url.length }
            .forEach { header = mergeRequestCookieHeader(header, it.cookie) }
        mergeRequestCookieHeader(header, SessionCookieStore.getForHost(host))
    }

    override suspend fun replaceCookiesForHosts(snapshots: List<CookieHostSnapshot>, persistSession: Boolean) {
        require(snapshots.size <= 32) { "Too many browser cookie owners" }
        val byHost = snapshots.groupBy { snapshot ->
            requireNotNull(cookieScopeHost(snapshot.ownerUrl)) { "Invalid browser cookie owner" }
        }
        withCookieLock {
            val jar = readJar()
            val previous = jar.all().associateBy { it.key() }
            val hosts = byHost.keys
            jar.persistent.entries.removeAll { cookie -> hosts.any { cookie.value.matchesHost(it) } }
            jar.session.entries.removeAll { cookie -> hosts.any { cookie.value.matchesHost(it) } }
            for ((host, entries) in byHost) {
                mergeCookies(jar, host, entries.flatMap { it.cookies }, persistSession, true, previous)
            }
            database.cacheQueries.transaction {
                deleteLegacyRows { key -> hosts.any { legacyCookieMatchesHost(key, it) } }
                writePersistentJar(jar)
            }
            hosts.forEach { SessionCookieStore.removeForHost(it) }
            rememberJar(jar)
        }
    }

    override suspend fun get(url: String): Cookie? = withCookieLock {
        database.cookieQueries.selectByUrl(url).executeAsOneOrNull()?.let { Cookie.from(it.url, it.cookie) }
    }

    override suspend fun getAll(): List<Cookie> = withCookieLock {
        database.cookieQueries.selectAll().executeAsList().map { Cookie.from(it.url, it.cookie) }
    }

    override suspend fun getOkHttpCookies(): List<Cookie> = withCookieLock {
        database.cookieQueries.selectOkHttpCookies().executeAsList().map { Cookie.from(it.url, it.cookie) }
    }

    override suspend fun insert(cookie: Cookie) = withCookieLock {
        database.cookieQueries.insert(cookie.url, cookie.cookie)
    }

    override suspend fun update(cookie: Cookie) = withCookieLock {
        database.cookieQueries.update(cookie = cookie.cookie, url = cookie.url)
    }

    override suspend fun delete(url: String) {
        withCookieLock {
            val host = cookieScopeHost(url)
            val domainScope = httpCookieUrl(url) == null
            val jar = readJar()
            fun matches(cookie: StoredHttpCookie): Boolean = host != null &&
                (cookie.matchesHost(host) || (domainScope && cookieDomainMatches(cookie.domain, host)))
            jar.persistent.entries.removeAll { matches(it.value) }
            jar.session.entries.removeAll { matches(it.value) }
            database.cacheQueries.transaction {
                deleteLegacyRows { key ->
                    key == url || (host != null && (legacyCookieMatchesHost(key, host) ||
                        (domainScope && cookieScopeHost(key)?.let { cookieDomainMatches(it, host) } == true)))
                }
                writePersistentJar(jar)
            }
            if (host != null) SessionCookieStore.removeForHost(host, includeSubdomains = domainScope)
            rememberJar(jar)
        }
    }

    override suspend fun deleteOkHttp() {
        withCookieLock {
            // All channels can supply HTTP cookies; clearing only one can resurrect a login.
            database.cacheQueries.transaction {
                deleteLegacyRows { true }
                database.cacheQueries.deleteByKey(COOKIE_JAR_KEY)
            }
            CookieJarMemory.sessions.remove(database)
            SessionCookieStore.clear()
        }
    }

    private fun mergeCookies(
        jar: CookieJar,
        host: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean,
        persistCookies: Boolean,
        previous: Map<CookieKey, StoredHttpCookie> = jar.all().associateBy { it.key() },
        previousPersistent: Map<CookieKey, StoredHttpCookie> = jar.persistent.toMap(),
    ) {
        val now = currentTimeMillis()
        cookies.forEach { incoming ->
            val cookie = incoming.normalizedForHost(host) ?: return@forEach
            val key = cookie.key()
            val existing = jar.session[key] ?: jar.persistent[key] ?: previous[key]
            jar.persistent.remove(key)
            jar.session.remove(key)
            if (cookie.expiresAtMillis?.let { it <= now } == true) return@forEach
            val replacement = cookie.copy(creationTimeMillis = existing?.creationTimeMillis ?: cookie.creationTimeMillis)
            // Foundation canonicalizes SameSite casing without changing its cookie semantics.
            val unchangedPersistent = previousPersistent[key]?.let { stored ->
                stored.copy(sameSite = stored.sameSite?.lowercase()) ==
                    replacement.copy(sameSite = replacement.sameSite?.lowercase())
            } == true
            // Ordinary browser synchronization must not demote an unchanged explicitly retained login cookie.
            // New/changed values remain memory-only; deleted or replaced identities cannot revive on restart.
            if (persistCookies && (replacement.expiresAtMillis != null || persistSession) ||
                unchangedPersistent
            ) {
                jar.persistent[key] = replacement
            } else {
                jar.session[key] = replacement
            }
        }
    }

    private fun readJar(): CookieJar {
        val encoded = database.cacheQueries.selectByKey(COOKIE_JAR_KEY).executeAsOneOrNull()?.value_
        val persisted = encoded?.let {
            runCatching { cookieJson.decodeFromString<List<StoredHttpCookie>>(it) }.getOrNull()
        }.orEmpty()
        val now = currentTimeMillis()
        val jar = CookieJar(
            persistent = persisted.filter { it.expiresAtMillis?.let { expiry -> expiry <= now } != true }
                .associateByTo(LinkedHashMap()) { it.key() },
            session = CookieJarMemory.sessions[database].orEmpty()
                .filterValues { it.expiresAtMillis?.let { expiry -> expiry <= now } != true }.toMutableMap()
        )
        if (jar.persistent.size != persisted.size) writeJar(jar)
        else rememberJar(jar)
        return jar
    }

    private fun writeJar(jar: CookieJar) {
        writePersistentJar(jar)
        rememberJar(jar)
    }

    private fun writePersistentJar(jar: CookieJar) {
        if (jar.persistent.isEmpty()) {
            database.cacheQueries.deleteByKey(COOKIE_JAR_KEY)
        } else {
            database.cacheQueries.insert(
                key = COOKIE_JAR_KEY,
                value_ = cookieJson.encodeToString(jar.persistent.values.toList()),
                deadline = 0L
            )
        }
    }

    private fun rememberJar(jar: CookieJar) {
        if (jar.session.isEmpty()) CookieJarMemory.sessions.remove(database)
        else CookieJarMemory.sessions[database] = jar.session.toMap()
    }

    private fun deleteLegacyRows(matches: (String) -> Boolean) {
        database.cookieQueries.selectAll().executeAsList().filter { matches(it.url) }
            .forEach { database.cookieQueries.deleteByUrl(it.url) }
    }

    private suspend fun <T> withCookieLock(block: () -> T): T = CookieJarMemory.lock.withLock {
        currentCoroutineContext().ensureActive()
        block()
    }

    private companion object {
        const val COOKIE_JAR_KEY = "httpCookieJar_v1"
        val cookieJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}

// A common lock also covers multiple repository instances sharing the same database object.
private object CookieJarMemory {
    val lock = Mutex()
    val sessions = mutableMapOf<LegadoDatabase, Map<CookieKey, StoredHttpCookie>>()
}

private data class CookieJar(
    val persistent: MutableMap<CookieKey, StoredHttpCookie>,
    val session: MutableMap<CookieKey, StoredHttpCookie>
) {
    fun all(): List<StoredHttpCookie> = (persistent + session).values.toList()
}

// RFC cookie identity excludes hostOnly/secure, which are replaced as attributes of this tuple.
private data class CookieKey(val name: String, val domain: String, val path: String)
private fun StoredHttpCookie.key(): CookieKey = CookieKey(name, domain, path)
