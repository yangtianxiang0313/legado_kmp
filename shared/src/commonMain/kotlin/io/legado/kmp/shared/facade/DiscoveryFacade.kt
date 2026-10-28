package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ExploreBooksUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetExploreKindsUseCase
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourcePart
import io.legado.kmp.shared.model.ExploreKind
import io.legado.kmp.shared.model.SearchBook

class DiscoveryFacade(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val getExploreKindsUseCase: GetExploreKindsUseCase,
    private val exploreBooksUseCase: ExploreBooksUseCase,
) {
    fun watchEnabledSourceParts(onUpdate: (List<BookSourcePart>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase.observeEnabledExploreParts(), onUpdate)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadExploreKinds(sourceUrl: String, forceRefresh: Boolean = false): List<ExploreKind> {
        return runRecoverable("DiscoveryFacade.loadExploreKinds") {
            val source = requireSource(sourceUrl)
            if (forceRefresh) {
                getExploreKindsUseCase.clearCache(source)
            }
            getExploreKindsUseCase(source).getOrThrow()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearExploreKinds(sourceUrl: String) {
        return runRecoverable("DiscoveryFacade.clearExploreKinds") {
            getExploreKindsUseCase.clearCache(requireSource(sourceUrl))
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadExploreBooks(sourceUrl: String, exploreUrl: String, page: Int = 1): List<SearchBook> {
        return runRecoverable("DiscoveryFacade.loadExploreBooks") {
            exploreBooksUseCase(requireSource(sourceUrl), exploreUrl, page).getOrThrow()
        }
    }

    private suspend fun requireSource(sourceUrl: String): BookSource {
        return requireNotNull(getBookSourcesUseCase.getByUrl(sourceUrl)) {
            "Book source not found: $sourceUrl"
        }
    }
}
