package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.ReadConfig
import io.legado.kmp.shared.model.ReadSimulationSchedule
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.first

private const val IMG_STYLE_FULL = "FULL"
private const val IMG_STYLE_SINGLE = "SINGLE"

internal class ReaderConfigurationSupport(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val preferencesStore: AppPreferencesStore,
) {
    fun computeSimulatedChapterSize(readConfig: ReadConfig?, realChapterSize: Int): Int {
        return ReadSimulationSchedule.count(readConfig, realChapterSize)
    }

    suspend fun upWebBook(book: Book) {
        val isPdf = book.bookUrl.substringAfterLast('.', "").lowercase() == "pdf"
        if (book.isLocal) {
            if (book.config.imageStyle.isNullOrBlank() && (book.isImage || isPdf)) {
                val updated = book.copy(
                    readConfig = book.config.copy(imageStyle = IMG_STYLE_FULL)
                )
                saveBookUseCase.ifSourceUnchanged(expected = book, book = updated)
            }
        } else {
            val source = getBookSourcesUseCase.getByUrl(book.origin) ?: return
            if (book.config.imageStyle.isNullOrBlank()) {
                var imageStyle = source.getContentRule().imageStyle
                if (imageStyle.isNullOrBlank() && (book.isImage || isPdf)) {
                    imageStyle = IMG_STYLE_FULL
                }
                if (!imageStyle.isNullOrBlank()) {
                    var newConfig = book.config.copy(imageStyle = imageStyle)
                    if (imageStyle.equals(IMG_STYLE_SINGLE, ignoreCase = true)) {
                        newConfig = newConfig.copy(pageAnim = 0)
                    }
                    val updated = book.copy(readConfig = newConfig)
                    saveBookUseCase.ifSourceUnchanged(expected = book, book = updated)
                }
            }
        }
    }

    suspend fun toggleDelTag(book: Book, tag: Long): Book {
        val config = book.config
        val newConfig = config.copy()
        if (config.hasDelTag(tag)) {
            newConfig.removeDelTag(tag)
        } else {
            newConfig.addDelTag(tag)
        }
        val updated = book.copy(readConfig = newConfig)
        return saveBookUseCase.ifSourceUnchanged(expected = book, book = updated)
    }

    suspend fun setImageStyle(book: Book, imageStyle: String): Book {
        return saveBookUseCase.updateImageStyle(book.bookUrl, book.origin, imageStyle)
    }

    suspend fun getReadAloudConfig(): ReadAloudConfig {
        return try {
            val config = preferencesStore.runtimeConfig.first()
            ReadAloudConfig(
                engine = config.ttsEngine,
                speed = config.reader.ttsSpeechRate,
                followSystemRate = config.reader.ttsFollowSystemRate,
                timerMinutes = config.reader.ttsTimerMinutes,
                voiceIdentifier = config.reader.ttsVoiceIdentifier,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "getReadAloudConfig", error = e)
            ReadAloudConfig()
        }
    }

    suspend fun setTtsSpeechRate(rate: Int) {
        try {
            val clamped = rate.coerceIn(0, 45)
            val currentConfig = preferencesStore.runtimeConfig.first()
            val updatedReader = currentConfig.reader.copy(ttsSpeechRate = clamped)
            preferencesStore.setReaderRuntimeConfig(updatedReader)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "setTtsSpeechRate", mapOf("rate" to rate.toString()), e)
        }
    }

    suspend fun setReadTimer(minutes: Int) {
        try {
            val clamped = minutes.coerceAtLeast(0)
            val currentConfig = preferencesStore.runtimeConfig.first()
            val updatedReader = currentConfig.reader.copy(ttsTimerMinutes = clamped)
            preferencesStore.setReaderRuntimeConfig(updatedReader)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "setReadTimer", mapOf("minutes" to minutes.toString()), e)
        }
    }
}
