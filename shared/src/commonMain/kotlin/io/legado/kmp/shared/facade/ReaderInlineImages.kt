package io.legado.kmp.shared.facade

/** TEXT rendering hints only; legacy blocks and chapter positions remain authoritative. */
data class ReaderInlineImageParagraph(
    val runs: List<ReaderInlineImageRun>,
)

/**
 * textStart/textLength locate the unchanged, trimmed block text inside displayText.
 * All offsets are UTF-16; blockIndex retains the existing chapter-coordinate identity.
 * A null displayText references an existing image block, with a zero-length text range.
 * Virtual whitespace has blockIndex -1 and a zero-length range; adjacent real runs anchor it.
 */
data class ReaderInlineImageRun(
    val blockIndex: Int,
    val displayText: String?,
    val textStart: Int,
    val textLength: Int,
)

internal data class ReaderContentBuildResult(
    val blocks: List<ReaderContentBlock>,
    val inlineImageParagraphs: List<ReaderInlineImageParagraph> = emptyList(),
)

internal class ReaderInlineImageCollector(
    private val checkActive: () -> Unit,
) {
    private val paragraphs = mutableListOf<ReaderInlineImageParagraph>()
    private val runs = mutableListOf<ReaderInlineImageRun>()
    private val pendingWhitespace = mutableListOf<String>()
    private var hasImage = false

    fun appendText(
        rawCandidate: String,
        trimmedCandidateLength: Int,
        strippedText: String,
        firstBlockIndex: Int,
    ) {
        checkActive()
        val candidateStart = rawCandidate.withReaderCancellationChecks(checkActive)
            .indexOfFirst { !it.isWhitespace() }
        if (candidateStart < 0) {
            appendWhitespace(rawCandidate)
            return
        }
        appendWhitespace(rawCandidate.substring(0, candidateStart))

        var blockIndex = firstBlockIndex
        val lines = strippedText.normalizeReaderLineEndings(checkActive)
            .withReaderCancellationChecks(checkActive)
            .splitToSequence('\n')
        var firstLine = true
        for (line in lines) {
            checkActive()
            if (!firstLine) endParagraph()
            firstLine = false
            val text = line.withReaderCancellationChecks(checkActive).trim().toString()
            if (text.isEmpty()) {
                appendWhitespace(line)
                continue
            }
            val textStart = line.withReaderCancellationChecks(checkActive)
                .indexOfFirst { !it.isWhitespace() }
            appendWhitespace(line.substring(0, textStart))
            appendRun(
                ReaderInlineImageRun(
                    blockIndex = blockIndex++,
                    displayText = text,
                    textStart = 0,
                    textLength = text.length,
                ),
            )
            appendWhitespace(line.substring(textStart + text.length))
        }

        appendWhitespace(rawCandidate.substring(candidateStart + trimmedCandidateLength))
    }

    fun appendWhitespace(text: String) {
        checkActive()
        var firstLine = true
        for (line in text.withReaderCancellationChecks(checkActive).splitToSequence('\n')) {
            checkActive()
            if (!firstLine) endParagraph()
            firstLine = false
            if (line.isNotEmpty() && runs.isNotEmpty()) {
                pendingWhitespace += line
            }
        }
    }

    fun appendImage(blockIndex: Int) {
        checkActive()
        appendRun(
            ReaderInlineImageRun(
                blockIndex = blockIndex,
                displayText = null,
                textStart = 0,
                textLength = 0,
            ),
        )
        hasImage = true
    }

    fun endParagraph() {
        checkActive()
        if (hasImage) {
            paragraphs += ReaderInlineImageParagraph(
                runs = runs.map {
                    checkActive()
                    it
                },
            )
        }
        runs.clear()
        pendingWhitespace.clear()
        hasImage = false
    }

    fun build(): List<ReaderInlineImageParagraph> {
        endParagraph()
        return paragraphs.map {
            checkActive()
            it
        }.also { checkActive() }
    }

    private fun appendRun(run: ReaderInlineImageRun) {
        checkActive()
        // Delay whitespace until another real run arrives so paragraph-edge trim stays intact.
        for (whitespace in pendingWhitespace) {
            checkActive()
            runs += ReaderInlineImageRun(
                blockIndex = -1,
                displayText = whitespace,
                textStart = 0,
                textLength = 0,
            )
        }
        pendingWhitespace.clear()
        runs += run
    }
}
