package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node
import kotlin.coroutines.cancellation.CancellationException

/** Archive-relative decoded paths and raw decoded fragment IDs, in depth-first display order. */
internal data class EpubNavigationEntry(
    val title: String,
    val path: String?,
    val fragment: String?,
    val depth: Int,
    val hasChildren: Boolean,
)

internal class EpubNavigation(
    private val archive: EpubArchive,
    private val isDocument: (String) -> Boolean,
) {
    private data class Branch(
        val title: String,
        val target: EpubNavigationTarget?,
        val children: List<Branch>,
    )

    private class EntryBudget {
        private var count = 0

        fun visit(depth: Int) {
            require(depth < MAX_DEPTH && ++count <= MAX_ENTRIES) { "EPUB 导航层级或条目超限" }
        }
    }

    private val readableDocuments = mutableMapOf<String, Boolean>()

    fun readNav(path: String): List<EpubNavigationEntry> = navigationOrNull {
        val html = archive.readText(path, MAX_NAVIGATION_BYTES) ?: return@navigationOrNull emptyList()
        val elements = checkedElements(Ksoup.parse(html))
        val toc = elements.firstOrNull { element ->
            val types = element.attr("epub:type").split(WHITESPACE)
            element.epubName() == "nav" && types.none { it == "landmarks" || it == "page-list" } &&
                ("toc" in types || "doc-toc" in element.attr("role").split(WHITESPACE))
        } ?: return@navigationOrNull emptyList()
        val list = toc.epubChild("ol") ?: return@navigationOrNull emptyList()
        flatten(readNavList(list, path, 0, EntryBudget()))
    }.orEmpty()

    fun readNcx(path: String): List<EpubNavigationEntry> = navigationOrNull {
        // Invalid XML or an exceeded budget discards this NCX, allowing package-level spine fallback.
        val xml = archive.readText(path, MAX_NAVIGATION_BYTES) ?: return@navigationOrNull emptyList()
        val document = parseEpubXml(xml)
        checkedElements(document)
        val root = document.child(0)
        require(root.epubName() == "ncx") { "EPUB NCX 根节点无效" }
        val map = root.epubChild("navmap") ?: return@navigationOrNull emptyList()
        flatten(readNcxPoints(map, path, 0, EntryBudget()))
    }.orEmpty()

    fun spineEntries(paths: List<String>): List<EpubNavigationEntry> {
        require(paths.size <= MAX_ENTRIES) { "EPUB spine 条目超限" }
        val entries = paths.filter(::isReadableDocument).map { path ->
            val title = navigationOrNull {
                val html = archive.readText(path) ?: return@navigationOrNull null
                val elements = checkedElements(Ksoup.parse(html))
                elements.firstOrNull { it.epubName() == "title" && it.text().isNotBlank() }?.text()
                    ?: elements.firstOrNull { it.epubName() == "h1" }?.text()
            }?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackTitle(path)
            EpubNavigationEntry(title, path, null, 0, false)
        }
        require(entries.isNotEmpty()) { "EPUB 导航及 spine 均无可读文档" }
        return entries
    }

    private fun isReadableDocument(path: String): Boolean = readableDocuments.getOrPut(path) {
        archive.contains(path) && isDocument(path) && navigationOrNull {
            archive.read(path, EpubArchive.MAX_DOCUMENT_BYTES) != null
        } == true
    }

    private fun target(document: String, reference: String?): EpubNavigationTarget? {
        val resolved = reference?.let { EpubNavigationUris.resolve(document, it) } ?: return null
        return resolved.takeIf { isReadableDocument(it.path) }
    }

    private fun readNavList(list: Element, document: String, depth: Int, budget: EntryBudget): List<Branch> {
        val result = mutableListOf<Branch>()
        list.children().filter { it.epubName() == "li" }.forEach { item ->
            budget.visit(depth)
            val children = item.children().filter { it.epubName() == "ol" }
                .flatMap { readNavList(it, document, depth + 1, budget) }
            val label = item.children().firstOrNull { it.epubName() == "a" || it.epubName() == "span" }
            val reference = label?.takeIf { it.epubName() == "a" && it.hasAttr("href") }?.attr("href")
            val title = label?.let(::labelText).orEmpty()
            result += branches(title, target(document, reference), children)
        }
        return result
    }

    private fun readNcxPoints(parent: Element, document: String, depth: Int, budget: EntryBudget): List<Branch> {
        val result = mutableListOf<Branch>()
        parent.children().filter { it.epubName() == "navpoint" }.forEach { point ->
            budget.visit(depth)
            val children = readNcxPoints(point, document, depth + 1, budget)
            val title = point.epubChild("navlabel")?.epubChild("text")?.text().orEmpty().trim()
            val reference = point.epubChild("content")?.takeIf { it.hasAttr("src") }?.attr("src")
            result += branches(title, target(document, reference), children)
        }
        return result
    }

    private fun branches(title: String, target: EpubNavigationTarget?, children: List<Branch>): List<Branch> {
        if (target == null && children.isEmpty()) return emptyList()
        // An unusable parent link can still label a valid subtree; anonymous wrappers are promoted.
        if (title.isBlank() && target == null) return children
        val label = title.ifBlank { target?.fragment?.takeIf { it.isNotBlank() } ?: fallbackTitle(target!!.path) }
        return listOf(Branch(label, target, children))
    }

    private fun labelText(element: Element): String = element.text().trim().ifBlank {
        element.attr("aria-label").trim().ifBlank {
            element.getAllElements().filter { it.epubName() == "img" }
                .map { it.attr("alt").trim() }.filter { it.isNotEmpty() }.joinToString(" ")
        }
    }

    private fun flatten(branches: List<Branch>): List<EpubNavigationEntry> {
        val entries = mutableListOf<EpubNavigationEntry>()
        fun append(branch: Branch, depth: Int) {
            entries += EpubNavigationEntry(
                branch.title, branch.target?.path, branch.target?.fragment, depth, branch.children.isNotEmpty(),
            )
            branch.children.forEach { append(it, depth + 1) }
        }
        branches.forEach { append(it, 0) }
        return entries
    }

    private fun checkedElements(root: Node): List<Element> {
        val pending = ArrayDeque<Pair<Node, Int>>()
        val seen = mutableSetOf<Node>()
        val elements = mutableListOf<Element>()
        pending.addLast(root to 0)
        while (pending.isNotEmpty()) {
            val (node, depth) = pending.removeLast()
            require(depth <= MAX_DOM_DEPTH && seen.add(node)) { "EPUB 导航 DOM 过深或循环" }
            if (node is Element) elements.add(node)
            val children = node.childNodes()
            require(seen.size + pending.size + children.size <= MAX_NODES) { "EPUB 导航 DOM 节点超限" }
            children.asReversed().forEach { pending.addLast(it to depth + 1) }
        }
        return elements
    }

    private fun fallbackTitle(path: String): String = path.substringAfterLast('/').substringBeforeLast('.')
        .ifBlank { path.substringAfterLast('/') }

    companion object {
        const val MAX_NAVIGATION_DOCUMENTS = 8
        private const val MAX_NAVIGATION_BYTES = EpubArchive.MAX_PACKAGE_BYTES
        private const val MAX_DEPTH = 32
        private const val MAX_ENTRIES = 10000
        private const val MAX_DOM_DEPTH = 128
        private const val MAX_NODES = 50000
        private val WHITESPACE = Regex("\\s+")
    }
}

internal data class EpubNavigationTarget(val path: String, val fragment: String?)

/** RFC 3986 components are separated before decoding; decoded delimiters never become URI syntax. */
internal object EpubNavigationUris {
    private data class Reference(
        val scheme: String?,
        val authority: String?,
        val path: String,
        val query: String?,
        val fragment: String?,
    )

    // RFC 3986 appendix B, with non-capturing delimiters and an anchored complete reference.
    private val components = Regex("^(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\\?([^#]*))?(?:#(.*))?$")

    fun resolve(document: String, reference: String): EpubNavigationTarget? = navigationOrNull {
        val value = reference.trim()
        require(value.length <= 8192 && value.none { it.isISOControl() || it == '\\' }) {
            "EPUB 导航 URI 无效"
        }
        val match = components.matchEntire(value) ?: return@navigationOrNull null
        val uri = Reference(
            match.groups[1]?.value, match.groups[2]?.value, match.groupValues[3],
            match.groups[4]?.value, match.groups[5]?.value,
        )
        if (uri.scheme != null || uri.authority != null) return@navigationOrNull null
        val fragment = uri.fragment?.let(::decodeComponent)?.takeIf { it.isNotEmpty() }
        require(fragment?.none { it.isISOControl() } != false) { "EPUB 导航 fragment 无效" }
        // Query data is not part of a ZIP entry identity, but malformed escaping is still invalid.
        uri.query?.let(::decodeComponent)
        val path = if (uri.path.isEmpty()) document else resolvePath(document, uri.path)
        BookArchiveZipReader.validatePath(path)
        EpubNavigationTarget(path, fragment)
    }

    private fun resolvePath(document: String, encodedPath: String): String {
        val parts = if (encodedPath.startsWith('/')) mutableListOf() else
            document.substringBeforeLast('/', "").split('/').filter { it.isNotEmpty() }.toMutableList()
        val segments = encodedPath.removePrefix("/").split('/')
        segments.forEachIndexed { index, segment ->
            when (segment) {
                "." -> require(index != segments.lastIndex) { "EPUB 导航目标是目录" }
                ".." -> {
                    require(parts.isNotEmpty() && index != segments.lastIndex) { "EPUB 导航路径越界或指向目录" }
                    parts.removeAt(parts.lastIndex)
                }
                else -> {
                    val decoded = decodeComponent(segment)
                    require(decoded.isNotEmpty() && decoded != "." && decoded != ".." &&
                        decoded.none { it.isISOControl() || it in "/\\:" }) { "EPUB 导航路径片段无效" }
                    parts += decoded
                }
            }
        }
        return parts.joinToString("/")
    }

    private fun decodeComponent(value: String): String {
        if ('%' !in value) return value
        val bytes = mutableListOf<Byte>()
        var cursor = 0
        while (cursor < value.length) {
            if (value[cursor] == '%') {
                require(cursor + 2 < value.length) { "EPUB 导航百分号编码不完整" }
                val high = value[cursor + 1].digitToIntOrNull(16)
                val low = value[cursor + 2].digitToIntOrNull(16)
                require(high != null && low != null) { "EPUB 导航百分号编码无效" }
                bytes += ((high shl 4) or low).toByte()
                cursor += 3
            } else {
                val end = value.indexOf('%', cursor).takeIf { it >= 0 } ?: value.length
                bytes.addAll(value.substring(cursor, end).encodeToByteArray().toList())
                cursor = end
            }
        }
        return bytes.toByteArray().decodeToString(throwOnInvalidSequence = true)
    }
}

// Broken optional navigation/targets fall back without swallowing request cancellation.
private inline fun <T> navigationOrNull(block: () -> T): T? = try {
    block()
} catch (error: CancellationException) {
    throw error
} catch (_: Exception) {
    null
}
