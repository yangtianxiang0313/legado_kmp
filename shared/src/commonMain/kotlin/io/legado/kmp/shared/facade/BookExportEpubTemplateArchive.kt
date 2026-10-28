package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.BookArchiveZipReader
import io.legado.kmp.shared.util.cnCompare
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

internal data class BookExportEpubTemplateAsset(
    val path: String,
    val data: ByteArray,
    val mediaType: String,
) {
    override fun toString(): String = "BookExportEpubTemplateAsset(redacted)"
}

/** Paths are relative to the Asset layout, never flattened or opened on the filesystem. */
internal class BookExportEpubTemplateArchive(
    val chapterTemplate: String,
    val sectionTemplates: List<BookExportEpubTemplateAsset>,
    val resources: List<BookExportEpubTemplateAsset>,
) {
    override fun toString(): String = "BookExportEpubTemplateArchive(redacted)"

    companion object {
        private const val MAX_ZIP_BYTES = 32 * 1024 * 1024
        private const val MAX_RESOURCE_BYTES = 16 * 1024 * 1024
        private const val MAX_EXPANDED_BYTES = 64L * 1024 * 1024
        private const val MAX_HTML_BYTES = 1024 * 1024
        private const val MAX_FILES = 512
        private val controlNames = setOf(
            "mimetype", "content.opf", "nav.xhtml", "toc.ncx", "container.xml",
            "encryption.xml", "signatures.xml", "rights.xml", "metadata.xml",
        )

        fun read(base64Zip: String, checkActive: () -> Unit = {}): BookExportEpubTemplateArchive = try {
            readArchive(base64Zip, checkActive)
        } catch (error: Throwable) {
            findFacadeRequestCancellation(error)?.let { throw it }
            // The ZIP reader's diagnostics include entry paths. Never retain their cause or text.
            throw if (error is BookExportEpubTemplateFailure) error else {
                BookExportEpubTemplateFailure(BookExportEpubTemplateProblem.INVALID_ARCHIVE)
            }
        }

        private fun readArchive(base64Zip: String, checkActive: () -> Unit): BookExportEpubTemplateArchive {
            val zip = BookArchiveZipReader(decodeZip(base64Zip, checkActive), checkActive)
            val entries = zip.entries()
            requireTemplate(entries.size <= MAX_FILES, BookExportEpubTemplateProblem.LIMIT_EXCEEDED)
            var expandedBytes = 0L
            val foldedPaths = mutableSetOf<String>()
            entries.forEach { entry ->
                checkActive()
                requireTemplate(entry.size <= MAX_RESOURCE_BYTES, BookExportEpubTemplateProblem.LIMIT_EXCEEDED)
                expandedBytes += entry.size.toLong()
                requireTemplate(expandedBytes <= MAX_EXPANDED_BYTES, BookExportEpubTemplateProblem.LIMIT_EXCEEDED)
                requireTemplate(entry.path.none { it in "#?%" }, BookExportEpubTemplateProblem.INVALID_PATH)
                requireTemplate(foldedPaths.add(caselessPath(entry.path)), BookExportEpubTemplateProblem.PATH_CONFLICT)
                if (BookExportEpubTemplateResources.isHtml(entry.path)) {
                    requireTemplate(entry.size <= MAX_HTML_BYTES, BookExportEpubTemplateProblem.HTML_TOO_LARGE)
                }
            }
            entries.forEach { entry ->
                checkActive()
                var parent = caselessPath(entry.path).substringBeforeLast('/', "")
                while (parent.isNotEmpty()) {
                    requireTemplate(parent !in foldedPaths, BookExportEpubTemplateProblem.PATH_CONFLICT)
                    parent = parent.substringBeforeLast('/', "")
                }
            }

            val chapters = entries.filter { isChapterPath(it.path) }
            requireTemplate(chapters.isNotEmpty(), BookExportEpubTemplateProblem.MISSING_CHAPTER)
            requireTemplate(chapters.size == 1, BookExportEpubTemplateProblem.AMBIGUOUS_CHAPTER)
            val chapter = chapters.single()
            val textDirectory = chapter.path.substringBeforeLast('/')
            val root = textDirectory.substringBeforeLast('/', "").let { if (it.isEmpty()) "" else "$it/" }

            // Check every file before inflating even the chapter; wrapper siblings are not silently discarded.
            val relativePaths = entries.associate { entry ->
                checkActive()
                requireTemplate(entry.path.startsWith(root), BookExportEpubTemplateProblem.INVALID_LAYOUT)
                val originalPath = entry.path.removePrefix(root)
                val path = if (originalPath.substringBefore('/').equals("Text", ignoreCase = true)) {
                    "Text/${originalPath.substringAfter('/')}"
                } else originalPath
                BookArchiveZipReader.validatePath(path)
                val parts = path.split('/')
                requireTemplate(parts.none { caselessPath(it) in controlNames || caselessPath(it) == "meta-inf" },
                    BookExportEpubTemplateProblem.CONTROL_RESOURCE)
                requireTemplate(BookExportEpubTemplateResources.isSupported(path),
                    BookExportEpubTemplateProblem.UNSUPPORTED_RESOURCE)
                entry.path to path
            }

            var chapterTemplate: String? = null
            val sections = mutableListOf<BookExportEpubTemplateAsset>()
            val resources = mutableListOf<BookExportEpubTemplateAsset>()
            entries.sortedBy { caselessPath(relativePaths.getValue(it.path)) }.forEach { entry ->
                checkActive()
                val path = relativePaths.getValue(entry.path)
                val data = zip.read(entry.path)
                val mediaType = BookExportEpubTemplateResources.mediaType(path, data, checkActive)
                checkActive()
                if (entry.path == chapter.path) {
                    val template = BookExportEpubTemplateResources.utf8(data, checkActive)
                    requireTemplate(epubTemplateHasContentSlot(template, checkActive), BookExportEpubTemplateProblem.MISSING_CONTENT)
                    chapterTemplate = template
                } else {
                    val asset = BookExportEpubTemplateAsset(path, data, mediaType)
                    if (path.substringBefore('/').equals("Text", ignoreCase = true) &&
                        BookExportEpubTemplateResources.isHtml(path)) {
                        sections += asset
                    } else {
                        resources += asset
                    }
                }
            }
            checkActive()
            return BookExportEpubTemplateArchive(
                chapterTemplate ?: throw BookExportEpubTemplateFailure(BookExportEpubTemplateProblem.MISSING_CHAPTER),
                sections.sortedWith { left, right -> left.path.cnCompare(right.path) },
                resources.toList(),
            )
        }

        private fun isChapterPath(path: String): Boolean {
            val name = path.substringAfterLast('/')
            return (name.equals("chapter.html", ignoreCase = true) || name.equals("chapter.xhtml", ignoreCase = true)) &&
                path.substringBeforeLast('/', "").substringAfterLast('/').equals("Text", ignoreCase = true)
        }

        // Also folds expanding uppercase mappings (for example sharp-s) and final sigma.
        private fun caselessPath(path: String): String = path.lowercase().uppercase().lowercase()

        @OptIn(ExperimentalEncodingApi::class)
        private fun decodeZip(value: String, checkActive: () -> Unit): ByteArray {
            checkActive()
            requireTemplate(value.length.toLong() <= (MAX_ZIP_BYTES.toLong() + 2) / 3 * 4,
                BookExportEpubTemplateProblem.LIMIT_EXCEEDED)
            val remainder = value.length % 4
            val padding = when {
                value.endsWith("==") -> 2
                value.endsWith('=') -> 1
                else -> 0
            }
            requireTemplate(value.isNotEmpty() && remainder != 1 && (padding == 0 || remainder == 0),
                BookExportEpubTemplateProblem.INVALID_ARCHIVE)
            val decodedSize = value.length.toLong() / 4 * 3 - padding + when (remainder) {
                2 -> 1
                3 -> 2
                else -> 0
            }
            requireTemplate(decodedSize in 22..MAX_ZIP_BYTES.toLong(), BookExportEpubTemplateProblem.LIMIT_EXCEEDED)
            value.forEachIndexed { index, char ->
                if (index and 65535 == 0) checkActive()
                requireTemplate(
                    if (index >= value.length - padding) char == '=' else {
                        char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '+' || char == '/'
                    },
                    BookExportEpubTemplateProblem.INVALID_ARCHIVE,
                )
            }
            checkActive()
            return Base64.decode(value).also {
                checkActive()
                requireTemplate(it.size.toLong() == decodedSize, BookExportEpubTemplateProblem.INVALID_ARCHIVE)
            }
        }
    }
}

internal enum class BookExportEpubTemplateProblem(val message: String) {
    INVALID_ARCHIVE("EPUB 模板归档无效或已损坏"),
    LIMIT_EXCEEDED("EPUB 模板超过归档容量或文件数量限制"),
    HTML_TOO_LARGE("EPUB 模板的 HTML 文件超过 1 MiB 限制"),
    INVALID_PATH("EPUB 模板包含不安全的资源路径"),
    PATH_CONFLICT("EPUB 模板包含重名或冲突的资源路径"),
    INVALID_LAYOUT("EPUB 模板的目录布局无效"),
    MISSING_CHAPTER("EPUB 模板缺少章模板"),
    AMBIGUOUS_CHAPTER("EPUB 模板包含多个章模板"),
    MISSING_CONTENT("EPUB 章模板缺少正文占位符"),
    CONTROL_RESOURCE("EPUB 模板包含保留的控制文件"),
    UNSUPPORTED_RESOURCE("EPUB 模板包含不支持的资源或可执行文件"),
    INVALID_RESOURCE("EPUB 模板的资源格式与内容无效"),
    INVALID_UTF8("EPUB 模板文本必须使用有效的 UTF-8 编码"),
    SCRIPT_RESOURCE("EPUB 模板不允许包含脚本标签"),
}

internal class BookExportEpubTemplateFailure(val problem: BookExportEpubTemplateProblem) : Exception(problem.message)

internal fun requireTemplate(condition: Boolean, problem: BookExportEpubTemplateProblem) {
    if (!condition) throw BookExportEpubTemplateFailure(problem)
}
