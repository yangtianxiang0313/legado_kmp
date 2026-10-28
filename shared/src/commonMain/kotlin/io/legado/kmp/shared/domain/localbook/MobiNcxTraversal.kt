package io.legado.kmp.shared.domain.localbook

/** Android constructs child lists from parent IDs, then traverses roots in source order. */
internal class MobiNcxTraversal(entries: List<MobiIndexEntry>, checkActive: () -> Unit) {
    private val children = Array(entries.size) { mutableListOf<Int>() }
    private val declaredChildren = BooleanArray(entries.size)
    val order: List<Int>

    init {
        require(entries.size <= 50000) { "MOBI NCX 目录条目过多" }
        val roots = mutableListOf<Int>()
        entries.forEachIndexed { index, entry ->
            checkActive()
            declaredChildren[index] = entry.values[22]?.isNotEmpty() == true
            val parents = entry.values[21]
            if (parents == null) {
                roots.add(index)
            } else {
                require(parents.size == 1 && parents[0] in entries.indices && parents[0] != index) {
                    "MOBI NCX 父目录引用无效"
                }
                children[parents[0]].add(index)
            }
        }
        val pending = ArrayDeque<Pair<Int, Int>>()
        roots.asReversed().forEach { pending.addLast(it to 0) }
        val visited = BooleanArray(entries.size)
        val result = ArrayList<Int>(entries.size)
        while (pending.isNotEmpty()) {
            checkActive()
            val (index, depth) = pending.removeLast()
            require(depth <= 64 && !visited[index]) { "MOBI NCX 层级过深或成环" }
            visited[index] = true
            result.add(index)
            children[index].asReversed().forEach { pending.addLast(it to depth + 1) }
        }
        require(result.size == entries.size) { "MOBI NCX 存在不可达或成环的目录" }
        order = result
    }

    fun hasChildren(index: Int): Boolean = declaredChildren[index] || children[index].isNotEmpty()
}
