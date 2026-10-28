package io.legado.kmp.shared.bootstrap

import kotlinx.serialization.Serializable

class SharedRuntimeBootstrapException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

@Serializable
data class SharedRuntimeHealth(
    val started: Boolean,
    val status: String,
)
