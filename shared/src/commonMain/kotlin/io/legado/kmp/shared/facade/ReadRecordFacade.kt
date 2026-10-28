package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.ReadRecordSnapshot
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.flow.first
import kotlin.coroutines.cancellation.CancellationException

class ReadRecordFacade(
    private val readRecordRepository: ReadRecordRepository,
    private val bookRepository: BookRepository,
    private val preferencesStore: AppPreferencesStore,
) {
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun load(query: String): ReadRecordSnapshot {
        return runRecoverable("ReadRecordFacade.load") {
            val enabled = preferencesStore.runtimeConfig.first().enableReadRecord
            readRecordRepository.loadSnapshot(query, enabled)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteByName(bookName: String) {
        runRecoverable("ReadRecordFacade.deleteByName") {
            readRecordRepository.deleteByName(bookName)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun clear() {
        runRecoverable("ReadRecordFacade.clear") {
            readRecordRepository.clear()
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun setEnabled(enabled: Boolean) {
        runRecoverable("ReadRecordFacade.setEnabled") {
            preferencesStore.setEnableReadRecord(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun findBook(bookName: String): Book? {
        return runRecoverable("ReadRecordFacade.findBook") {
            bookRepository.getBooksByName(bookName).firstOrNull()
        }
    }
}
