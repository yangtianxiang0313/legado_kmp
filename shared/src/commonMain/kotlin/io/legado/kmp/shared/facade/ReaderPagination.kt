package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.ReaderRuntimeConfig
import io.legado.kmp.shared.preferences.ReaderStylePreferences
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

data class ReaderViewport(
    val width: Float,
    val height: Float,
)

data class ReaderPaginationConfig(
    val fontSize: Float,
    val titleFontSize: Float,
    val lineSpacingMultiplier: Float,
    val letterSpacing: Float,
    val paragraphSpacing: Int,
    val paragraphIndent: Int,
    val titleMode: Int,
    val titleTopSpacing: Int,
    val titleBottomSpacing: Int,
    val paddingTop: Int,
    val paddingBottom: Int,
    val paddingLeft: Int,
    val paddingRight: Int,
    val headerPaddingTop: Int,
    val headerPaddingBottom: Int,
    val footerPaddingTop: Int,
    val footerPaddingBottom: Int,
    val showHeaderLine: Boolean,
    val showFooterLine: Boolean,
    val headerMode: Int,
    val footerMode: Int,
    val hideStatusBar: Boolean,
    val textFullJustify: Boolean,
    val textBottomJustify: Boolean,
    val chineseMode: Int,
    val imageStyle: String? = null,
) {
    companion object {
        fun from(
            style: ReaderStylePreferences,
            runtime: ReaderRuntimeConfig,
            imageStyle: String? = null,
        ): ReaderPaginationConfig {
            return ReaderPaginationConfig(
                fontSize = style.fontSizeSp,
                titleFontSize = max(style.fontSizeSp + style.titleSize, 1f),
                lineSpacingMultiplier = style.lineSpacingMultiplier,
                letterSpacing = style.letterSpacing,
                paragraphSpacing = style.paragraphSpacing,
                paragraphIndent = style.paragraphIndent,
                titleMode = style.titleMode,
                titleTopSpacing = style.titleTopSpacing,
                titleBottomSpacing = style.titleBottomSpacing,
                paddingTop = style.paddingTop,
                paddingBottom = style.paddingBottom,
                paddingLeft = style.paddingLeft,
                paddingRight = style.paddingRight,
                headerPaddingTop = style.headerPaddingTop,
                headerPaddingBottom = style.headerPaddingBottom,
                footerPaddingTop = style.footerPaddingTop,
                footerPaddingBottom = style.footerPaddingBottom,
                showHeaderLine = style.showHeaderLine,
                showFooterLine = style.showFooterLine,
                headerMode = style.headerMode,
                footerMode = style.footerMode,
                hideStatusBar = runtime.hideStatusBar,
                textFullJustify = runtime.textFullJustify,
                textBottomJustify = runtime.textBottomJustify,
                chineseMode = runtime.chineseMode,
                imageStyle = imageStyle,
            )
        }
    }
}

enum class ReaderPageFragmentKind {
    HEADING,
    PARAGRAPH,
    IMAGE,
    SPACER,
}

data class ReaderPageFragment(
    val blockIndex: Int,
    val kind: ReaderPageFragmentKind,
    val text: String = "",
    val imageUrl: String? = null,
    val imageAlt: String? = null,
    val chapterStartPosition: Int,
    val chapterEndPosition: Int,
    val isContinuation: Boolean = false,
    val isParagraphEnd: Boolean = true,
)

data class ReaderPageSlice(
    val pageIndex: Int,
    val chapterStartPosition: Int,
    val chapterEndPosition: Int,
    val previewText: String,
    val pageText: String,
    val leadingBlockIndex: Int,
    val fragments: List<ReaderPageFragment>,
) {
    fun containsBlockIndex(blockIndex: Int): Boolean {
        return fragments.any { it.blockIndex == blockIndex }
    }
}

data class ReaderChapterLayout(
    val chapterIndex: Int,
    val chapterTitle: String,
    val pages: List<ReaderPageSlice>,
    val searchableText: String,
    val imageStyle: String? = null,
) {
    fun pageIndexByChapterPosition(position: Int): Int {
        if (pages.isEmpty()) return 0
        val normalized = position.coerceAtLeast(0)
        for (page in pages.indices.reversed()) {
            if (normalized >= pages[page].chapterStartPosition) {
                return page
            }
        }
        return 0
    }

    fun pageIndexBySearchPosition(position: Int): Int {
        return pageIndexByChapterPosition(position)
    }

    fun readPositionForPage(pageIndex: Int): Int {
        if (pages.isEmpty()) return 0
        return pages[pageIndex.coerceIn(0, pages.lastIndex)].chapterStartPosition
    }

    fun nextReadPosition(position: Int): Int {
        val currentIndex = pageIndexByChapterPosition(position)
        if (currentIndex >= pages.lastIndex) return -1
        return pages[currentIndex + 1].chapterStartPosition
    }

    fun prevReadPosition(position: Int): Int {
        val currentIndex = pageIndexByChapterPosition(position)
        if (currentIndex <= 0) return -1
        return pages[currentIndex - 1].chapterStartPosition
    }
}

class ReaderPaginationService {
    fun paginate(
        chapterIndex: Int,
        chapterTitle: String,
        content: String,
        config: ReaderPaginationConfig,
        viewport: ReaderViewport,
        checkActive: () -> Unit = {},
    ): ReaderChapterLayout {
        checkActive()
        val blocks = buildReaderContentBlocks(chapterTitle, content, checkActive)
            .withTitleVisibility(config, content, checkActive)
        val metrics = PaginationMetrics(config, viewport)
        val pages = mutableListOf<ReaderPageSlice>()
        var current = PageAccumulator(index = 0)
        var chapterCursor = 0

        fun flushPage(force: Boolean = false) {
            checkActive()
            if (!force && current.fragments.isEmpty()) return
            val pageText = current.pageTextParts.joinToString("\n") {
                checkActive()
                it.withReaderCancellationChecks(checkActive)
            }.withReaderCancellationChecks(checkActive).trim().toString()
            val previewText = current.previewParts.joinToString(" ") {
                checkActive()
                it.withReaderCancellationChecks(checkActive)
            }.withReaderCancellationChecks(checkActive).trim().toString()
            val leadingBlockIndex = current.fragments.firstOrNull()?.blockIndex ?: 0
            val startPosition = current.fragments.firstOrNull()?.chapterStartPosition ?: current.pageStartPosition
            val endPosition = current.fragments.lastOrNull()?.chapterEndPosition ?: startPosition
            pages += ReaderPageSlice(
                pageIndex = pages.size,
                chapterStartPosition = startPosition,
                chapterEndPosition = endPosition,
                previewText = previewText.ifEmpty { chapterTitle },
                pageText = pageText,
                leadingBlockIndex = leadingBlockIndex,
                fragments = current.fragments.map {
                    checkActive()
                    it
                },
            )
            current = PageAccumulator(index = pages.size, pageStartPosition = endPosition)
        }

        for (block in blocks) {
            checkActive()
            when (block.type) {
                ReaderContentBlockType.HEADING,
                ReaderContentBlockType.PARAGRAPH,
                -> {
                    val kind = if (block.type == ReaderContentBlockType.HEADING) {
                        ReaderPageFragmentKind.HEADING
                    } else {
                        ReaderPageFragmentKind.PARAGRAPH
                    }
                    if (config.normalizedImageStyle() == IMAGE_STYLE_SINGLE &&
                        kind != ReaderPageFragmentKind.HEADING &&
                        current.fragments.isNotEmpty() &&
                        current.fragments.all {
                            checkActive()
                            it.kind == ReaderPageFragmentKind.HEADING
                        }
                    ) {
                        flushPage()
                    }
                    val logicalText = convertText(block.text, config.chineseMode)
                    if (logicalText.isEmpty()) continue
                    val textMetrics = metrics.textMetricsFor(kind)
                    val wrappedLines = wrapText(
                        text = logicalText,
                        width = metrics.availableWidth,
                        metrics = textMetrics,
                        indentCount = if (kind == ReaderPageFragmentKind.PARAGRAPH) config.paragraphIndent else 0,
                        checkActive = checkActive,
                    )
                    var consumedChars = 0
                    var lineIndex = 0
                    while (lineIndex < wrappedLines.size) {
                        checkActive()
                        val lineHeight = textMetrics.lineHeight
                        val verticalBefore = when {
                            wrappedLines[lineIndex].isContinuationLine -> 0f
                            kind == ReaderPageFragmentKind.HEADING -> if (lineIndex == 0) {
                                config.titleTopSpacing.coerceAtLeast(0).toFloat()
                            } else 0f
                            current.fragments.isEmpty() -> 0f
                            else -> metrics.paragraphSpacingHeight
                        }
                        if (current.usedHeight > 0 && current.usedHeight + verticalBefore + lineHeight > metrics.availableHeight) {
                            flushPage()
                            continue
                        }
                        if (current.usedHeight == 0f && verticalBefore > 0f) {
                            current.usedHeight += min(verticalBefore, max(metrics.availableHeight - lineHeight, 0f))
                        } else if (current.usedHeight > 0f) {
                            current.usedHeight += verticalBefore
                        }
                        val availableLines = max(
                            floor((metrics.availableHeight - current.usedHeight) / lineHeight).toInt(),
                            1,
                        )
                        val takeCount = min(availableLines, wrappedLines.size - lineIndex)
                        val taken = wrappedLines.subList(lineIndex, lineIndex + takeCount)
                        val fragmentText = taken.joinToString("\n") {
                            checkActive()
                            it.text.withReaderCancellationChecks(checkActive)
                        }
                        val fragmentChars = taken.sumOf {
                            checkActive()
                            it.length
                        }
                        val startPosition = chapterCursor + consumedChars
                        val endPosition = startPosition + fragmentChars
                        current.fragments += ReaderPageFragment(
                            blockIndex = block.blockIndex,
                            kind = kind,
                            text = fragmentText,
                            chapterStartPosition = startPosition,
                            chapterEndPosition = endPosition,
                            isContinuation = lineIndex > 0,
                            isParagraphEnd = lineIndex + takeCount >= wrappedLines.size,
                        )
                        current.usedHeight += takeCount * lineHeight
                        if (current.previewParts.size < 3) {
                            current.previewParts += fragmentText.replace('\n', ' ').trim()
                        }
                        current.pageTextParts += fragmentText
                        consumedChars += fragmentChars
                        lineIndex += takeCount
                        if (lineIndex < wrappedLines.size) {
                            flushPage()
                        }
                    }
                    if (kind == ReaderPageFragmentKind.HEADING) {
                        // Reserve the bottom gap only after the complete title, including its continuations.
                        current.usedHeight += config.titleBottomSpacing.coerceAtLeast(0).toFloat()
                    }
                    chapterCursor += logicalText.length
                }

                ReaderContentBlockType.IMAGE -> {
                    val imageStyle = config.normalizedImageStyle()
                    val imageHeight = metrics.estimatedImageHeight(imageStyle)
                    val verticalBefore = if (current.usedHeight > 0f) metrics.paragraphSpacingHeight else 0f
                    if (imageStyle == IMAGE_STYLE_SINGLE && current.usedHeight > 0f) {
                        flushPage()
                    } else if (current.usedHeight > 0f && current.usedHeight + verticalBefore + imageHeight > metrics.availableHeight) {
                        flushPage()
                    }
                    if (current.usedHeight > 0f) {
                        current.usedHeight += verticalBefore
                    }
                    current.fragments += ReaderPageFragment(
                        blockIndex = block.blockIndex,
                        kind = ReaderPageFragmentKind.IMAGE,
                        imageUrl = block.imageUrl,
                        imageAlt = block.imageAlt,
                        chapterStartPosition = chapterCursor,
                        chapterEndPosition = chapterCursor + 1,
                    )
                    current.usedHeight += imageHeight
                    current.previewParts += block.imageAlt ?: ""
                    current.pageTextParts += listOfNotNull(block.imageAlt?.ifEmpty { null })
                    chapterCursor += 1
                    if (imageStyle == IMAGE_STYLE_SINGLE) {
                        flushPage()
                    }
                }

                ReaderContentBlockType.SPACER -> {
                    val spacerHeight = metrics.bodyLineHeight / 2f + metrics.paragraphSpacingHeight
                    if (current.usedHeight > 0f && current.usedHeight + spacerHeight > metrics.availableHeight) {
                        flushPage()
                    }
                    current.fragments += ReaderPageFragment(
                        blockIndex = block.blockIndex,
                        kind = ReaderPageFragmentKind.SPACER,
                        chapterStartPosition = chapterCursor,
                        chapterEndPosition = chapterCursor,
                    )
                    current.usedHeight += min(spacerHeight, metrics.availableHeight)
                }
            }
        }

        if (current.fragments.isNotEmpty() || pages.isEmpty()) {
            flushPage(force = true)
        }

        checkActive()
        return ReaderChapterLayout(
            chapterIndex = chapterIndex,
            chapterTitle = chapterTitle,
            pages = pages.ifEmpty {
                listOf(
                    ReaderPageSlice(
                        pageIndex = 0,
                        chapterStartPosition = 0,
                        chapterEndPosition = 0,
                        previewText = chapterTitle,
                        pageText = chapterTitle,
                        leadingBlockIndex = 0,
                        fragments = emptyList(),
                    )
                )
            },
            searchableText = blocks
                .filter {
                    checkActive()
                    it.type == ReaderContentBlockType.HEADING || it.type == ReaderContentBlockType.PARAGRAPH
                }
                .joinToString("\n") {
                    checkActive()
                    convertText(it.text, config.chineseMode).withReaderCancellationChecks(checkActive)
                }.also { checkActive() },
            imageStyle = config.normalizedImageStyle(),
        )
    }

    private data class PageAccumulator(
        val index: Int,
        val pageStartPosition: Int = 0,
        val fragments: MutableList<ReaderPageFragment> = mutableListOf(),
        val previewParts: MutableList<String> = mutableListOf(),
        val pageTextParts: MutableList<String> = mutableListOf(),
        var usedHeight: Float = 0f,
    )

    private data class WrappedLine(
        val text: String,
        val length: Int,
        val isContinuationLine: Boolean,
    )

    private class PaginationMetrics(
        private val config: ReaderPaginationConfig,
        viewport: ReaderViewport,
    ) {
        private val contentWidth = max(
            viewport.width - config.paddingLeft - config.paddingRight,
            1f,
        )

        val availableWidth: Float = contentWidth
        val availableHeight: Float = max(
            viewport.height - config.paddingTop - config.paddingBottom,
            1f,
        )
        private val bodyTextMetrics = textMetricsFor(ReaderPageFragmentKind.PARAGRAPH)
        val bodyLineHeight: Float = bodyTextMetrics.lineHeight
        val paragraphSpacingHeight: Float = bodyTextMetrics.lineHeight * config.paragraphSpacing / 10f

        fun textMetricsFor(kind: ReaderPageFragmentKind): TextMetrics {
            val fontSize = if (kind == ReaderPageFragmentKind.HEADING) {
                config.titleFontSize
            } else {
                config.fontSize
            }
            val baseLineHeight = fontSize * 1.2f
            return TextMetrics(
                fontSize = fontSize,
                lineHeight = ceil(max(baseLineHeight * max(config.lineSpacingMultiplier, 0.2f), 4f).toDouble()).toFloat(),
                letterSpacing = config.letterSpacing * fontSize,
            )
        }

        fun estimatedImageHeight(imageStyle: String): Float {
            return when (imageStyle) {
                IMAGE_STYLE_TEXT -> bodyLineHeight
                IMAGE_STYLE_FULL -> min(availableHeight, max(availableHeight * 0.72f, bodyLineHeight * 8f))
                IMAGE_STYLE_SINGLE -> availableHeight
                else -> min(availableHeight, max(bodyLineHeight * 6f, 120f))
            }
        }
    }

    private data class TextMetrics(
        val fontSize: Float,
        val lineHeight: Float,
        val letterSpacing: Float,
    )

    private fun wrapText(
        text: String,
        width: Float,
        metrics: TextMetrics,
        indentCount: Int,
        checkActive: () -> Unit,
    ): List<WrappedLine> {
        checkActive()
        if (text.isEmpty()) return emptyList()
        val lines = mutableListOf<WrappedLine>()
        var index = 0
        var lineNumber = 0
        var charactersUntilCheck = 0
        while (index < text.length) {
            checkActive()
            val indentWidth = if (lineNumber == 0) {
                estimatedIndentWidth(metrics.fontSize) * indentCount
            } else {
                0f
            }
            val maxWidth = max(width - indentWidth, estimatedCharWidth('中', metrics))
            var currentWidth = 0f
            var end = index
            while (end < text.length) {
                if (charactersUntilCheck == 0) {
                    checkActive()
                    charactersUntilCheck = 256
                }
                charactersUntilCheck--
                val char = text[end]
                val charWidth = estimatedCharWidth(char, metrics)
                if (currentWidth > 0f && currentWidth + charWidth > maxWidth) {
                    break
                }
                currentWidth += charWidth
                end += 1
            }
            if (end == index) {
                end = min(index + 1, text.length)
            }
            val lineText = text.substring(index, end)
            lines += WrappedLine(
                text = lineText,
                length = lineText.length,
                isContinuationLine = lineNumber > 0,
            )
            index = end
            lineNumber += 1
        }
        checkActive()
        return lines
    }

    private fun estimatedCharWidth(
        char: Char,
        metrics: TextMetrics,
    ): Float {
        val base = when {
            char == '　' -> metrics.fontSize
            char.isWhitespace() -> metrics.fontSize * 0.32f
            isWideChar(char) -> metrics.fontSize * 0.95f
            else -> metrics.fontSize * 0.56f
        }
        return base + metrics.letterSpacing
    }

    private fun estimatedIndentWidth(fontSize: Float): Float {
        return fontSize * 0.95f
    }

    private fun isWideChar(char: Char): Boolean {
        val code = char.code
        return code in 0x2E80..0x9FFF || code in 0xF900..0xFAFF || code in 0xFF01..0xFF60
    }

    private fun convertText(text: String, mode: Int): String {
        return text
    }
}

private const val IMAGE_STYLE_DEFAULT = "DEFAULT"
private const val IMAGE_STYLE_FULL = "FULL"
private const val IMAGE_STYLE_TEXT = "TEXT"
private const val IMAGE_STYLE_SINGLE = "SINGLE"

private fun ReaderPaginationConfig.normalizedImageStyle(): String {
    return when (imageStyle?.uppercase()) {
        IMAGE_STYLE_FULL -> IMAGE_STYLE_FULL
        IMAGE_STYLE_TEXT -> IMAGE_STYLE_TEXT
        IMAGE_STYLE_SINGLE -> IMAGE_STYLE_SINGLE
        else -> IMAGE_STYLE_DEFAULT
    }
}

private fun List<ReaderContentBlock>.withTitleVisibility(
    config: ReaderPaginationConfig,
    content: String,
    checkActive: () -> Unit,
): List<ReaderContentBlock> {
    checkActive()
    if (config.titleMode != 2) return this
    // CR/LF normalization cannot change whether the chapter contains non-whitespace text.
    val hasChapterContent = content.withReaderCancellationChecks(checkActive).any { !it.isWhitespace() }
    if (!hasChapterContent) return this
    return dropFirstHeading(checkActive)
}

private fun List<ReaderContentBlock>.dropFirstHeading(checkActive: () -> Unit): List<ReaderContentBlock> {
    val first = firstOrNull() ?: return this
    if (first.type != ReaderContentBlockType.HEADING) return this
    return subList(1, size).map {
        checkActive()
        it
    }
}
