package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.WebFileMetadataMergeContext
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.getCacheFolderName
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

/**
 * 仅在单本文件成功导入后，由调用方携带在线书与已导入本地书的两端快照显式合并。
 * 批量 archive 导入不得对所有同名书逐一调用；合并失败时保留已导入的本地书。
 * 不重新加载在线书、不重新导入或修改原文件；改名时保留正文编辑与图片缓存。
 */
class WebBookFileImportFacade(
    private val books: BookRepository,
    private val chapterContent: ChapterContentRepository,
) {
    companion object {
        private val mergeMutex = Mutex()

        @Throws(RecoverableSharedException::class)
        fun create(): WebBookFileImportFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            WebBookFileImportFacade(koin.get(), koin.get())
        } catch (_: Throwable) {
            throw RecoverableSharedException(
                code = "WebBookFileImportFacade.create",
                message = "文件书籍合并服务不可用，请重试",
            )
        }
    }

    /**
     * 使用单本成功导入时保留的两端快照进行条件合并，返回仓库实际提交的书籍。
     * 快照冲突或合并失败均保留已导入的本地书；提交后不再检查取消或执行挂起操作。
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun mergeImportedBook(expectedOnlineBook: Book, expectedLocalBook: Book): Book {
        return try {
            val callerContext = currentCoroutineContext()
            callerContext.ensureActive()
            mergeMutex.withLock {
                callerContext.ensureActive()
                // No dispatcher switch: cancellation cannot discard a successful commit on return.
                // The SQL transaction checks the original caller, not NonCancellable, before writes/commit.
                withContext(NonCancellable + WebFileMetadataMergeContext(callerContext)) {
                    callerContext.ensureActive()
                    if (expectedOnlineBook.bookUrl.isBlank() || expectedLocalBook.bookUrl.isBlank() ||
                        expectedOnlineBook.bookUrl == expectedLocalBook.bookUrl ||
                        expectedOnlineBook.isLocal || !expectedOnlineBook.isWebFile || !expectedLocalBook.isLocal
                    ) {
                        throw ImportConflict()
                    }
                    val oldFolder = expectedLocalBook.getCacheFolderName()
                    val newFolder = expectedLocalBook.copy(
                        name = expectedOnlineBook.name.ifBlank { expectedLocalBook.name },
                    ).getCacheFolderName()
                    var movedCache = false
                    try {
                        if (oldFolder != newFolder) {
                            val storedBooks = books.getAllBooks()
                            callerContext.ensureActive()
                            val local = storedBooks.firstOrNull { it.bookUrl == expectedLocalBook.bookUrl }
                            if (local == null || !matchesLocalSnapshot(local, expectedLocalBook) ||
                                hasOtherCacheOwner(storedBooks, expectedLocalBook.bookUrl, oldFolder, newFolder)
                            ) {
                                throw ImportConflict()
                            }
                            val folders = chapterContent.listCacheFolders().toSet()
                            callerContext.ensureActive()
                            // moveCacheFolder may delete an empty target. Do not overwrite even an empty
                            // preexisting folder, or adopt its resources when the old folder is absent.
                            if (newFolder in folders) throw ImportConflict()
                            if (oldFolder in folders) {
                                callerContext.ensureActive()
                                if (!chapterContent.moveCacheFolder(oldFolder, newFolder)) throw CacheMoveFailure()
                                movedCache = true
                            }
                        }
                        callerContext.ensureActive()
                        books.mergeWebFileMetadataIfUnchanged(expectedOnlineBook, expectedLocalBook)
                            ?: throw ImportConflict()
                    } catch (error: Throwable) {
                        // A true result for an absent old folder is NOT a move. Never reverse it and
                        // accidentally consume resources that another operation created at the new path.
                        if (movedCache) {
                            val restored = try {
                                restoreCache(expectedLocalBook.bookUrl, oldFolder, newFolder)
                            } catch (_: Throwable) {
                                false
                            }
                            if (!restored) {
                                if (error is CancellationException) {
                                    error.addSuppressed(cacheRestoreError())
                                } else {
                                    throw CacheRestoreFailure()
                                }
                            }
                        }
                        throw error
                    }
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: ImportConflict) {
            throw RecoverableSharedException(
                code = "WebBookFileImportFacade.conflict",
                message = "文件已导入但未合并，请刷新后重试",
            )
        } catch (_: CacheMoveFailure) {
            throw RecoverableSharedException(
                code = "WebBookFileImportFacade.cacheMove",
                message = "文件已导入，缓存未能迁移，未合并书籍信息，请重试",
            )
        } catch (_: CacheRestoreFailure) {
            throw cacheRestoreError()
        } catch (_: Throwable) {
            throw RecoverableSharedException(
                code = "WebBookFileImportFacade.mergeImportedBook",
                message = "文件已导入但合并失败，请刷新后重试",
            )
        }
    }

    private suspend fun restoreCache(bookUrl: String, oldFolder: String, newFolder: String): Boolean {
        val storedBooks = books.getAllBooks()
        if (hasOtherCacheOwner(storedBooks, bookUrl, oldFolder, newFolder)) return false
        val folders = chapterContent.listCacheFolders().toSet()
        // Do not let moveCacheFolder remove a newly recreated old folder, even if it is empty.
        if (oldFolder in folders || newFolder !in folders) return false
        return chapterContent.moveCacheFolder(newFolder, oldFolder)
    }

    private fun hasOtherCacheOwner(books: List<Book>, bookUrl: String, oldFolder: String, newFolder: String): Boolean =
        books.any { book ->
            book.bookUrl != bookUrl && book.getCacheFolderName().let { it == oldFolder || it == newFolder }
        }

    private fun matchesLocalSnapshot(local: Book, expected: Book): Boolean =
        local.isLocal && local.origin == expected.origin && local.type == expected.type &&
            local.name == expected.name && local.author == expected.author &&
            local.coverUrl == expected.coverUrl && local.intro == expected.intro

    private fun cacheRestoreError(): RecoverableSharedException = RecoverableSharedException(
        code = "WebBookFileImportFacade.cacheRestore",
        message = "文件已导入，书籍信息未合并，缓存保留但恢复位置失败，请重试",
    )

    private class ImportConflict : Exception()
    private class CacheMoveFailure : Exception()
    private class CacheRestoreFailure : Exception()
}
