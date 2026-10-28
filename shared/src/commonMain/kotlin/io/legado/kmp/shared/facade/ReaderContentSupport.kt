package io.legado.kmp.shared.facade

internal fun buildReaderContentBlocks(
    chapterTitle: String,
    content: String,
): List<ReaderContentBlock> {
    val blocks = mutableListOf<ReaderContentBlock>()
    var nextBlockIndex = 0
    chapterTitle.trim().takeIf { it.isNotEmpty() }?.let { title ->
        blocks += ReaderContentBlock(
            blockIndex = nextBlockIndex++,
            type = ReaderContentBlockType.HEADING,
            text = title,
        )
    }

    val normalized = content
        .replace("\r\n", "\n")
        .replace('\r', '\n')
        .trim()

    if (normalized.isEmpty()) {
        return blocks.ifEmpty {
            listOf(ReaderContentBlock(blockIndex = nextBlockIndex, type = ReaderContentBlockType.PARAGRAPH, text = ""))
        }
    }

    val imageRegex = Regex("""<img[^>]+src=['"]([^'"]+)['"][^>]*?(?:alt=['"]([^'"]*)['"])?[^>]*>""", RegexOption.IGNORE_CASE)
    val paragraphCandidates = normalized
        .split(Regex("""\n\s*\n+"""))
        .map { it.trim() }
        .filter { it.isNotEmpty() }

    fun appendTextParagraphs(rawText: String) {
        splitReadableParagraphs(rawText.stripSimpleHtml()).forEach { paragraph ->
            blocks += ReaderContentBlock(
                blockIndex = nextBlockIndex++,
                type = ReaderContentBlockType.PARAGRAPH,
                text = paragraph,
            )
        }
    }

    // Android ContentProcessor drops blank lines; paragraph spacing belongs to layout, not spacer blocks.
    paragraphCandidates.forEach { rawBlock ->
        var cursor = 0
        val imageMatches = imageRegex.findAll(rawBlock)
        for (match in imageMatches) {
            if (match.range.first > cursor) {
                appendTextParagraphs(rawBlock.substring(cursor, match.range.first))
            }
            val imageUrl = match.groupValues.getOrNull(1)?.trim().orEmpty()
            if (imageUrl.isNotEmpty()) {
                blocks += ReaderContentBlock(
                    blockIndex = nextBlockIndex++,
                    type = ReaderContentBlockType.IMAGE,
                    imageUrl = imageUrl,
                    imageAlt = match.groupValues.getOrNull(2)?.trim()?.ifEmpty { null },
                )
            }
            cursor = match.range.last + 1
        }
        if (cursor < rawBlock.length) {
            appendTextParagraphs(rawBlock.substring(cursor))
        }
    }

    return blocks.ifEmpty {
        listOf(ReaderContentBlock(blockIndex = nextBlockIndex, type = ReaderContentBlockType.PARAGRAPH, text = normalized.stripSimpleHtml()))
    }
}

private fun String.stripSimpleHtml(): String {
    return replace(Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE), "\n")
        .replace(Regex("""</p>""", RegexOption.IGNORE_CASE), "\n")
        .replace(Regex("""<[^>]+>"""), "")
        .replace(Regex("""\n{3,}"""), "\n\n")
        .trim()
}

private fun splitReadableParagraphs(text: String): List<String> {
    return text
        .replace("\r\n", "\n")
        .replace('\r', '\n')
        .split('\n')
        .map { it.trim() }
        .filter { it.isNotEmpty() }
}
