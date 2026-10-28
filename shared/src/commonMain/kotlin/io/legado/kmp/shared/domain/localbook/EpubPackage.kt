package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element

internal class EpubPackage(private val archive: EpubArchive) {
    private data class Item(val id: String, val path: String, val mediaType: String, val properties: Set<String>)

    private val packagePath: String
    private val directory: String
    private val root: Element
    private val manifest: Map<String, Item>
    private val navigation by lazy {
        val documents = manifest.values.filter(::isDocument).map { it.path }.toSet()
        EpubNavigation(archive) { path -> path in documents || isHtmlPath(path) }
    }

    init {
        val container = archive.readText("META-INF/container.xml", EpubArchive.MAX_PACKAGE_BYTES)
        val declaredPath = container?.let { xml ->
            val document = parseEpubXml(xml)
            require(document.child(0).epubName() == "container") { "EPUB container.xml 根节点无效" }
            document.getAllElements().firstOrNull { it.epubName() == "rootfile" }
                ?.attr("full-path")?.let { EpubResourcePaths.resolve("", it) }
        }
        packagePath = declaredPath
            ?: archive.entries().firstOrNull { it.endsWith(".opf", ignoreCase = true) }
            ?: error("EPUB package document not found")
        directory = packagePath.substringBeforeLast('/', "")
        root = parseEpubXml(archive.readText(packagePath, EpubArchive.MAX_PACKAGE_BYTES)
            ?: error("EPUB package document is missing")).child(0)
        require(root.epubName() == "package") { "EPUB package 根节点无效" }
        val items = root.epubChild("manifest")?.children().orEmpty()
            .filter { it.epubName() == "item" }.mapNotNull { item ->
                val id = item.attr("id")
                require(id.isNotBlank()) { "EPUB manifest 包含空资源 ID" }
                val href = item.attr("href").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                val path = EpubNavigationUris.resolve(packagePath, href)?.path
                    ?: return@mapNotNull null
                Item(id, path, item.attr("media-type"), item.attr("properties").split(Regex("\\s+"))
                    .filter { it.isNotBlank() }.toSet())
            }
        require(items.map { it.id }.distinct().size == items.size) { "EPUB manifest 包含重复资源 ID" }
        manifest = items.associateBy { it.id }
    }

    fun metadata(name: String): String? = root.epubChild("metadata")?.children()
        ?.firstOrNull { it.epubName() == name }?.text()?.let { text ->
            (if (name == "description") Ksoup.parseBodyFragment(text).text() else text)
                .trim().takeIf { it.isNotBlank() }
        }

    fun subjects(): List<String> = root.epubChild("metadata")?.children().orEmpty()
        .filter { it.epubName() == "subject" }.map { it.text().trim() }.filter { it.isNotEmpty() }.distinct()

    fun spinePaths(): List<String> {
        val references = root.epubChild("spine")?.children().orEmpty().filter { it.epubName() == "itemref" }
        val paths = references.mapNotNull { ref ->
            val item = manifest[ref.attr("idref")] ?: return@mapNotNull null
            item.path.takeIf { archive.contains(it) && isDocument(item) }
        }.distinct()
        if (paths.isNotEmpty()) return paths
        val fallback = archive.entries().filter { isHtmlPath(it) }
            .filterNot { path -> manifest.values.any { it.path == path && "nav" in it.properties } }
            .sorted()
        require(fallback.isNotEmpty()) { "EPUB spine is empty" }
        return fallback
    }

    /** Display order, not spine order; repeated resources and fragments remain distinct. */
    fun navigationEntries(): List<EpubNavigationEntry> = navigationEntriesCache

    private val navigationEntriesCache: List<EpubNavigationEntry> by lazy {
        manifest.values.asSequence().filter { "nav" in it.properties }.map { it.path }.distinct()
            .take(EpubNavigation.MAX_NAVIGATION_DOCUMENTS).forEach { path ->
                val entries = navigation.readNav(path)
                if (entries.any { it.path != null }) return@lazy entries
            }
        val declaredNcx = root.epubChild("spine")?.attr("toc")?.let(manifest::get)
        (listOfNotNull(declaredNcx) + manifest.values.filter {
            it.mediaType.equals("application/x-dtbncx+xml", true) || it.path.endsWith(".ncx", true)
        }).asSequence().map { it.path }.distinct().take(EpubNavigation.MAX_NAVIGATION_DOCUMENTS)
            .forEach { path ->
                val entries = navigation.readNcx(path)
                if (entries.any { it.path != null }) return@lazy entries
            }
        navigation.spineEntries(spinePaths())
    }

    /** Legacy path-only callers intentionally keep the first label for each document. */
    fun navigationTitles(): Map<String, String> = linkedMapOf<String, String>().also { titles ->
        navigationEntries().forEach { entry ->
            val path = entry.path ?: return@forEach
            if (path !in titles) titles[path] = entry.title
        }
    }

    fun coverPath(): String? {
        val metadataCoverId = root.epubChild("metadata")?.children()?.firstOrNull {
            it.epubName() == "meta" && it.attr("name").equals("cover", true)
        }?.attr("content")
        val preferred = manifest.values.firstOrNull { "cover-image" in it.properties }
            ?: metadataCoverId?.let(manifest::get)
        preferred?.path?.takeIf(archive::contains)?.let { return it }

        root.epubChild("guide")?.children()?.firstOrNull {
            it.epubName() == "reference" && it.attr("type").split(Regex("\\s+")).contains("cover")
        }?.attr("href")?.let { href ->
            EpubResourcePaths.resolve(directory, href)?.let { page ->
                if (EpubEmbeddedImage.isImagePath(page) && archive.contains(page)) return page
                archive.readText(page)?.let { html ->
                    val document = Ksoup.parse(html)
                    document.getAllElements().firstOrNull { it.epubName() in setOf("img", "image") }
                        ?.let { image ->
                            val reference = EpubEmbeddedImage.reference(image)
                            EpubResourcePaths.resolve(page.substringBeforeLast('/', ""), reference)
                                ?.takeIf(archive::contains)?.let { return it }
                        }
                }
            }
        }
        return manifest.values.firstOrNull { item ->
            item.mediaType.startsWith("image/", true) &&
                item.path.substringAfterLast('/').substringBeforeLast('.').contains("cover", true) &&
                archive.contains(item.path)
        }?.path
    }

    private fun isDocument(item: Item): Boolean = item.mediaType.lowercase() in
        setOf("application/xhtml+xml", "text/html", "image/svg+xml") || isHtmlPath(item.path)

    private fun isHtmlPath(path: String): Boolean = path.substringAfterLast('.').lowercase() in
        setOf("html", "xhtml", "htm")
}
