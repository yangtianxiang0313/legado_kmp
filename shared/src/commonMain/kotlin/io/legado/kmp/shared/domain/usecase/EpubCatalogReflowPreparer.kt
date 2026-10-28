package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.EpubCatalogReflowPlan
import io.legado.kmp.shared.domain.localbook.EpubReflowText
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.LocalBookFileStore
import io.legado.kmp.shared.domain.localbook.ZipEpubBookParser
import io.legado.kmp.shared.domain.localbook.needsEpubCatalogReflow
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.ReplaceRuleRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Read-only preparation; validate again under the book-save lock before starting a transaction. */
class EpubCatalogReflowPreparation internal constructor(
    val plan: EpubCatalogReflowPlan,
    private val validation: suspend () -> Unit,
) {
    internal suspend fun validate() {
        currentCoroutineContext().ensureActive()
        validation()
        currentCoroutineContext().ensureActive()
    }
}

class EpubCatalogReflowPreparer(
    private val localBookFileResolver: LocalBookFileResolver,
    private val epubBookParser: ZipEpubBookParser,
    private val chapterContentRepository: ChapterContentRepository,
    private val replaceRuleRepository: ReplaceRuleRepository,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val contentProcessor: ContentProcessor,
    private val preferencesStore: AppPreferencesStore,
    private val fileStore: LocalBookFileStore,
) {
    suspend fun prepare(
        current: Book,
        replacement: Book,
        previous: List<BookChapter>,
        chapters: List<BookChapter>,
    ): EpubCatalogReflowPreparation? {
        currentCoroutineContext().ensureActive()
        if (!current.isLocal || !current.isEpub || previous.isEmpty() ||
            !needsEpubCatalogReflow(previous, chapters)
        ) return null
        require(replacement.isLocal && replacement.isEpub) { "EPUB replacement is not a local EPUB book" }

        val oldBook = current.copy(readConfig = current.readConfig?.copy())
        val newBook = replacement.copy(readConfig = replacement.readConfig?.copy())
        val resolvedCurrent = resolveExisting(oldBook)
        val resolvedReplacement = resolveExisting(newBook)
        check(resolvedCurrent.bookUrl == resolvedReplacement.bookUrl) {
            "EPUB source file identity changed; original catalog and reading state were preserved"
        }
        val file = readFileSnapshot(resolvedCurrent.bookUrl)
        val profile = readProfile()
        val capturedRuleReader = object : ReplaceRuleRepository by replaceRuleRepository {
            override suspend fun getAllRules(): List<ReplaceRule> = profile.rules
            override suspend fun getEnabledRules(): List<ReplaceRule> = profile.rules.filter { it.isEnabled }
        }
        val capturedApplyRules = ApplyReplaceRulesUseCase(capturedRuleReader)
        val capturedProcessor = ContentProcessor(capturedApplyRules)
        val contentReads = linkedMapOf<ChapterReadKey, ContentReadSnapshot>()
        val titleFlags = linkedMapOf<ChapterReadKey, TitleFlagSnapshot>()

        // Inspect real cache paths on both sides, including legacy index/title and URL aliases.
        // Only cached bodies need a span lookup; absent bodies cannot override the EPUB reader.
        captureCatalogContent(resolvedCurrent, previous, chapters, contentReads)
        captureCatalogContent(resolvedReplacement, chapters, previous, contentReads)

        val plan = epubBookParser.prepareCatalogReflow(
            current = resolvedCurrent,
            replacement = resolvedReplacement,
            previous = previous,
            chapters = chapters,
        ) { book, chapter, rawContent, actualChapter ->
            currentCoroutineContext().ensureActive()
            checkChineseMode(profile)
            val displayTitle = resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
            currentCoroutineContext().ensureActive()
            val content = if (actualChapter) {
                val cached = chapterContentRepository.getContent(book, chapter)
                currentCoroutineContext().ensureActive()
                rememberContent(book, chapter, cached, contentReads)
                cached ?: rawContent
            } else {
                rawContent
            }
            val removeSameTitle = if (actualChapter) {
                val remove = chapterContentRepository.removeSameTitle(book, chapter)
                currentCoroutineContext().ensureActive()
                val key = ChapterReadKey.of(book, chapter)
                val previousFlag = titleFlags[key]
                check(previousFlag == null || previousFlag.removeSameTitle == remove) {
                    "EPUB chapter title-removal marker changed during preparation; original data were preserved"
                }
                titleFlags[key] = TitleFlagSnapshot(book, chapter, remove)
                remove
            } else {
                false
            }
            val useReplace = book.config.useReplaceRule ?: false
            suspend fun processWith(processor: ContentProcessor): ContentProcessor.Result = processor.process(
                book = book,
                chapter = chapter,
                content = content,
                displayTitle = displayTitle,
                useReplace = useReplace,
                chineseConvert = profile.chineseMode,
                shouldRemoveSameTitle = removeSameTitle,
            )
            val processed = processWith(contentProcessor)
            currentCoroutineContext().ensureActive()
            if (useReplace) {
                // A change-and-revert between profile samples must not leave mixed-rule geometry.
                val capturedTitle = resolveDisplayChapterTitle(book, chapter, capturedApplyRules)
                currentCoroutineContext().ensureActive()
                check(displayTitle == capturedTitle && processed == processWith(capturedProcessor)) {
                    "EPUB text does not match the captured replacement rules; original data were preserved"
                }
            }
            currentCoroutineContext().ensureActive()
            checkChineseMode(profile)
            EpubReflowText(content = processed.content, displayTitle = displayTitle)
        } ?: return null
        currentCoroutineContext().ensureActive()

        // Keep signatures/digests, not chapter bodies or a process-wide plan-to-profile cache.
        val capturedContent = contentReads.values.toList()
        val capturedFlags = titleFlags.values.toList()
        return EpubCatalogReflowPreparation(plan) {
            check(current.readConfig == oldBook.readConfig && replacement.readConfig == newBook.readConfig) {
                "EPUB reading configuration changed during preparation; original data were preserved"
            }
            validateProfile(profile)
            validateFile(file)
            for (snapshot in capturedContent) {
                currentCoroutineContext().ensureActive()
                val content = chapterContentRepository.getContent(snapshot.book, snapshot.chapter)
                currentCoroutineContext().ensureActive()
                check(contentDigest(content) == snapshot.digest) {
                    "EPUB chapter cache changed after preparation; original catalog and reading state were preserved"
                }
            }
            for (snapshot in capturedFlags) {
                currentCoroutineContext().ensureActive()
                val remove = chapterContentRepository.removeSameTitle(snapshot.book, snapshot.chapter)
                currentCoroutineContext().ensureActive()
                check(remove == snapshot.removeSameTitle) {
                    "EPUB chapter title-removal marker changed after preparation; original data were preserved"
                }
            }
            validateFile(file)
            validateProfile(profile)
        }.also { it.validate() }
    }

    private suspend fun resolveExisting(book: Book): Book {
        currentCoroutineContext().ensureActive()
        check(fileStore.lastModified(book.bookUrl) != null) {
            "EPUB source is unavailable; recover the book before preparing a catalog change"
        }
        currentCoroutineContext().ensureActive()
        // Recovery/download is a write operation, even if the source disappears between checks.
        // Resolve only the existing path, then retain the real metadata for rule/cache scoping.
        val resolved = localBookFileResolver.resolve(book.copy(origin = BookType.LOCAL_TAG))
        currentCoroutineContext().ensureActive()
        check(resolved.bookUrl == book.bookUrl) { "EPUB source path changed during preparation" }
        return book
    }

    private suspend fun captureCatalogContent(
        book: Book,
        chapters: List<BookChapter>,
        opposite: List<BookChapter>,
        reads: MutableMap<ChapterReadKey, ContentReadSnapshot>,
    ) {
        for (chapter in chapters) {
            currentCoroutineContext().ensureActive()
            if (chapter.isVolume) continue
            val content = chapterContentRepository.getContent(book, chapter)
            currentCoroutineContext().ensureActive()
            check(content == null || !needsEpubCatalogReflow(listOf(chapter), opposite)) {
                "EPUB chapter boundaries changed and a local cached/edited body exists; original data were preserved"
            }
            rememberContent(book, chapter, content, reads)
        }
    }

    private suspend fun rememberContent(
        book: Book,
        chapter: BookChapter,
        content: String?,
        reads: MutableMap<ChapterReadKey, ContentReadSnapshot>,
    ) {
        val key = ChapterReadKey.of(book, chapter)
        val digest = contentDigest(content)
        val previous = reads[key]
        check(previous == null || previous.digest == digest) {
            "EPUB chapter cache changed during preparation; original catalog and reading state were preserved"
        }
        reads[key] = ContentReadSnapshot(book, chapter, digest)
    }

    private suspend fun contentDigest(content: String?): ByteString? {
        currentCoroutineContext().ensureActive()
        if (content == null) return null
        check(content.length <= MAX_CACHED_CHAPTER_CHARACTERS) {
            "EPUB cached chapter exceeds the bounded reflow preparation budget; original data were preserved"
        }
        return content.encodeUtf8().sha256().also { currentCoroutineContext().ensureActive() }
    }

    private suspend fun readProfile(): ReflowReadProfile {
        currentCoroutineContext().ensureActive()
        val rules = replaceRuleRepository.getAllRules().toList()
        currentCoroutineContext().ensureActive()
        val chineseMode = preferencesStore.runtimeConfig.first().reader.chineseMode
        currentCoroutineContext().ensureActive()
        return ReflowReadProfile(rules, chineseMode)
    }

    private suspend fun validateProfile(expected: ReflowReadProfile) {
        check(readProfile() == expected) {
            "EPUB replacement rules or Chinese mode changed after preparation; original data were preserved"
        }
    }

    private fun checkChineseMode(expected: ReflowReadProfile) {
        check(preferencesStore.runtimeConfig.value.reader.chineseMode == expected.chineseMode) {
            "EPUB Chinese mode changed during preparation; original data were preserved"
        }
    }

    private suspend fun readFileSnapshot(path: String): ReflowFileSnapshot {
        currentCoroutineContext().ensureActive()
        val modified = checkNotNull(fileStore.lastModified(path)) {
            "EPUB source modification time is unavailable; original data were preserved"
        }
        currentCoroutineContext().ensureActive()
        val source = fileStore.openRead(path)
        val size = try {
            currentCoroutineContext().ensureActive()
            source.size
        } finally {
            source.closeSource()
        }
        currentCoroutineContext().ensureActive()
        check(fileStore.lastModified(path) == modified) {
            "EPUB source changed while taking its snapshot; original data were preserved"
        }
        currentCoroutineContext().ensureActive()
        return ReflowFileSnapshot(path, modified, size)
    }

    private suspend fun validateFile(expected: ReflowFileSnapshot) {
        check(readFileSnapshot(expected.path) == expected) {
            "EPUB source file changed after preparation; original catalog and reading state were preserved"
        }
    }

    private companion object {
        const val MAX_CACHED_CHAPTER_CHARACTERS = 8 * 1024 * 1024
    }
}

private data class ReflowReadProfile(val rules: List<ReplaceRule>, val chineseMode: Int)

private data class ReflowFileSnapshot(val path: String, val modified: Long, val size: Long)

// BookChapter.equals only compares URLs; neither legacy cache paths nor flags use that identity.
private data class ChapterReadKey(
    val bookUrl: String,
    val bookName: String,
    val chapterUrl: String,
    val chapterIndex: Int,
    val chapterTitle: String,
) {
    companion object {
        fun of(book: Book, chapter: BookChapter): ChapterReadKey = ChapterReadKey(
            book.bookUrl, book.name, chapter.url, chapter.index, chapter.title,
        )
    }
}

private data class ContentReadSnapshot(val book: Book, val chapter: BookChapter, val digest: ByteString?)

private data class TitleFlagSnapshot(val book: Book, val chapter: BookChapter, val removeSameTitle: Boolean)
