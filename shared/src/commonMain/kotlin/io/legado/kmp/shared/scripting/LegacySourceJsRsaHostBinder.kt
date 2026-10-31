package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** RSA material stays in this execution; only validated DER bytes cross the host boundary. */
internal suspend fun QuickJs.bindLegacyJavaRsaHost(json: Json) {
    function("__legacyJavaRsaKey") { args ->
        require(args.size == 2) { "Unsupported Java RSA key arguments" }
        json.encodeToString(LegacyJavaRsaSupport.key(rsaString(args[0]), rsaString(args[1])))
    }
    function("__legacyJavaRsaCipher") { args ->
        require(args.size == 4) { "Unsupported Java RSA cipher arguments" }
        val mode = when ((args[0] as? Number)?.toDouble()) {
            1.0 -> 1
            2.0 -> 2
            else -> throw IllegalArgumentException("Unsupported Java RSA cipher mode")
        }
        LegacyJavaRsaSupport.cipher(mode, rsaString(args[1]), rsaString(args[2]), rsaString(args[3]))
    }
    function("__legacyJavaRsaSign") { args ->
        require(args.size == 3) { "Unsupported Java RSA sign arguments" }
        LegacyJavaRsaSupport.sign(rsaString(args[0]), rsaString(args[1]), rsaString(args[2]))
    }
    function("__legacyJavaRsaVerify") { args ->
        require(args.size == 5) { "Unsupported Java RSA verify arguments" }
        LegacyJavaRsaSupport.verify(
            rsaString(args[0]), rsaString(args[1]), rsaString(args[2]), rsaString(args[3]), rsaString(args[4]),
        )
    }
}

private fun rsaString(value: Any?): String = value as? String
    ?: throw IllegalArgumentException("Expected a Java RSA string argument")
