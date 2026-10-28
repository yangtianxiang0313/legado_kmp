package io.legado.kmp.shared.network

/** PSL prevailing-rule algorithm, including PRIVATE domains, wildcard rules and exceptions. */
internal object CookiePublicSuffixes {
    private val rules: Set<String> by lazy { CookiePublicSuffixData.loadRules() }

    fun registrableDomain(host: String): String? {
        if (host.any { it.code > 127 }) return null
        val labels = host.lowercase().split('.')
        if (labels.any { it.isEmpty() }) return null
        var publicSuffixLabels = 1 // The PSL's implicit default rule is "*".
        for (index in labels.indices) {
            val suffix = labels.subList(index, labels.size).joinToString(".")
            if ("!$suffix" in rules) {
                // An exception's leftmost label is registrable, not part of its public suffix.
                publicSuffixLabels = labels.size - index - 1
                break
            }
            if (suffix in rules) publicSuffixLabels = maxOf(publicSuffixLabels, labels.size - index)
            if (index < labels.lastIndex) {
                val wildcard = "*." + labels.subList(index + 1, labels.size).joinToString(".")
                if (wildcard in rules) publicSuffixLabels = maxOf(publicSuffixLabels, labels.size - index)
            }
        }
        if (labels.size <= publicSuffixLabels) return null
        return labels.takeLast(publicSuffixLabels + 1).joinToString(".")
    }
}
