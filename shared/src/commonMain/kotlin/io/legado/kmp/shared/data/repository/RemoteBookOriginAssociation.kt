package io.legado.kmp.shared.data.repository

import io.legado.kmp.data.database.schema.Books
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.localbook.RemoteBookOrigin
import io.legado.kmp.shared.domain.localbook.archiveContainerName
import io.legado.kmp.shared.domain.localbook.mergeRemoteBookOrigin
import io.legado.kmp.shared.domain.localbook.remoteBookOrigins
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal suspend fun associateImportedRemoteBookOrigin(
    database: LegadoDatabase,
    remoteOrigin: String,
    expected: Book,
    mapToBook: (Books) -> Book,
): Book? {
    val context = currentCoroutineContext()
    context.ensureActive()
    val remote = requireNotNull(RemoteBookOrigin.parse(remoteOrigin)) { "远程书籍来源无效" }
    require(expected.isLocal && expected.bookUrl.isNotBlank()) { "只能关联已导入的本地书籍" }
    return database.bookQueries.transactionWithResult {
        context.ensureActive()
        val row = database.bookQueries.selectByBookUrl(expected.bookUrl).executeAsOneOrNull()
            ?: return@transactionWithResult null
        val latest = mapToBook(row)
        if (!latest.isLocal || row.book_url != expected.bookUrl || row.origin != expected.origin ||
            row.type != expected.type.toLong() || row.variable != expected.variable ||
            row.origin_name != expected.originName || row.name != expected.name || row.author != expected.author
        ) return@transactionWithResult null

        val plainLocal = row.origin.equals(BookType.LOCAL_TAG, true) || row.origin.equals(BookType.LEGACY_LOCAL_TAG, true)
        val primary = RemoteBookOrigin.parseOrNull(row.origin)
        // An explicit association from a completed import can resolve this exact legacy URL.
        // Other remote primary origins, including distinct named-server identities, stay intact.
        val resolvesLegacy = primary != null && primary.serverID == null &&
            primary.url == remote.url && remote.serverID != null
        // Archive entry recovery depends on the complete local::<archive identity> value.
        val origin = if (latest.archiveContainerName == null && latest.type and BookType.ARCHIVE == 0 &&
            ((plainLocal && latest.remoteBookOrigins.isEmpty()) || resolvesLegacy)
        ) remote.encoded else row.origin
        val variable = mergeRemoteBookOrigin(row.variable, remote)
        context.ensureActive()
        database.bookQueries.associateRemoteOriginIfUnchanged(
            origin = origin,
            variable = variable,
            book_url = row.book_url,
            expected_origin = row.origin,
            expected_type = row.type,
            expected_variable = row.variable,
        )
        val persisted = database.bookQueries.selectByBookUrl(row.book_url).executeAsOne()
        check(persisted.origin == origin && persisted.variable == variable && mapToBook(persisted).isLocal) {
            "远程书籍来源关联未完成，原书籍未被替换"
        }
        val result = mapToBook(persisted)
        context.ensureActive()
        result
    }
}
