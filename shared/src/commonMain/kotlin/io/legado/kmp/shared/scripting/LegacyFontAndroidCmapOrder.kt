package io.legado.kmp.shared.scripting

/** Java HashMap<Integer, ...> iteration is bucket order, not numeric or insertion order. */
internal fun legacyAndroidCmapOrder(mappings: Map<Int, Int>): List<Int> {
    if (mappings.isEmpty()) return emptyList()
    val keys = mappings.keys.toList()
    val hashes = IntArray(keys.size) { keys[it] xor (keys[it] ushr 16) }
    val next = IntArray(keys.size) { -1 }
    var capacity = 16
    var heads = IntArray(capacity) { -1 }
    var tails = IntArray(capacity) { -1 }
    var counts = IntArray(capacity)

    fun append(index: Int) {
        val bucket = hashes[index] and (capacity - 1)
        if (heads[bucket] == -1) heads[bucket] = index else next[tails[bucket]] = index
        tails[bucket] = index
        counts[bucket]++
    }

    fun resize() {
        val oldHeads = heads
        capacity *= 2
        heads = IntArray(capacity) { -1 }
        tails = IntArray(capacity) { -1 }
        counts = IntArray(capacity)
        for (head in oldHeads) {
            var index = head
            while (index != -1) {
                val following = next[index]
                next[index] = -1
                append(index)
                index = following
            }
        }
    }

    for (index in keys.indices) {
        append(index)
        val bucket = hashes[index] and (capacity - 1)
        if (counts[bucket] >= 9) {
            // Java resizes collision-heavy small tables before treeifying. Do not silently
            // substitute insertion order for tree-bin traversal on adversarial sparse cmaps.
            fontRequire(capacity < 64, "cmap hash bucket complexity limit exceeded")
            resize()
        }
        if (index + 1 > capacity * 3 / 4) resize()
    }
    return buildList(keys.size) {
        for (head in heads) {
            var index = head
            while (index != -1) {
                add(keys[index])
                index = next[index]
            }
        }
    }
}
