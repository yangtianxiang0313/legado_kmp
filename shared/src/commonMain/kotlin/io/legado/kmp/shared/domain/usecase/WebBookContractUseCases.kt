package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.domain.repository.WebBookChapterContent
import io.legado.kmp.shared.domain.webBook.BookContent
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.flow.Flow

class ObserveBookChaptersUseCase(
    private val repository: BookChapterRepository
) {
    operator fun invoke(bookUrl: String): Flow<List<BookChapter>> {
        return repository.observeChaptersByBookUrl(bookUrl)
    }
}

class RefreshBookInfoUseCase(
    private val repository: WebBookRepository
) {
    suspend operator fun invoke(
        source: BookSource,
        bookUrl: String
    ): Result<Book> {
        return repository.getBookInfo(source, bookUrl)
    }

    suspend operator fun invoke(
        source: BookSource,
        book: Book,
        canReName: Boolean = true,
        debugSink: BookSourceDebugSink? = null,
    ): Result<Book> {
        // Refresh from the network without carrying transient infoHtml/tocHtml caches.
        return repository.getBookInfo(source, book.copy(), canReName, debugSink)
    }
}

class LoadChapterContentUseCase(
    private val repository: WebBookRepository
) {
    suspend operator fun invoke(
        source: BookSource,
        book: Book,
        chapter: BookChapter
    ): Result<String> {
        return repository.getChapterContent(source, book, chapter)
    }

    suspend fun loadWithChapter(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
    ): Result<WebBookChapterContent> {
        return repository.getChapterContentWithChapter(source, book, chapter)
    }
}

class FetchChapterListContractUseCase(
    private val useCase: FetchChapterListUseCase
) {
    suspend operator fun invoke(
        source: BookSource,
        book: Book,
        runPreUpdateJs: Boolean = false,
        debugSink: BookSourceDebugSink? = null,
    ): Result<ChapterListLoadResult> {
        return useCase(source, book, runPreUpdateJs, debugSink)
    }
}

class GetPayActionUseCase(
    private val sourceStateStore: SourceStateStore,
    private val jsExecutor: JsExecutor,
    private val connectGateway: LegacyJsConnectGateway? = null,
    private val headerResolver: SourceHeaderResolver? = null,
    private val sourceJsRuntime: SourceJsRuntime? = null
) {
    suspend operator fun invoke(
        source: BookSource,
        book: Book,
        chapter: BookChapter
    ): Result<String> = runCatching {
        BookContent.getPayAction(
            bookSource = source,
            book = book,
            chapter = chapter,
            loginHeader = sourceStateStore.getLoginHeader(source.bookSourceUrl),
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
    }
}
