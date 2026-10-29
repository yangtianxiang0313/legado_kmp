package io.legado.kmp.shared.data.repository

import io.legado.kmp.data.database.schema.Books
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.WebFileMetadataMergeContext
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSourceType
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal suspend fun mergeImportedWebFileMetadata(
    database: LegadoDatabase,
    expectedOnlineBook: Book,
    expectedLocalBook: Book,
    mapToBook: (Books) -> Book,
): Book? {
    val context = currentCoroutineContext()
    val cancellationContext = context[WebFileMetadataMergeContext]?.callerContext ?: context
    cancellationContext.ensureActive()
    return database.bookQueries.transactionWithResult {
        cancellationContext.ensureActive()
        if (expectedOnlineBook.bookUrl.isBlank() || expectedLocalBook.bookUrl.isBlank() ||
            expectedOnlineBook.bookUrl == expectedLocalBook.bookUrl ||
            expectedOnlineBook.isLocal || !expectedOnlineBook.isWebFile || !expectedLocalBook.isLocal
        ) {
            return@transactionWithResult null
        }

        val onlineRow = database.bookQueries.selectByBookUrl(expectedOnlineBook.bookUrl).executeAsOneOrNull()
            ?: return@transactionWithResult null
        val localRow = database.bookQueries.selectByBookUrl(expectedLocalBook.bookUrl).executeAsOneOrNull()
            ?: return@transactionWithResult null
        val online = mapToBook(onlineRow)
        val local = mapToBook(localRow)
        if (online.bookUrl != expectedOnlineBook.bookUrl || online.origin != expectedOnlineBook.origin ||
            online.isLocal || !online.isWebFile || !onlineRow.matchesFileMetadata(expectedOnlineBook) ||
            local.bookUrl != expectedLocalBook.bookUrl || local.origin != expectedLocalBook.origin ||
            !local.isLocal || localRow.type != expectedLocalBook.type.toLong() ||
            !localRow.matchesFileMetadata(expectedLocalBook)
        ) {
            return@transactionWithResult null
        }
        val source = database.bookSourceQueries.selectByUrl(online.origin).executeAsOneOrNull()
        if (source == null || source.book_source_type != BookSourceType.FILE.toLong()) {
            return@transactionWithResult null
        }
        cancellationContext.ensureActive()

        // Android LocalBook.mergeBook: do not trim strings or substitute custom display values.
        val merged = local.copy(
            name = online.name.ifBlank { local.name },
            author = online.author.ifBlank { local.author },
            coverUrl = online.coverUrl,
            intro = online.intro?.takeIf { it.isNotBlank() } ?: local.intro,
        )
        val renamed = local.name != merged.name || local.author != merged.author
        var moveBookmarks = false
        if (renamed) {
            val owners = database.bookQueries.selectByExactNameAndAuthor(local.name, local.author).executeAsList()
            if (owners.singleOrNull()?.book_url != local.bookUrl) return@transactionWithResult null
            val oldBookmarks = database.bookmarkQueries.selectByBook(local.name, local.author).executeAsList()
            val targetBookmarks = database.bookmarkQueries.selectByBook(merged.name, merged.author).executeAsList()
            if (targetBookmarks.isNotEmpty()) return@transactionWithResult null
            val targetBooks = database.bookQueries.selectByExactNameAndAuthor(merged.name, merged.author).executeAsList()
            // Bookmarks share a name/author domain. The explicit online counterpart is the same
            // work for this merge, not a third-party owner; never join a third book or existing marks.
            if (targetBooks.any { it.book_url != online.bookUrl }) return@transactionWithResult null
            moveBookmarks = oldBookmarks.isNotEmpty()
        }

        cancellationContext.ensureActive()
        database.bookQueries.updateWebFileMetadataIfUnchanged(
            name = merged.name,
            author = merged.author,
            cover_url = merged.coverUrl,
            intro = merged.intro,
            book_url = localRow.book_url,
            expected_origin = localRow.origin,
            expected_type = localRow.type,
            expected_name = localRow.name,
            expected_author = localRow.author,
            expected_cover_url = localRow.cover_url,
            expected_intro = localRow.intro,
        )
        if (moveBookmarks) {
            cancellationContext.ensureActive()
            database.bookmarkQueries.renameBookIdentity(
                book_name = merged.name,
                book_author = merged.author,
                expected_book_name = local.name,
                expected_book_author = local.author,
            )
        }
        val persisted = database.bookQueries.selectByBookUrl(local.bookUrl).executeAsOne()
        check(persisted.matchesFileMetadata(merged)) { "File metadata merge did not persist" }
        val result = mapToBook(persisted)
        cancellationContext.ensureActive()
        result
    }
}

private fun Books.matchesFileMetadata(expected: Book): Boolean =
    name == expected.name && author == expected.author && cover_url == expected.coverUrl && intro == expected.intro
