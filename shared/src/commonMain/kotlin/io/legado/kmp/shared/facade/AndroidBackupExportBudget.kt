package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.preferences.ReaderPreset
import io.legado.kmp.shared.preferences.ThemePreset
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.AbstractEncoder
import kotlinx.serialization.encoding.CompositeEncoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.EmptySerializersModule
import okio.utf8Size

/** Reject oversized repository snapshots before allocating their JSON strings and duplicate metadata. */
@OptIn(ExperimentalSerializationApi::class)
internal object AndroidBackupExportBudget {
    fun check(data: BackupData) {
        val budget = BudgetEncoder()
        // JsonElement's serializer needs a JsonEncoder; count preserved raw preferences separately.
        BackupData.serializer().serialize(budget, data.copy(preferences = null))
        data.preferences?.let { preferences ->
            require(preferences.appConfig.size <= 4096 && preferences.readConfig.size <= 1024 &&
                preferences.themeConfig.size <= 1024) { "备份偏好或预设数量超过上限" }
            budget.element(preferences.appConfig, 0)
            preferences.readConfig.forEach { ReaderPreset.serializer().serialize(budget, it) }
            preferences.themeConfig.forEach { ThemePreset.serializer().serialize(budget, it) }
        }
    }

    private class BudgetEncoder : AbstractEncoder() {
        override val serializersModule = EmptySerializersModule()
        private var bytes = 0L
        private var elements = 0

        private fun add(count: Long) {
            bytes += count
            require(bytes <= BackupZipWriter.MAX_ENTRY_BYTES) { "备份快照超过 64 MB 导出上限" }
        }

        override fun beginStructure(descriptor: SerialDescriptor): CompositeEncoder {
            add(2)
            return this
        }

        override fun encodeInline(descriptor: SerialDescriptor): Encoder = this

        override fun encodeElement(descriptor: SerialDescriptor, index: Int): Boolean {
            add(4 + descriptor.getElementName(index).length.toLong() * 3)
            return true
        }

        override fun shouldEncodeElementDefault(descriptor: SerialDescriptor, index: Int): Boolean = true
        override fun encodeValue(value: Any) { add(32) }
        override fun encodeNull() { add(4) }
        override fun encodeString(value: String) {
            add(value.utf8Size() + 2)
            var index = 0
            while (index < value.length) {
                val char = value[index++]
                if (char == '"' || char == '\\') add(1)
                else if (char.code < 32) add(5)
                if (char.isHighSurrogate()) {
                    require(index < value.length && value[index].isLowSurrogate()) { "备份数据包含无效 UTF-16" }
                    index++
                } else require(!char.isLowSurrogate()) { "备份数据包含无效 UTF-16" }
            }
        }

        fun element(value: JsonElement, depth: Int) {
            require(depth <= 64 && ++elements <= 200_000) { "备份偏好嵌套或元素数量超过上限" }
            when (value) {
                is JsonObject -> {
                    add(2)
                    value.forEach { (key, child) -> encodeString(key); add(2); element(child, depth + 1) }
                }
                is JsonArray -> {
                    add(2)
                    value.forEach { add(1); element(it, depth + 1) }
                }
                is JsonPrimitive -> if (value.isString) encodeString(value.content) else add(value.content.length.toLong())
            }
        }
    }
}
