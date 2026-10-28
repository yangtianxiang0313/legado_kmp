package io.legado.kmp.shared.model

import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.serialization.Serializable

/** An HTTP cookie with its original scope; a null expiry denotes a session cookie. */
@Serializable
data class StoredHttpCookie(
    val name: String,
    val value: String,
    val domain: String,
    val path: String = "/",
    val hostOnly: Boolean = true,
    val secure: Boolean = false,
    val httpOnly: Boolean = false,
    val expiresAtMillis: Long? = null,
    val sameSite: String? = null,
    val creationTimeMillis: Long = currentTimeMillis()
)

/** A confirmed, isolated browser's complete cookie view for one visited host. */
data class CookieHostSnapshot(val ownerUrl: String, val cookies: List<StoredHttpCookie>)
