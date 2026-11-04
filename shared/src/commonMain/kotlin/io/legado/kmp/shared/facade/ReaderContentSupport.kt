package io.legado.kmp.shared.facade

import io.legado.kmp.shared.content.BookImageMarkup

private val noReaderContentCancellationCheck: () -> Unit = {}

internal fun buildReaderContentBlocks(
    chapterTitle: String,
    content: String,
    checkActive: () -> Unit = noReaderContentCancellationCheck,
    imageBaseUrl: String = "",
): List<ReaderContentBlock> {
    return buildReaderContent(chapterTitle, content, checkActive, imageBaseUrl).blocks
}

internal fun buildReaderContent(
    chapterTitle: String,
    content: String,
    checkActive: () -> Unit = noReaderContentCancellationCheck,
    imageBaseUrl: String = "",
    includeInlineImages: Boolean = false,
): ReaderContentBuildResult {
    checkActive()
    val blocks = mutableListOf<ReaderContentBlock>()
    val inlineImages = if (includeInlineImages) ReaderInlineImageCollector(checkActive) else null
    var nextBlockIndex = 0
    chapterTitle.withReaderCancellationChecks(checkActive).trim().toString().takeIf { it.isNotEmpty() }?.let { title ->
        blocks += ReaderContentBlock(
            blockIndex = nextBlockIndex++,
            type = ReaderContentBlockType.HEADING,
            text = title,
        )
    }

    val normalized = content.normalizeReaderLineEndings(checkActive)
        .withReaderCancellationChecks(checkActive)
        .trim()
        .toString()

    if (normalized.isEmpty()) {
        return ReaderContentBuildResult(
            blocks = blocks.ifEmpty {
                listOf(ReaderContentBlock(blockIndex = nextBlockIndex, type = ReaderContentBlockType.PARAGRAPH, text = ""))
            },
        )
    }

    val paragraphSeparator = Regex("""\n\s*\n+""")

    fun appendTextParagraphs(rawText: String) {
        checkActive()
        val paragraphCandidates = paragraphSeparator
            .splitToSequence(rawText.normalizeReaderLineEndings(checkActive).withReaderCancellationChecks(checkActive))
        var firstCandidate = true
        for (candidate in paragraphCandidates) {
            if (!firstCandidate) inlineImages?.endParagraph()
            firstCandidate = false
            val rawParagraph = candidate.withReaderCancellationChecks(checkActive).trim().toString()
            if (rawParagraph.isEmpty()) {
                inlineImages?.appendWhitespace(candidate)
                continue
            }
            val firstBlockIndex = nextBlockIndex
            val strippedText = rawParagraph.stripSimpleHtml(
                checkActive,
                onUntrimmedText = inlineImages?.let { collector ->
                    { text: String -> collector.appendText(candidate, rawParagraph.length, text, firstBlockIndex) }
                },
            )
            splitReadableParagraphs(strippedText, checkActive).forEach { paragraph ->
                checkActive()
                blocks += ReaderContentBlock(
                    blockIndex = nextBlockIndex++,
                    type = ReaderContentBlockType.PARAGRAPH,
                    text = paragraph,
                )
            }
        }
    }

    // Android ContentProcessor drops blank lines; paragraph spacing belongs to layout, not spacer blocks.
    var cursor = 0
    for (image in BookImageMarkup.images(content, checkActive)) {
        checkActive()
        if (image.range.first > cursor) {
            appendTextParagraphs(content.substring(cursor, image.range.first))
        }
        if (image.source.withReaderCancellationChecks(checkActive).isNotBlank()) {
            inlineImages?.appendImage(nextBlockIndex)
            blocks += ReaderContentBlock(
                blockIndex = nextBlockIndex++,
                type = ReaderContentBlockType.IMAGE,
                imageUrl = BookImageMarkup.absoluteSource(image.source, imageBaseUrl),
                imageAlt = image.alt?.withReaderCancellationChecks(checkActive)?.trim()?.toString()?.ifEmpty { null },
            )
        }
        cursor = image.range.last + 1
    }
    if (cursor < content.length) {
        appendTextParagraphs(content.substring(cursor))
    }

    checkActive()
    return ReaderContentBuildResult(
        blocks = blocks.ifEmpty {
            listOf(ReaderContentBlock(blockIndex = nextBlockIndex, type = ReaderContentBlockType.PARAGRAPH, text = normalized.stripSimpleHtml(checkActive)))
        },
        inlineImageParagraphs = inlineImages?.build().orEmpty(),
    )
}

private fun String.stripSimpleHtml(
    checkActive: () -> Unit,
    onUntrimmedText: ((String) -> Unit)? = null,
): String {
    var text = this
    for ((pattern, replacement) in listOf(
        Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE) to "\n",
        Regex("""</p>""", RegexOption.IGNORE_CASE) to "\n",
        Regex("""<[^>]+>""") to "",
        Regex("""\n{3,}""") to "\n\n",
    )) {
        checkActive()
        text = pattern.replace(text.withReaderCancellationChecks(checkActive), replacement)
    }
    onUntrimmedText?.invoke(text)
    return text.withReaderCancellationChecks(checkActive)
        .trim()
        .toString()
}

private fun splitReadableParagraphs(text: String, checkActive: () -> Unit): Sequence<String> {
    return text
        .normalizeReaderLineEndings(checkActive)
        .withReaderCancellationChecks(checkActive)
        .splitToSequence('\n')
        .map { it.withReaderCancellationChecks(checkActive).trim().toString() }
        .filter { it.isNotEmpty() }
}

internal fun String.normalizeReaderLineEndings(checkActive: () -> Unit): String {
    if (checkActive === noReaderContentCancellationCheck) {
        return replace("\r\n", "\n").replace('\r', '\n')
    }
    if (withReaderCancellationChecks(checkActive).indexOf('\r') < 0) return this
    val normalized = StringBuilder(length)
    var index = 0
    var charactersUntilCheck = 0
    while (index < length) {
        if (charactersUntilCheck <= 0) {
            checkActive()
            charactersUntilCheck = 256
        }
        val char = this[index++]
        charactersUntilCheck--
        if (char == '\r') {
            normalized.append('\n')
            if (index < length && this[index] == '\n') {
                index++
                charactersUntilCheck--
            }
        } else {
            normalized.append(char)
        }
    }
    checkActive()
    return normalized.toString()
}

internal fun String.withReaderCancellationChecks(checkActive: () -> Unit): CharSequence {
    checkActive()
    return if (checkActive === noReaderContentCancellationCheck) this else ReaderCheckedText(this, checkActive)
}

// Keep the full regex input and UTF-16 indices intact, including matches spanning any check interval.
private class ReaderCheckedText(
    private val text: CharSequence,
    private val checkActive: () -> Unit,
) : CharSequence {
    private var charactersUntilCheck = 0

    override val length: Int get() = text.length

    override fun get(index: Int): Char {
        if (charactersUntilCheck == 0) {
            checkActive()
            charactersUntilCheck = 256
        }
        charactersUntilCheck--
        return text[index]
    }

    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence {
        checkActive()
        return ReaderCheckedText(text.subSequence(startIndex, endIndex), checkActive)
    }

    override fun toString(): String {
        checkActive()
        return text.toString()
    }
}
