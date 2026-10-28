package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.LocalBookFileNameResolver
import io.legado.kmp.shared.domain.localbook.LocalBookFileNameResult
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

class LocalBookFileNameFacade(
    private val preferencesStore: AppPreferencesStore,
    private val resolver: LocalBookFileNameResolver,
) {
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun load(): String = operation("load") {
        preferencesStore.runtimeConfig.value.bookImportFileName.orEmpty()
    }

    /** Persist verbatim, or clear a blank rule; never execute or validate JavaScript here. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun save(rule: String) {
        currentCoroutineContext().ensureActive()
        if (rule.length > LocalBookFileNameResolver.MAX_RULE_LENGTH) {
            throw RecoverableSharedException(
                "LocalBookFileNameFacade.save",
                "File name rule exceeds 65536 characters",
            )
        }
        operation("save") {
            preferencesStore.setBookImportFileName(rule.takeUnless { it.isBlank() })
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun resolve(fileName: String): LocalBookFileNameResult =
        operation("resolve") { resolver.resolve(fileName) }

    // runRecoverable would record raw preference/runtime errors, potentially containing private data.
    private suspend fun <T> operation(method: String, block: suspend () -> T): T {
        return try {
            currentCoroutineContext().ensureActive()
            val result = block()
            currentCoroutineContext().ensureActive()
            result
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            currentCoroutineContext().ensureActive()
            throw RecoverableSharedException(
                "LocalBookFileNameFacade.$method",
                "Unable to access local book file name rules",
            )
        }
    }

    companion object {
        @Throws(RecoverableSharedException::class, CancellationException::class)
        fun create(): LocalBookFileNameFacade = try {
            SharedBootstrap.startOrThrow()
            KoinPlatformTools.defaultContext().get().get<LocalBookFileNameFacade>()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            throw RecoverableSharedException(
                "LocalBookFileNameFacade.create",
                "Unable to initialize local book file name rules",
            )
        }
    }
}
