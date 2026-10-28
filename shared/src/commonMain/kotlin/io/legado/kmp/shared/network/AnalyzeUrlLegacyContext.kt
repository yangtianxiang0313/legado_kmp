package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.scripting.LegacySourceJsRuntime
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore

data class AnalyzeUrlLegacyContext(
    val source: BookSource,
    val sourceStateStore: SourceStateStore? = null,
    val cookieRepository: CookieRepository? = null,
    val gateway: LegacyJsConnectGateway,
    val sourceJsRuntime: SourceJsRuntime? = null,
    val ruleData: Map<String, Any?> = emptyMap(),
    val chapter: BookChapter? = null,
)

internal fun legacySourceJsRuntime(
    sourceJsRuntime: SourceJsRuntime?,
    sourceStateStore: SourceStateStore?,
    cookieRepository: CookieRepository?
): SourceJsRuntime {
    return sourceJsRuntime ?: LegacySourceJsRuntime(
        sourceStateStore = sourceStateStore,
        cookieRepository = cookieRepository
    )
}
