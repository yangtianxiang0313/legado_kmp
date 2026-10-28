package io.legado.kmp.shared.preferences

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import platform.Foundation.NSUserDefaults

/** Catalog and active snapshots are mutated synchronously inside the store's write boundary. */
internal class IosReaderPresetPersistence(private val defaults: NSUserDefaults) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private var needsAnimationMaterialization = false

    var presets: List<ReaderPreset> = load()

    fun reload() {
        presets = load()
    }

    private fun load(): List<ReaderPreset> {
        val fallback = defaults.readerPresetDefaults()
        val stored = defaults.stringForKey(KEY_CUSTOM_READER_PRESETS)
        val elements = stored?.let { runCatching { json.parseToJsonElement(it).jsonArray }.getOrNull() }
        val decoded = elements?.let {
            runCatching { json.decodeFromJsonElement<List<ReaderPreset>>(it) }.getOrNull()
        }?.takeIf { it.isNotEmpty() }
        val loaded = decoded ?: fallback
        needsAnimationMaterialization = decoded == null || elements.orEmpty().any {
            val fields = it as? JsonObject
            fields?.containsKey("pageAnim") != true || fields?.containsKey("pageAnimEInk") != true
        }
        val index = defaults.integerForKey(KEY_READ_STYLE_INDEX).coerceIn(0L, loaded.lastIndex.toLong()).toInt()
        val isEInk = defaults.readerVisualVariant() == ReaderVisualVariant.E_INK
        val animationKey = if (isEInk) "pageAnimEInk" else "pageAnim"
        val hasAnimation = decoded != null && (elements?.getOrNull(index) as? JsonObject)?.containsKey(animationKey) == true
        if (hasAnimation || defaults.objectForKey(KEY_PAGE_ANIMATION) == null) return loaded
        // The flat legacy value belongs only to the selected slot's active variant, if absent there.
        val animation = defaults.integerForKey(KEY_PAGE_ANIMATION).toInt().coerceAtLeast(0)
        return loaded.toMutableList().also {
            it[index] = if (isEInk) it[index].copy(pageAnimEInk = animation) else it[index].copy(pageAnim = animation)
        }
    }

    fun persist() {
        defaults.setObject(json.encodeToString(presets), KEY_CUSTOM_READER_PRESETS)
        needsAnimationMaterialization = false
        defaults.synchronize()
    }

    fun currentIndex(): Int = defaults.integerForKey(KEY_READ_STYLE_INDEX)
        .coerceIn(0L, presets.lastIndex.toLong()).toInt()

    fun upsertWithoutSelecting(preset: ReaderPreset) {
        val index = presets.indexOfFirst { it.name == preset.name }
        if (index == currentIndex()) {
            // Android's durConfig getter reads the selected catalog slot after a same-name update.
            replace(index, preset)
            return
        }
        presets = presets.toMutableList().also {
            if (index < 0) it.add(preset) else it[index] = preset
        }
        persist()
    }

    fun mutationIndex(expectedName: String?, expectedIndex: Int?): Int {
        val rawIndex = defaults.integerForKey(KEY_READ_STYLE_INDEX)
        val selected = if (rawIndex in 0L..presets.lastIndex.toLong()) presets[rawIndex.toInt()] else null
        if (expectedIndex != null) {
            // Validate the raw selection before write() can materialize any legacy values.
            check(rawIndex == expectedIndex.toLong() && selected != null &&
                (expectedName == null || selected.name == expectedName)) {
                "Reader preset changed: expected $expectedName at $expectedIndex, current ${selected?.name} at $rawIndex"
            }
            return expectedIndex
        }
        if (selected != null && (expectedName == null || selected.name == expectedName)) return rawIndex.toInt()
        check(expectedName != null) { "Invalid reader preset selection: $rawIndex" }
        return presets.indexOfFirst { it.name == expectedName }
    }

    fun selectedMutationIndex(expectedName: String?, expectedIndex: Int?): Int {
        val rawIndex = defaults.integerForKey(KEY_READ_STYLE_INDEX)
        check(rawIndex in 0L..presets.lastIndex.toLong()) { "Invalid reader preset selection: $rawIndex" }
        return mutationIndex(expectedName, expectedIndex ?: rawIndex.toInt())
    }

    fun materializeLegacyValues() {
        if (defaults.stringForKey(KEY_CUSTOM_READER_PRESETS) != null) {
            // Freeze missing fields before selection/theme changes overwrite the compatibility mirror.
            if (needsAnimationMaterialization) persist()
            return
        }
        val index = currentIndex()
        val preset = presets[index]
        val active = defaults.readReaderActiveStyle(preset.toReaderStylePreferences())
        val merged = defaults.readerPresetWithLegacyActiveValues(preset)
        presets = presets.toMutableList().also { it[index] = merged }
        if (defaults.boolForKey(KEY_SHARE_LAYOUT) && defaults.readReaderSharedLayout() == null) {
            defaults.writeReaderSharedLayout(active)
        }
        persist()
    }

    fun persistCurrentLayout(style: ReaderStylePreferences) {
        if (defaults.boolForKey(KEY_SHARE_LAYOUT)) {
            defaults.writeReaderSharedLayout(style)
            return
        }
        val index = currentIndex()
        val current = presets[index]
        update(index, current.withReaderLayout(style))
    }

    fun activate(index: Int, previousStyle: ReaderStylePreferences, keepVisual: Boolean) {
        val nextIndex = index.coerceIn(0, presets.lastIndex)
        val preset = presets[nextIndex]
        val independentStyle = preset.styleForVariant(defaults.readerVisualVariant())
        val visualStyle = if (keepVisual) previousStyle.withSharedLayoutFrom(independentStyle) else independentStyle
        val style = if (defaults.boolForKey(KEY_SHARE_LAYOUT)) {
            val shared = defaults.readReaderSharedLayout() ?: previousStyle
            defaults.writeReaderSharedLayout(shared)
            visualStyle.withSharedLayoutFrom(shared)
        } else {
            visualStyle
        }
        defaults.setInteger(nextIndex.toLong(), KEY_READ_STYLE_INDEX)
        defaults.writeReaderStyleSnapshot(preset.name, style)
        writeActivePageAnimation()
    }

    fun updateVisual(index: Int, style: ReaderStylePreferences, variant: ReaderVisualVariant) {
        update(index, presets[index].withReaderStyle(style, defaults.boolForKey(KEY_SHARE_LAYOUT), variant))
    }

    fun rename(index: Int, newName: String) {
        update(index, presets[index].copy(name = newName))
        if (defaults.integerForKey(KEY_READ_STYLE_INDEX) == index.toLong()) {
            defaults.setObject(newName, KEY_READER_PRESET)
        }
    }

    fun delete(index: Int, previousStyle: ReaderStylePreferences) {
        if (presets.size <= 5) return
        val readIndex = defaults.integerForKey(KEY_READ_STYLE_INDEX)
        val comicIndex = defaults.integerForKey(KEY_COMIC_STYLE_INDEX)
        presets = presets.toMutableList().also { it.removeAt(index) }
        persist()
        // ReadBookConfig.deleteDur adjusts both independent selections, including equality.
        fun adjusted(selection: Long): Int =
            (if (index.toLong() <= selection) selection - 1 else selection)
                .coerceIn(0L, presets.lastIndex.toLong()).toInt()
        defaults.setInteger(adjusted(comicIndex).toLong(), KEY_COMIC_STYLE_INDEX)
        activate(adjusted(readIndex), previousStyle, keepVisual = false)
    }

    fun replace(index: Int, replacement: ReaderPreset) {
        // Never preserve the outgoing active layout after installing a full replacement.
        presets = presets.toMutableList().also { it[index] = replacement }
        persist()
        if (defaults.integerForKey(KEY_READ_STYLE_INDEX) != index.toLong()) return
        val style = replacement.styleForVariant(defaults.readerVisualVariant())
        if (defaults.boolForKey(KEY_SHARE_LAYOUT)) defaults.writeReaderSharedLayout(style)
        defaults.writeReaderStyleSnapshot(replacement.name, style)
        writeActivePageAnimation()
    }

    fun setCurrentPageAnimation(value: Int) {
        val animation = value.coerceAtLeast(0)
        val index = currentIndex()
        val current = presets[index]
        val updated = if (defaults.readerVisualVariant() == ReaderVisualVariant.E_INK) {
            current.copy(pageAnimEInk = animation)
        } else {
            current.copy(pageAnim = animation)
        }
        update(index, updated)
        writeActivePageAnimation()
    }

    fun currentPageAnimation(): Int {
        val preset = presets[currentIndex()]
        val animation = if (defaults.readerVisualVariant() == ReaderVisualVariant.E_INK) {
            preset.pageAnimEInk
        } else {
            preset.pageAnim
        }
        return animation.coerceAtLeast(0)
    }

    fun writeActivePageAnimation() {
        // Compatibility mirror only; preset fields remain the source of truth.
        defaults.setInteger(currentPageAnimation().toLong(), KEY_PAGE_ANIMATION)
    }

    fun presetForExport(name: String, activeStyle: ReaderStylePreferences): ReaderPreset? {
        val selectedIndex = currentIndex()
        val index = if (presets[selectedIndex].name == name) selectedIndex else presets.indexOfFirst { it.name == name }
        val stored = presets.getOrNull(index) ?: return null
        val preset = if (index == selectedIndex) defaults.readerPresetWithLegacyActiveValues(stored) else stored
        return when {
            defaults.boolForKey(KEY_SHARE_LAYOUT) -> preset.withReaderLayout(defaults.readReaderSharedLayout() ?: activeStyle)
            index == selectedIndex -> preset.withReaderLayout(activeStyle)
            else -> preset
        }
    }

    private fun update(index: Int, preset: ReaderPreset) {
        if (presets[index] == preset) return
        presets = presets.toMutableList().also { it[index] = preset }
        persist()
    }

    private companion object {
        private const val KEY_CUSTOM_READER_PRESETS = "custom_reader_presets"
        private const val KEY_READ_STYLE_INDEX = "read_style_index"
        private const val KEY_COMIC_STYLE_INDEX = "comic_style_index"
        private const val KEY_READER_PRESET = "reader_preset_name"
        private const val KEY_SHARE_LAYOUT = "share_layout"
        private const val KEY_PAGE_ANIMATION = "page_animation"
    }
}
