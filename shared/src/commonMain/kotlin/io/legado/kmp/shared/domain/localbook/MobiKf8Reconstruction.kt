package io.legado.kmp.shared.domain.localbook

internal data class MobiKf8Part(val start: Int, val end: Int)

internal data class MobiKf8Rebuilt(
    val text: ByteArray,
    val parts: List<MobiKf8Part>,
    val positions: MobiKf8Positions,
)

/** Maps original fragment byte offsets through all subsequent insertions and splits. */
internal class MobiKf8Positions(fragmentLengths: Map<Int, Int>, private val checkActive: () -> Unit) {
    private val fragments = fragmentLengths.mapValues {
        checkActive()
        MobiKf8PositionEntry(it.value)
    }

    fun add(fid: Int, fragmentOffset: Int, outputOffset: Int, length: Int) {
        val entry = checkNotNull(fragments[fid])
        val previousEnd = entry.spans.lastOrNull()?.let { it.fragmentOffset + it.length } ?: 0
        require(fragmentOffset == previousEnd && length > 0 && length <= entry.length - fragmentOffset) {
            "KF8 片段位置映射不连续"
        }
        entry.spans.add(MobiKf8PositionSpan(fragmentOffset, outputOffset, length))
    }

    fun requireComplete() {
        fragments.values.forEach { entry ->
            checkActive()
            val last = entry.spans.lastOrNull()
            require(last != null && last.fragmentOffset + last.length == entry.length) {
                "KF8 片段位置映射不完整"
            }
        }
    }

    fun resolve(fid: Int, offset: Int): Int {
        val entry = fragments[fid] ?: throw IllegalArgumentException("KF8 NCX 引用了不存在的 fid：$fid")
        require(offset in 0..entry.length) { "KF8 NCX off 超过片段范围" }
        if (offset == entry.length) {
            val last = entry.spans.last()
            return last.outputOffset + last.length
        }
        var low = 0
        var high = entry.spans.lastIndex
        while (low <= high) {
            val mid = low + (high - low) / 2
            val span = entry.spans[mid]
            when {
                offset < span.fragmentOffset -> high = mid - 1
                offset >= span.fragmentOffset + span.length -> low = mid + 1
                else -> return span.outputOffset + offset - span.fragmentOffset
            }
        }
        throw IllegalArgumentException("KF8 NCX 位置未映射到正文")
    }
}

private data class MobiKf8PositionEntry(
    val length: Int,
    val spans: MutableList<MobiKf8PositionSpan> = mutableListOf(),
)

private data class MobiKf8PositionSpan(val fragmentOffset: Int, val outputOffset: Int, val length: Int)

internal class MobiKf8Reconstructor(
    private val rawText: ByteArray,
    private val encoding: MobiTextEncoding,
    private val checkActive: () -> Unit,
) {
    fun rebuild(
        mainStart: Int,
        mainEnd: Int,
        skelData: MobiIndexData,
        fragData: MobiIndexData,
    ): MobiKf8Rebuilt {
        require(mainStart >= 0 && mainEnd > mainStart && mainEnd <= rawText.size) { "KF8 主流范围无效" }
        require(skelData.entries.isNotEmpty() && skelData.entries.size <= MAX_STRUCTURAL_ENTRIES &&
            fragData.entries.size <= MAX_STRUCTURAL_ENTRIES) { "KF8 骨架或片段数量无效" }
        val fragments = readFragments(fragData)
        val plans = readPlans(skelData, fragments, mainStart, mainEnd)
        val totalLength = plans.sumOf { it.sourceEnd.toLong() - it.skeleton.offset }
        require(totalLength in 1..MAX_TEXT_BYTES.toLong()) { "KF8 重建正文超过限制" }
        val output = ByteArray(totalLength.toInt())
        val positions = MobiKf8Positions(fragments.associate { it.fid to it.length }, checkActive)
        val parts = ArrayList<MobiKf8Part>(plans.size)
        var outputOffset = 0
        for (plan in plans) {
            checkActive()
            val skeleton = plan.skeleton
            val rope = MobiKf8ByteRope(MobiKf8Piece(skeleton.offset, skeleton.length))
            for (fragment in plan.fragments) {
                checkActive()
                val insertion = fragment.insertOffset.toLong() - skeleton.offset
                require(insertion in 0..rope.length.toLong()) { "KF8 FRAG 插入位置超出当前骨架" }
                val at = insertion.toInt()
                require(at == rope.length || encoding.isBoundary(rawText, rope.sourceOffset(at))) {
                    "KF8 FRAG 插入位置落在多字节字符中间"
                }
                val sourceStart = skeleton.offset + skeleton.length + fragment.offset
                rope.insert(at, MobiKf8Piece(sourceStart, fragment.length, fragment.fid))
            }
            require(rope.length == plan.sourceEnd - skeleton.offset) { "KF8 骨架重建长度不一致" }
            val partStart = outputOffset
            rope.forEach { piece ->
                checkActive()
                piece.fid?.let { positions.add(it, piece.fragmentOffset, outputOffset, piece.length) }
                var copied = 0
                while (copied < piece.length) {
                    checkActive()
                    val count = minOf(64 * 1024, piece.length - copied)
                    rawText.copyInto(output, outputOffset, piece.sourceStart + copied, piece.sourceStart + copied + count)
                    copied += count
                    outputOffset += count
                }
            }
            parts.add(MobiKf8Part(partStart, outputOffset))
        }
        require(outputOffset == output.size) { "KF8 重建正文长度不一致" }
        positions.requireComplete()
        return MobiKf8Rebuilt(output, parts, positions)
    }

    private fun readFragments(data: MobiIndexData): List<MobiKf8Fragment> {
        val seen = HashSet<Int>()
        return data.entries.map { entry ->
            checkActive()
            val insertOffset = decimalOffset(entry.label)
            val selector = entry.requiredValues(2, 1)[0]
            require(data.strings.containsKey(selector)) { "KF8 FRAG selector 引用不存在" }
            val fid = entry.requiredValues(4, 1)[0]
            require(seen.add(fid)) { "KF8 FRAG fid 重复" }
            val range = entry.requiredValues(6, 2)
            require(range[1] > 0) { "KF8 FRAG 片段为空" }
            MobiKf8Fragment(insertOffset, fid, range[0], range[1])
        }
    }

    private fun readPlans(
        data: MobiIndexData,
        fragments: List<MobiKf8Fragment>,
        mainStart: Int,
        mainEnd: Int,
    ): List<MobiKf8Plan> {
        var fragmentCursor = 0
        val plans = data.entries.map { entry ->
            checkActive()
            val count = entry.requiredValues(1, 1)[0]
            require(count <= fragments.size - fragmentCursor) { "KF8 SKEL 引用了不存在的片段" }
            val range = entry.requiredValues(6, 2)
            val skeleton = MobiKf8Skeleton(range[0], range[1])
            require(skeleton.length > 0 && skeleton.offset >= mainStart &&
                skeleton.offset < mainEnd && skeleton.length <= mainEnd - skeleton.offset) {
                "KF8 SKEL 骨架范围越界"
            }
            val sectionFragments = fragments.subList(fragmentCursor, fragmentCursor + count)
            fragmentCursor += count
            val fragmentBytes = sectionFragments.sumOf { it.length.toLong() }
            val sourceEnd = skeleton.offset.toLong() + skeleton.length + fragmentBytes
            require(sourceEnd <= mainEnd) { "KF8 FRAG 数据超出 FDST 主流" }
            var previousEnd = 0
            for (fragment in sectionFragments.sortedBy { it.offset }) {
                checkActive()
                require(fragment.offset == previousEnd && fragment.length <= fragmentBytes - fragment.offset) {
                    "KF8 FRAG 源片段重叠、缺失或越界"
                }
                previousEnd += fragment.length
                requireCharacterRange(skeleton.offset + skeleton.length + fragment.offset, fragment.length)
            }
            requireCharacterRange(skeleton.offset, skeleton.length)
            MobiKf8Plan(skeleton, sectionFragments, sourceEnd.toInt())
        }
        require(fragmentCursor == fragments.size) { "KF8 FRAG 包含未被骨架引用的片段" }
        var previousEnd = mainStart
        for (plan in plans.sortedBy { it.skeleton.offset }) {
            checkActive()
            require(plan.skeleton.offset >= previousEnd) { "KF8 SKEL 源范围重叠" }
            requirePadding(previousEnd, plan.skeleton.offset)
            previousEnd = plan.sourceEnd
        }
        requirePadding(previousEnd, mainEnd)
        return plans
    }

    private fun requireCharacterRange(start: Int, length: Int) {
        rawText.mobiRange(start, length)
        require(encoding.isBoundary(rawText, start) && encoding.isBoundary(rawText, start + length)) {
            "KF8 骨架或片段边界落在多字节字符中间"
        }
    }

    private fun requirePadding(start: Int, end: Int) {
        for (cursor in start until end) {
            if (cursor and 0x3fff == 0) checkActive()
            require(rawText.mobiU8(cursor) in PADDING_BYTES) { "KF8 主流存在未被骨架引用的正文" }
        }
    }

    private fun decimalOffset(label: String): Int {
        require(label.isNotEmpty() && label.length <= 16) { "KF8 FRAG 插入位置标签无效" }
        var value = 0L
        for (char in label) {
            require(char in '0'..'9') { "KF8 FRAG 插入位置不是十进制字节偏移" }
            value = value * 10 + (char - '0')
            require(value <= Int.MAX_VALUE) { "KF8 FRAG 插入位置越界" }
        }
        return value.toInt()
    }

    private fun MobiIndexEntry.requiredValues(tag: Int, count: Int): List<Int> {
        val result = values[tag]
        require(result != null && result.size >= count && result.size % count == 0) {
            "KF8 结构索引缺少有效的 tag $tag"
        }
        // SKEL writers can emit repeated value groups; Android consumes the first group.
        return result.take(count)
    }

    private companion object {
        const val MAX_STRUCTURAL_ENTRIES = 50000
        val PADDING_BYTES = setOf(0, 9, 10, 12, 13, 32)
    }
}

private data class MobiKf8Skeleton(val offset: Int, val length: Int)
private data class MobiKf8Fragment(val insertOffset: Int, val fid: Int, val offset: Int, val length: Int)
private data class MobiKf8Plan(
    val skeleton: MobiKf8Skeleton,
    val fragments: List<MobiKf8Fragment>,
    val sourceEnd: Int,
)

private data class MobiKf8Piece(
    val sourceStart: Int,
    val length: Int,
    val fid: Int? = null,
    val fragmentOffset: Int = 0,
)

/** AVL rope: insertions split byte spans, never copy or decode the partially built HTML. */
private class MobiKf8ByteRope(piece: MobiKf8Piece) {
    private var root = MobiKf8RopeNode(piece = piece)
    val length: Int get() = root.length

    fun sourceOffset(offset: Int): Int {
        require(offset in 0 until length) { "KF8 字节片段位置越界" }
        var node = root
        var at = offset
        while (node.piece == null) {
            val left = checkNotNull(node.left)
            if (at < left.length) {
                node = left
            } else {
                at -= left.length
                node = checkNotNull(node.right)
            }
        }
        return checkNotNull(node.piece).sourceStart + at
    }

    fun insert(offset: Int, piece: MobiKf8Piece) {
        require(offset in 0..length && piece.length > 0 && length <= MAX_TEXT_BYTES - piece.length) {
            "KF8 字节片段插入范围无效"
        }
        val (left, right) = split(root, offset)
        root = checkNotNull(join(join(left, MobiKf8RopeNode(piece = piece)), right))
    }

    fun forEach(visit: (MobiKf8Piece) -> Unit) {
        fun walk(node: MobiKf8RopeNode) {
            val piece = node.piece
            if (piece != null) {
                visit(piece)
            } else {
                walk(checkNotNull(node.left))
                walk(checkNotNull(node.right))
            }
        }
        walk(root)
    }

    private fun split(node: MobiKf8RopeNode, offset: Int): Pair<MobiKf8RopeNode?, MobiKf8RopeNode?> {
        if (offset == 0) return null to node
        if (offset == node.length) return node to null
        val piece = node.piece
        if (piece != null) {
            val left = MobiKf8RopeNode(piece = piece.copy(length = offset))
            val right = MobiKf8RopeNode(piece = piece.copy(
                sourceStart = piece.sourceStart + offset,
                length = piece.length - offset,
                fragmentOffset = piece.fragmentOffset + offset,
            ))
            return left to right
        }
        val left = checkNotNull(node.left)
        val right = checkNotNull(node.right)
        return if (offset < left.length) {
            val (before, after) = split(left, offset)
            before to join(after, right)
        } else {
            val (before, after) = split(right, offset - left.length)
            join(left, before) to after
        }
    }

    private fun join(left: MobiKf8RopeNode?, right: MobiKf8RopeNode?): MobiKf8RopeNode? {
        if (left == null) return right
        if (right == null) return left
        return when {
            left.height > right.height + 1 -> balance(
                checkNotNull(left.left),
                checkNotNull(join(checkNotNull(left.right), right)),
            )
            right.height > left.height + 1 -> balance(
                checkNotNull(join(left, checkNotNull(right.left))),
                checkNotNull(right.right),
            )
            else -> branch(left, right)
        }
    }

    private fun balance(left: MobiKf8RopeNode, right: MobiKf8RopeNode): MobiKf8RopeNode {
        if (left.height > right.height + 1) {
            val outer = checkNotNull(left.left)
            val inner = checkNotNull(left.right)
            return if (outer.height >= inner.height) {
                branch(outer, branch(inner, right))
            } else {
                branch(branch(outer, checkNotNull(inner.left)), branch(checkNotNull(inner.right), right))
            }
        }
        if (right.height > left.height + 1) {
            val inner = checkNotNull(right.left)
            val outer = checkNotNull(right.right)
            return if (outer.height >= inner.height) {
                branch(branch(left, inner), outer)
            } else {
                branch(branch(left, checkNotNull(inner.left)), branch(checkNotNull(inner.right), outer))
            }
        }
        return branch(left, right)
    }

    private fun branch(left: MobiKf8RopeNode, right: MobiKf8RopeNode) = MobiKf8RopeNode(left = left, right = right)
}

private class MobiKf8RopeNode(
    val piece: MobiKf8Piece? = null,
    val left: MobiKf8RopeNode? = null,
    val right: MobiKf8RopeNode? = null,
) {
    val length: Int = piece?.length ?: (checkNotNull(left).length + checkNotNull(right).length)
    val height: Int = if (piece != null) 1 else 1 + maxOf(checkNotNull(left).height, checkNotNull(right).height)
}
