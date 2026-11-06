package io.legado.kmp.shared.network

import io.legado.kmp.shared.util.currentTimeMillis
import io.ktor.http.Url
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlin.time.Duration.Companion.seconds

@Serializable
data class SourceNetworkOptions(
    val timeoutSeconds: Int? = null,
    val retryCount: Int? = null,
    val maxConcurrent: Int? = null,
    val userAgent: String? = null,
    val proxyMode: String? = null,
    val proxy: String? = null,
) {
    override fun toString(): String = "SourceNetworkOptions(redacted)"
}

@Serializable
data class SourceCertificateGrant(
    val sourceUrl: String,
    val host: String,
    val port: Int,
    val fingerprint: String,
    val expiresAt: Long,
)

data class SourceCertificateIssue(
    val id: String,
    val sourceUrl: String,
    val host: String,
    val port: Int,
    val fingerprint: String,
    val observedAt: Long,
)

@Serializable
private data class NetworkPolicyDocument(
    val version: Int = 1,
    val defaults: SourceNetworkOptions = SourceNetworkOptions(),
    val sources: Map<String, SourceNetworkOptions> = emptyMap(),
    val certificates: List<SourceCertificateGrant> = emptyList(),
)

/** A login/upload call and all of its nested JS requests must retain system trust evaluation. */
internal object StrictSourceNetwork : AbstractCoroutineContextElement(Key) {
    object Key : CoroutineContext.Key<StrictSourceNetwork>
}

internal class SourceNetworkOrigin(val sourceUrl: String?) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<SourceNetworkOrigin>
}

internal expect fun readSourceNetworkDocument(): String?
internal expect fun updateSourceNetworkDocument(update: (String?) -> String)
internal expect fun pendingSourceCertificateIssues(): List<SourceCertificateIssue>
internal expect fun forgetSourceCertificateIssue(id: String)

/** Local network choices are separate from imported book-source definitions and backups. */
object SourceNetworkPolicy {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private const val GRANT_LIFETIME = 30L * 24 * 60 * 60 * 1000

    private fun decode(value: String?): NetworkPolicyDocument = value?.let {
        json.decodeFromString<NetworkPolicyDocument>(it).also { document ->
            require(document.version == 1) { "Unsupported source network settings version" }
        }
    } ?: NetworkPolicyDocument()

    @Throws(Exception::class)
    fun optionsJson(sourceUrl: String?): String = json.encodeToString(
        if (sourceUrl.isNullOrBlank()) decode(readSourceNetworkDocument()).defaults
        else decode(readSourceNetworkDocument()).sources[sourceUrl] ?: SourceNetworkOptions()
    )

    @Throws(Exception::class)
    fun saveOptionsJson(sourceUrl: String?, value: String) {
        val options = json.decodeFromString<SourceNetworkOptions>(value)
        validate(options)
        updateSourceNetworkDocument { existing ->
            val document = decode(existing)
            json.encodeToString(if (sourceUrl.isNullOrBlank()) document.copy(defaults = options) else {
                require(sourceUrl.length <= 4096)
                document.copy(sources = document.sources + (sourceUrl to options))
            })
        }
        SourceNetworkLimiter.settingsChanged()
    }

    @Throws(Exception::class)
    fun reset(sourceUrl: String?) {
        updateSourceNetworkDocument { existing ->
            val document = decode(existing)
            json.encodeToString(if (sourceUrl.isNullOrBlank()) document.copy(defaults = SourceNetworkOptions()) else {
                document.copy(sources = document.sources - sourceUrl,
                    certificates = document.certificates.filterNot { it.sourceUrl == sourceUrl })
            })
        }
        SourceNetworkLimiter.settingsChanged()
    }

    @Throws(Exception::class)
    fun effective(sourceUrl: String?): SourceNetworkOptions = effective(decode(readSourceNetworkDocument()), sourceUrl)

    private fun effective(document: NetworkPolicyDocument, sourceUrl: String?): SourceNetworkOptions {
        val local = document.sources[sourceUrl] ?: SourceNetworkOptions()
        val global = document.defaults
        return SourceNetworkOptions(
            local.timeoutSeconds ?: global.timeoutSeconds ?: 30,
            local.retryCount ?: global.retryCount ?: 0,
            local.maxConcurrent ?: global.maxConcurrent ?: 6,
            local.userAgent ?: global.userAgent,
            local.proxyMode ?: global.proxyMode ?: "rule",
            if (local.proxyMode != null) local.proxy else global.proxy,
        ).also(::validate)
    }

    fun retryCount(sourceUrl: String, ruleRetry: Int): Int {
        val document = decode(readSourceNetworkDocument())
        return document.sources[sourceUrl]?.retryCount ?: document.defaults.retryCount ?: ruleRetry
    }

    internal fun timeoutMillis(sourceUrl: String, ruleTimeoutMillis: Int): Int {
        val document = decode(readSourceNetworkDocument())
        val override = document.sources[sourceUrl]?.timeoutSeconds ?: document.defaults.timeoutSeconds
        return override?.times(1000) ?: ruleTimeoutMillis
    }

    fun issues(sourceUrl: String?): List<SourceCertificateIssue> = pendingSourceCertificateIssues().filter {
        (sourceUrl == null || it.sourceUrl == sourceUrl) && currentTimeMillis() - it.observedAt in 0..300_000
    }

    @Throws(Exception::class)
    fun allowCertificate(issueId: String) {
        val issue = issues(null).singleOrNull { it.id == issueId }
            ?: throw IllegalArgumentException("Certificate failure has expired; retry the original source first")
        updateSourceNetworkDocument { existing ->
            val document = decode(existing)
            val grant = SourceCertificateGrant(issue.sourceUrl, issue.host, issue.port, issue.fingerprint,
                currentTimeMillis() + GRANT_LIFETIME)
            json.encodeToString(document.copy(certificates = document.certificates.filterNot {
                it.sourceUrl == issue.sourceUrl && it.host == issue.host && it.port == issue.port
            } + grant))
        }
        forgetSourceCertificateIssue(issueId)
    }

    @Throws(Exception::class)
    fun certificateGrants(sourceUrl: String?): List<SourceCertificateGrant> = decode(readSourceNetworkDocument())
        .certificates.filter { (sourceUrl == null || it.sourceUrl == sourceUrl) && it.expiresAt > currentTimeMillis() }

    @Throws(Exception::class)
    fun revokeCertificate(sourceUrl: String, host: String, port: Int) {
        updateSourceNetworkDocument { existing ->
            val document = decode(existing)
            json.encodeToString(document.copy(certificates = document.certificates.filterNot {
                it.sourceUrl == sourceUrl && it.host == host && it.port == port
            }))
        }
    }

    internal fun permitsCertificate(sourceUrl: String, host: String, port: Int, fingerprint: String): Boolean =
        runCatching { certificateGrants(sourceUrl).any {
            it.host == host && it.port == port && it.fingerprint == fingerprint
        } }.getOrDefault(false)

    internal suspend fun apply(config: HttpRequestConfig, sourceUrl: String, ruleProxy: String?): HttpRequestConfig {
        val document = decode(readSourceNetworkDocument())
        val options = effective(document, sourceUrl)
        val timeoutOverride = document.sources[sourceUrl]?.timeoutSeconds ?: document.defaults.timeoutSeconds
        val headers = config.headers.toMutableMap()
        options.userAgent?.let { value ->
            headers.keys.filter { it.equals("User-Agent", true) }.forEach(headers::remove)
            if (value.isNotBlank()) headers["User-Agent"] = value
        }
        return config.copy(
            headers = headers,
            timeout = timeoutOverride?.seconds ?: config.timeout,
            sourceNetworkKey = sourceUrl,
            sourceNetworkProxy = resolveProxy(options, ruleProxy),
            allowSourceCertificateCompatibility = currentCoroutineContext()[StrictSourceNetwork.Key] == null &&
                config.method in setOf(HttpMethod.GET, HttpMethod.HEAD) &&
                permitsCompatibilityForRequest(config.url, headers),
        )
    }

    /** Never weaken trust for explicit account credentials, including a redirect's refreshed cookies. */
    fun permitsCompatibilityForRequest(url: String, headers: Map<String, String>): Boolean = runCatching {
        val target = Url(url)
        target.user.isNullOrEmpty() && target.password.isNullOrEmpty() && headers.none { (name, value) ->
            value.isNotBlank() && name.lowercase() in setOf("authorization", "proxy-authorization", "cookie")
        }
    }.getOrDefault(false)

    fun resolveProxy(options: SourceNetworkOptions, ruleProxy: String?): String? = when (options.proxyMode) {
        "direct" -> null
        "custom" -> options.proxy
        else -> ruleProxy
    }

    private fun validate(options: SourceNetworkOptions) {
        require(options.timeoutSeconds == null || options.timeoutSeconds in 5..300) { "Timeout must be 5 to 300 seconds" }
        require(options.retryCount == null || options.retryCount in 0..5) { "Retry count must be 0 to 5" }
        require(options.maxConcurrent == null || options.maxConcurrent in 1..32) { "Source concurrency must be 1 to 32" }
        require(options.userAgent == null || options.userAgent.length <= 2048 && options.userAgent.none { it.code < 32 || it.code == 127 }) {
            "Invalid User-Agent"
        }
        require(options.proxyMode == null || options.proxyMode in setOf("rule", "direct", "custom")) { "Invalid proxy mode" }
        if (options.proxyMode == "custom") {
            val proxy = requireNotNull(options.proxy).also { require(it.length <= 2048) }
            val parsed = parseSourceNetworkProxy(proxy)
            require(parsed.type in setOf("http", "socks5") && parsed.host.isNotBlank() && parsed.port in 1..65535) { "Invalid proxy" }
        }
    }
}
