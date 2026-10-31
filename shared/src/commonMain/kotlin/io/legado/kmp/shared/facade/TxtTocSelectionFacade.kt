package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.LocalBookFileBinding
import io.legado.kmp.shared.domain.localbook.LocalBookFileStore
import io.legado.kmp.shared.domain.localbook.TxtBookParser
import io.legado.kmp.shared.domain.localbook.TxtChapterIdentity
import io.legado.kmp.shared.domain.localbook.hashBookArchiveSource
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.BookmarkRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.ReplaceRuleRepository
import io.legado.kmp.shared.domain.repository.TxtCatalogBookmarkLocation
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ContentProcessor
import io.legado.kmp.shared.domain.usecase.GetTxtTocRulesUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.Bookmark
import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.model.TxtTocRule
import io.legado.kmp.shared.model.isTxtLocalBook
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import okio.ByteString.Companion.encodeUtf8
import org.koin.mp.KoinPlatformTools

data class TxtTocSelectionState(val book: Book, val rules: List<TxtTocRule>)

/** Explicit per-book TXT rule selection; parsing cannot publish a partial directory. */
class TxtTocSelectionFacade(
    private val books: BookRepository,
    private val chapters: BookChapterRepository,
    private val bookmarks: BookmarkRepository,
    private val content: ChapterContentRepository,
    private val files: LocalBookFileStore,
    private val parser: TxtBookParser,
    private val rules: GetTxtTocRulesUseCase,
    private val replacementRules: ReplaceRuleRepository,
    private val preferences: AppPreferencesStore,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): TxtTocSelectionFacade = try {
            SharedBootstrap.startOrThrow()
            KoinPlatformTools.defaultContext().get().get<TxtTocSelectionFacade>()
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("TxtTocSelectionFacade.create")
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadState(bookUrl: String): TxtTocSelectionState = runRecoverable("TxtTocSelection.load") {
        val book = requireTxt(bookUrl)
        TxtTocSelectionState(book, rules.getAll())
    }

    fun prepareApplyRequest(
        bookUrl: String,
        ruleId: Long,
        onResult: (LocalBookImportRequestResult) -> Unit,
    ): LocalBookImportRequest = LocalBookImportRequest.create(
        performImport = { applyRule(bookUrl, ruleId) }, onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun applyRule(bookUrl: String, ruleId: Long): Book = runRecoverable("TxtTocSelection.apply") {
        val context = currentCoroutineContext()
        context.ensureActive()
        val current = requireTxt(bookUrl).let { it.copy(readConfig = it.readConfig?.copy()) }
        val selected = requireNotNull(rules.get(ruleId)) { "所选目录规则已不存在，请重新选择" }
        val automaticRules = if (selected.rule.isBlank()) rules.getEnabled().toList() else emptyList()
        val previous = chapters.getChaptersByBookUrl(bookUrl).map { it.copy() }.sortedBy { it.index }
        val marks = bookmarks.getByBook(current.name, current.author).toList()
        val profile = profile()
        val capturedRepository = object : ReplaceRuleRepository by replacementRules {
            override suspend fun getAllRules(): List<ReplaceRule> = profile.rules
            override suspend fun getEnabledRules(): List<ReplaceRule> = profile.rules.filter { it.isEnabled }
        }
        val apply = ApplyReplaceRulesUseCase(capturedRepository)
        val processor = ContentProcessor(apply)
        val path = LocalBookFileBinding.path(current)
        val modified = requireNotNull(files.lastModified(path)) { "原书文件缺失，请先重新选择原文件" }
        val cache = captureCache(current, previous)
        val source = files.openRead(path)
        val prepared = try {
            val digest = hashBookArchiveSource(source, Long.MAX_VALUE) { context.ensureActive() }
            LocalBookFileBinding.retainedKeyForBook(current)?.let { key ->
                check(key.substringBefore('/').substringAfter('-') == digest.sha256) { "原书留存文件指纹已变化，原目录未改动" }
            }
            val parsed = parser.parseSourceWithRule(
                current, source, automaticRules, selected.rule.takeIf { it.isNotBlank() },
            ) { context.ensureActive() }
            var directory = TxtChapterIdentity.retain(previous, parsed.chapters) { context.ensureActive() }
            if (current.config.reverseToc) directory = directory.asReversed().mapIndexed { index, chapter ->
                chapter.copy(index = index)
            }
            require(directory.isNotEmpty()) { "目录规则未生成可读章节，原目录未改动" }
            val nextByUrl = directory.associateBy { it.url }
            for (old in previous) {
                context.ensureActive()
                if (nextByUrl[old.url] == null) {
                    val oldCache = cache.getValue(old.url)
                    require(oldCache.digest == null && oldCache.removeTitle) {
                        "目录重切会改变已编辑章节或正文标题标记，请先恢复这些章节原文；原目录及正文未改动"
                    }
                }
            }
            val index = current.durChapterIndex.coerceIn(directory.indices)
            var replacement = current.copy(
                tocUrl = parsed.book.tocUrl, charset = parsed.book.charset,
                wordCount = parsed.book.wordCount, totalChapterNum = directory.size,
                latestChapterTitle = directory.last().title, latestChapterTime = modified,
                durChapterIndex = index, durChapterPos = 0,
            )
            replacement = replacement.copy(durChapterTitle = resolveDisplayChapterTitle(replacement, directory[index], apply))
            val locations = TxtCatalogBookmarkMapper(
                source, parser, current, replacement, previous, directory,
                process = { book, chapter, raw ->
                    check(preferences.runtimeConfig.value.reader.chineseMode == profile.chineseMode) {
                        "繁简配置已变化，请重新选择目录规则"
                    }
                    val title = resolveDisplayChapterTitle(book, chapter, apply)
                    processor.process(
                        book, chapter, raw, title, useReplace = book.config.useReplaceRule ?: profile.defaultReplace,
                        chineseConvert = profile.chineseMode,
                        shouldRemoveSameTitle = cache[chapter.url]?.removeTitle ?: true,
                    ).content
                },
                displayTitle = { chapter -> resolveDisplayChapterTitle(replacement, chapter, apply) },
                checkActive = { context.ensureActive() },
            ).map(marks)
            val after = hashBookArchiveSource(source, Long.MAX_VALUE) { context.ensureActive() }
            check(after == digest && files.lastModified(path) == modified) { "原书在重建目录期间变化，原目录未改动" }
            Prepared(replacement, directory, locations, digest.sha256, digest.size)
        } finally {
            source.closeSource()
        }
        context.ensureActive()
        validateRule(selected)
        validateAutomaticRules(selected, automaticRules)
        check(profile() == profile) { "替换规则或繁简配置已变化，请重新选择目录规则" }
        validateCache(current, previous, cache)
        // URL addressing retains old bodies/markers and prevents an old index naming a new chapter.
        if (previous.isNotEmpty() && changed(previous, prepared.chapters)) {
            content.prepareForChapterReorder(current, previous)
            validateCache(current, previous, cache)
        }
        val probe = files.openRead(path)
        try {
            val actual = hashBookArchiveSource(probe, Long.MAX_VALUE) { context.ensureActive() }
            check(actual.sha256 == prepared.sha256 && actual.size == prepared.size && files.lastModified(path) == modified) {
                "原书在提交前变化，原目录未改动"
            }
        } finally {
            probe.closeSource()
        }
        validateRule(selected)
        validateAutomaticRules(selected, automaticRules)
        check(profile() == profile) { "阅读配置已变化，原目录未改动" }
        context.ensureActive()
        // SQL rechecks catalog/profile/progress/bookmarks. No cancellable work follows its acknowledged commit.
        books.replaceTxtCatalogIfUnchanged(
            current, previous, prepared.book, prepared.chapters, marks, prepared.bookmarks,
        ) ?: error("原书、阅读进度、目录或书签已变化，请重新选择目录规则")
    }

    private suspend fun requireTxt(url: String): Book {
        val book = requireNotNull(books.getBook(url)) { "书籍已不在书架中" }
        require(book.isLocal && book.isTxtLocalBook) { "仅本地 TXT 支持目录规则选择" }
        return book
    }

    private suspend fun validateRule(expected: TxtTocRule) {
        val rule = rules.get(expected.id)
        check(rule != null && rule.id == expected.id && rule.name == expected.name && rule.rule == expected.rule &&
            rule.example == expected.example && rule.serialNumber == expected.serialNumber && rule.enable == expected.enable
        ) { "所选目录规则已变化，请重新选择" }
    }

    private suspend fun profile(): Profile {
        val rules = replacementRules.getAllRules().toList()
        val config = preferences.runtimeConfig.first()
        return Profile(rules, config.reader.chineseMode, config.replaceRuleEnabledByDefault)
    }

    private suspend fun validateAutomaticRules(selected: TxtTocRule, expected: List<TxtTocRule>) {
        if (selected.rule.isNotBlank()) return
        fun signature(rule: TxtTocRule) = listOf(
            rule.id.toString(), rule.name, rule.rule, rule.example, rule.serialNumber.toString(), rule.enable.toString(),
        )
        check(rules.getEnabled().map(::signature) == expected.map(::signature)) {
            "自动目录规则已变化，请重新选择"
        }
    }

    private suspend fun captureCache(book: Book, directory: List<BookChapter>): Map<String, Cached> =
        directory.associate { chapter ->
            currentCoroutineContext().ensureActive()
            chapter.url to Cached(content.getContent(book, chapter)?.encodeUtf8()?.sha256()?.hex(),
                content.removeSameTitle(book, chapter))
        }

    private suspend fun validateCache(book: Book, directory: List<BookChapter>, expected: Map<String, Cached>) {
        check(captureCache(book, directory) == expected) { "章节正文或标题标记已变化，原目录未改动" }
    }

    private fun changed(old: List<BookChapter>, next: List<BookChapter>): Boolean = old.size != next.size ||
        old.indices.any { index ->
            val a = old[index]
            val b = next[index]
            a.url != b.url || a.index != b.index || a.start != b.start || a.end != b.end || a.title != b.title
        }

    private data class Profile(val rules: List<ReplaceRule>, val chineseMode: Int, val defaultReplace: Boolean)
    private data class Cached(val digest: String?, val removeTitle: Boolean)
    private data class Prepared(
        val book: Book, val chapters: List<BookChapter>, val bookmarks: List<TxtCatalogBookmarkLocation>,
        val sha256: String, val size: Long,
    )
}
