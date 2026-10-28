package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

/** Portable, password-protected credentials alongside the ordinary JSON backup tables. */
class BackupCredentialCodec {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }

    /** Call before presenting JSON restore; Android ZIPs still use AndroidBackupArchive. */
    @Throws(RecoverableSharedException::class)
    fun requiresPassword(payload: String): Boolean {
        val root = try {
            json.parseToJsonElement(payload) as? JsonObject ?: error("Expected a JSON object")
        } catch (_: Exception) {
            throw RecoverableSharedException("INVALID_BACKUP_JSON", "备份必须为有效的 JSON 对象")
        }
        return FORMAT_KEY in root || CREDENTIALS_KEY in root
    }

    internal fun encode(data: BackupData, password: String?): String {
        val root = json.encodeToJsonElement(BackupData.serializer(), data).jsonObject.toMutableMap()
        val appConfig = data.preferences?.appConfig ?: JsonObject(emptyMap())
        val credentials = appConfig.filterKeys { it in credentialKeys }
        val hasCredentials = data.servers.isNotEmpty() || credentials.values.any {
            it !is JsonNull && (it !is JsonPrimitive || it.content.isNotEmpty())
        }
        if (!hasCredentials) return json.encodeToString(JsonObject.serializer(), JsonObject(root))
        val secret = requirePassword(password)
        requireCredentialValues(JsonObject(credentials))
        val protected = buildJsonObject {
            put("format", FORMAT)
            put("servers", root.getValue("servers"))
            put("appConfig", JsonObject(credentials))
        }
        val cipher = try {
            AndroidBackupCipher.encrypt(protected.toString(), secret)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // Never use Android Backup.kt's plaintext fallback when encryption fails.
            throw RecoverableSharedException("BACKUP_ENCRYPTION_FAILED", "凭据加密失败，未导出备份")
        }
        root[FORMAT_KEY] = JsonPrimitive(FORMAT)
        root["servers"] = JsonArray(emptyList())
        data.preferences?.let {
            root["preferences"] = json.encodeToJsonElement(
                it.copy(appConfig = JsonObject(appConfig.filterKeys { key -> key !in credentialKeys })),
            )
        }
        root[CREDENTIALS_KEY] = buildJsonObject {
            put("version", VERSION)
            put("cipher", AndroidBackupCipher.CONTRACT)
            put("payload", cipher)
        }
        return json.encodeToString(JsonObject.serializer(), JsonObject(root))
    }

    internal fun decode(root: JsonObject, password: String?): JsonObject {
        if (FORMAT_KEY !in root && CREDENTIALS_KEY !in root) return root
        val envelope = root[CREDENTIALS_KEY] as? JsonObject
            ?: invalidProtectedBackup()
        if (root[FORMAT_KEY] != JsonPrimitive(FORMAT) ||
            envelope["version"] != JsonPrimitive(VERSION) ||
            envelope["cipher"] != JsonPrimitive(AndroidBackupCipher.CONTRACT)) {
            throw RecoverableSharedException("UNSUPPORTED_BACKUP_ENCRYPTION", "备份的凭据加密版本不受支持")
        }
        val cipher = envelope["payload"] as? JsonPrimitive ?: invalidProtectedBackup()
        if (!cipher.isString || cipher.content.isBlank()) invalidProtectedBackup()
        val secret = requirePassword(password)
        val protected = try {
            val plain = AndroidBackupCipher.decrypt(cipher.content, secret)
            val decoded = json.parseToJsonElement(plain) as? JsonObject ?: error("Invalid credentials")
            require(decoded["format"] == JsonPrimitive(FORMAT))
            require(decoded.keys == setOf("format", "servers", "appConfig"))
            val rows = decoded["servers"] as? JsonArray ?: error("Invalid servers")
            validateBackupRows("servers", rows)
            val config = decoded["appConfig"] as? JsonObject ?: error("Invalid preferences")
            requireCredentialValues(config)
            decoded
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw RecoverableSharedException("BACKUP_DECRYPTION_FAILED", "备份密码不正确或凭据数据已损坏，未恢复任何数据")
        }
        // Reject mixed plaintext/encrypted credentials rather than choosing one silently.
        val plainServers = root["servers"]
        if (plainServers != null && (plainServers !is JsonArray || plainServers.isNotEmpty())) {
            invalidProtectedBackup()
        }
        val restored = root.toMutableMap()
        val config = protected.getValue("appConfig").jsonObject
        val preferenceElement = root["preferences"]
        val preferences = when (preferenceElement) {
            null, JsonNull -> null
            is JsonObject -> preferenceElement
            else -> invalidProtectedBackup()
        }
        if (preferences == null && config.isNotEmpty()) invalidProtectedBackup()
        preferences?.let {
            val appConfig = it["appConfig"] as? JsonObject ?: invalidProtectedBackup()
            if (appConfig.keys.any { key -> key in credentialKeys }) invalidProtectedBackup()
            restored["preferences"] = JsonObject(it + ("appConfig" to JsonObject(appConfig + config)))
        }
        restored["servers"] = protected.getValue("servers")
        restored.remove(FORMAT_KEY)
        restored.remove(CREDENTIALS_KEY)
        return JsonObject(restored)
    }

    private fun requirePassword(password: String?): String = password?.takeIf { it.isNotBlank() }
        ?: throw RecoverableSharedException("BACKUP_PASSWORD_REQUIRED", "请提供非空备份密码；跨设备恢复时需要使用同一密码")

    private fun requireCredentialValues(config: JsonObject) {
        require(config.keys.all { it in credentialKeys }) { "Invalid credential preference" }
        require(config.all { (key, value) ->
            key == "android.directLinkUploadRule.json" || value is JsonNull || (value is JsonPrimitive && value.isString)
        }) { "Invalid credential value" }
    }

    private fun invalidProtectedBackup(): Nothing = throw RecoverableSharedException(
        "INVALID_BACKUP_ENCRYPTION", "备份的加密凭据结构不正确，未恢复任何数据",
    )

    private companion object {
        const val FORMAT_KEY = "backupFormat"
        const val CREDENTIALS_KEY = "encryptedCredentials"
        const val FORMAT = "legado-kmp-credentials-v1"
        const val VERSION = 1
        // Android aliases are preserved in raw preferences, so both copies must leave plaintext.
        val credentialKeys = setOf("web_dav_password", "webDavPassword", "android.directLinkUploadRule.json")
    }
}
