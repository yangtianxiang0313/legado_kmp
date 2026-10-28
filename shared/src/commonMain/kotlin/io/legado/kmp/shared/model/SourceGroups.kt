package io.legado.kmp.shared.model

internal object SourceGroups {
    private val splitRegex = Regex("[,;，；]+")

    fun split(groups: String?): List<String> {
        return groups
            ?.split(splitRegex)
            ?.map(String::trim)
            ?.filter(String::isNotEmpty)
            .orEmpty()
    }

    fun contains(groups: String?, group: String): Boolean {
        val normalized = group.trim()
        return normalized.isNotEmpty() && split(groups).any { it == normalized }
    }

    fun normalize(groups: String?): String? {
        val normalized = linkedSetOf<String>()
        split(groups).forEach(normalized::add)
        return normalized.takeIf { it.isNotEmpty() }?.joinToString(",")
    }

    fun add(current: String?, groups: String): String? {
        val merged = linkedSetOf<String>()
        split(current).forEach(merged::add)
        split(groups).forEach(merged::add)
        return merged.takeIf { it.isNotEmpty() }?.joinToString(",")
    }

    fun remove(current: String?, groups: String): String? {
        val merged = split(current).toMutableSet()
        merged.removeAll(split(groups).toSet())
        return merged.takeIf { it.isNotEmpty() }?.joinToString(",")
    }
}
