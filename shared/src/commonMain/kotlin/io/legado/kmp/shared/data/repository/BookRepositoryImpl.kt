package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import app.cash.sqldelight.coroutines.mapToOneOrNull
import io.legado.kmp.data.database.schema.Books
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ChapterListReorderResult
import io.legado.kmp.shared.domain.repository.ReadingProgressUpdateResult
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.domain.localbook.EpubCatalogReflowPlan
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.ReadConfig
import io.legado.kmp.shared.model.isTxtLocalBook
import io.legado.kmp.shared.model.variableMapJson
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.datetime.LocalDate

/**
 * SQLDelight implementation of BookRepository
 */
class BookRepositoryImpl(
    private val database: LegadoDatabase
) : BookRepository {

    override fun observeAllBooks(): Flow<List<Book>> {
        return database.bookQueries
            .selectAllOrdered { book_url, toc_url, origin, origin_name, name, author, kind,
                custom_tag, cover_url, custom_cover_url, intro, custom_intro, charset, type,
                group, latest_chapter_title, latest_chapter_time, last_check_time, last_check_count,
                total_chapter_num, dur_chapter_title, dur_chapter_index, dur_chapter_pos,
                dur_chapter_time, word_count, can_update, order, origin_order, variable,
                read_config, sync_time ->
                Book.from(book_url, toc_url, origin, origin_name, name, author, kind,
                    custom_tag, cover_url, custom_cover_url, intro, custom_intro, charset, type,
                    group, latest_chapter_title, latest_chapter_time, last_check_time, last_check_count,
                    total_chapter_num, dur_chapter_title, dur_chapter_index, dur_chapter_pos,
                    dur_chapter_time, word_count, can_update, order, origin_order, variable,
                    read_config, sync_time)
            }
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeBooksByGroup(groupId: Long): Flow<List<Book>> {
        return database.bookQueries
            .selectByGroup(groupId) { book_url, toc_url, origin, origin_name, name, author, kind,
                custom_tag, cover_url, custom_cover_url, intro, custom_intro, charset, type,
                group, latest_chapter_title, latest_chapter_time, last_check_time, last_check_count,
                total_chapter_num, dur_chapter_title, dur_chapter_index, dur_chapter_pos,
                dur_chapter_time, word_count, can_update, order, origin_order, variable,
                read_config, sync_time ->
                Book.from(book_url, toc_url, origin, origin_name, name, author, kind,
                    custom_tag, cover_url, custom_cover_url, intro, custom_intro, charset, type,
                    group, latest_chapter_title, latest_chapter_time, last_check_time, last_check_count,
                    total_chapter_num, dur_chapter_title, dur_chapter_index, dur_chapter_pos,
                    dur_chapter_time, word_count, can_update, order, origin_order, variable,
                    read_config, sync_time)
            }
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeBook(bookUrl: String): Flow<Book?> {
        return database.bookQueries
            .selectByBookUrl(bookUrl) { book_url, toc_url, origin, origin_name, name, author, kind,
                custom_tag, cover_url, custom_cover_url, intro, custom_intro, charset, type,
                group, latest_chapter_title, latest_chapter_time, last_check_time, last_check_count,
                total_chapter_num, dur_chapter_title, dur_chapter_index, dur_chapter_pos,
                dur_chapter_time, word_count, can_update, order, origin_order, variable,
                read_config, sync_time ->
                Book.from(book_url, toc_url, origin, origin_name, name, author, kind,
                    custom_tag, cover_url, custom_cover_url, intro, custom_intro, charset, type,
                    group, latest_chapter_title, latest_chapter_time, last_check_time, last_check_count,
                    total_chapter_num, dur_chapter_title, dur_chapter_index, dur_chapter_pos,
                    dur_chapter_time, word_count, can_update, order, origin_order, variable,
                    read_config, sync_time)
            }
            .asFlow()
            .mapToOneOrNull(Dispatchers.Default)
    }

    override suspend fun getAllBooks(): List<Book> {
        return database.bookQueries
            .selectAllOrdered()
            .executeAsList()
            .map { book -> mapToBook(book) }
    }

    override suspend fun getBook(bookUrl: String): Book? {
        return database.bookQueries
            .selectByBookUrl(bookUrl)
            .executeAsOneOrNull()
            ?.let { book -> mapToBook(book) }
    }

    override suspend fun getBooksByName(bookName: String): List<Book> {
        return database.bookQueries
            .selectByExactName(bookName)
            .executeAsList()
            .map { book -> mapToBook(book) }
    }

    override suspend fun getBooksByOrigin(origin: String): List<Book> {
        return database.bookQueries
            .selectByOrigin(origin)
            .executeAsList()
            .map { book -> mapToBook(book) }
    }

    override suspend fun getBooksByGroup(groupId: Long): List<Book> {
        return database.bookQueries
            .selectByGroup(groupId)
            .executeAsList()
            .map { book -> mapToBook(book) }
    }

    override suspend fun searchBooks(query: String): List<Book> {
        return database.bookQueries
            .searchByName(query, query)
            .executeAsList()
            .map { book -> mapToBook(book) }
    }

    override suspend fun insert(book: Book) {
        insertBook(book)
    }

    private fun insertBook(book: Book) {
        database.bookQueries.insert(
            book_url = book.bookUrl,
            toc_url = book.tocUrl,
            origin = book.origin,
            origin_name = book.originName,
            name = book.name,
            author = book.author,
            kind = book.kind,
            custom_tag = book.customTag,
            cover_url = book.coverUrl,
            custom_cover_url = book.customCoverUrl,
            intro = book.intro,
            custom_intro = book.customIntro,
            charset = book.charset,
            type = book.type.toLong(),
            group = book.group,
            latest_chapter_title = book.latestChapterTitle,
            latest_chapter_time = book.latestChapterTime,
            last_check_time = book.lastCheckTime,
            last_check_count = book.lastCheckCount.toLong(),
            total_chapter_num = book.totalChapterNum.toLong(),
            dur_chapter_title = book.durChapterTitle,
            dur_chapter_index = book.durChapterIndex.toLong(),
            dur_chapter_pos = book.durChapterPos.toLong(),
            dur_chapter_time = book.durChapterTime,
            word_count = book.wordCount,
            can_update = if (book.canUpdate) 1L else 0L,
            order = book.order.toLong(),
            origin_order = book.originOrder.toLong(),
            variable = book.variable,
            read_config = book.readConfig?.toJson(),
            sync_time = book.syncTime
        )
    }

    override suspend fun update(book: Book) {
        updateBook(book)
    }

    private fun updateBook(book: Book) {
        database.bookQueries.update(
            toc_url = book.tocUrl,
            origin = book.origin,
            origin_name = book.originName,
            name = book.name,
            author = book.author,
            kind = book.kind,
            custom_tag = book.customTag,
            cover_url = book.coverUrl,
            custom_cover_url = book.customCoverUrl,
            intro = book.intro,
            custom_intro = book.customIntro,
            charset = book.charset,
            type = book.type.toLong(),
            group = book.group,
            latest_chapter_title = book.latestChapterTitle,
            latest_chapter_time = book.latestChapterTime,
            last_check_time = book.lastCheckTime,
            last_check_count = book.lastCheckCount.toLong(),
            total_chapter_num = book.totalChapterNum.toLong(),
            dur_chapter_title = book.durChapterTitle,
            dur_chapter_index = book.durChapterIndex.toLong(),
            dur_chapter_pos = book.durChapterPos.toLong(),
            dur_chapter_time = book.durChapterTime,
            word_count = book.wordCount,
            can_update = if (book.canUpdate) 1L else 0L,
            order = book.order.toLong(),
            origin_order = book.originOrder.toLong(),
            variable = book.variable,
            read_config = book.readConfig?.toJson(),
            sync_time = book.syncTime,
            book_url = book.bookUrl
        )
    }

    override suspend fun insertOrUpdate(book: Book) {
        val existing = getBook(book.bookUrl)
        if (existing != null) {
            update(book)
        } else {
            insert(book)
        }
    }

    internal fun restoreFromBackup(book: Book) {
        val existing = database.bookQueries.selectByBookUrl(book.bookUrl).executeAsOneOrNull()
        if (existing != null) {
            updateBook(book)
        } else {
            insertBook(book)
        }
    }

    override suspend fun insertLocalBookIfAbsent(book: Book, chapters: List<BookChapter>): Book {
        val coroutineContext = currentCoroutineContext()
        coroutineContext.ensureActive()
        return database.bookQueries.transactionWithResult {
            coroutineContext.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(book.bookUrl).executeAsOneOrNull()
            coroutineContext.ensureActive()
            if (stored != null) {
                return@transactionWithResult mapToBook(stored)
            }

            require(book.isLocal) { "Book must be local" }
            require(book.bookUrl.isNotBlank()) { "Local book URL must not be blank" }
            val localChapters = chapters.toList()
            require(book.totalChapterNum == localChapters.size) { "Book chapter count must match the chapter list" }
            val chapterIndices = HashSet<Int>()
            val chapterUrls = HashSet<String>()
            localChapters.forEach { chapter ->
                coroutineContext.ensureActive()
                require(chapter.bookUrl == book.bookUrl) { "Chapter book URL must match the local book" }
                require(chapter.index in localChapters.indices) { "Chapter indices must cover the full zero-based list" }
                require(chapterIndices.add(chapter.index)) { "Chapter indices must be unique" }
                require(chapter.url.isNotBlank()) { "Chapter URL must not be blank" }
                require(chapterUrls.add(chapter.url)) { "Chapter URLs must be unique" }
            }

            coroutineContext.ensureActive()
            insertBook(book)
            localChapters.forEach { chapter ->
                coroutineContext.ensureActive()
                database.insertBookChapter(chapter)
            }
            coroutineContext.ensureActive()
            book
        }
    }

    override suspend fun insertPreviewIfAbsent(book: Book): Book {
        require(book.bookUrl.isNotBlank()) { "Book URL is empty" }
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(book.bookUrl).executeAsOneOrNull()
            context.ensureActive()
            if (stored != null) return@transactionWithResult mapToBook(stored)
            require(book.isNotShelf) { "Preview book must not be on the shelf" }
            insertBook(book)
            context.ensureActive()
            book
        }
    }

    override suspend fun insertOrUpdatePreservingReadingProgress(book: Book): Book {
        currentCoroutineContext().ensureActive()
        return database.bookQueries.transactionWithResult {
            val stored = database.bookQueries.selectByBookUrl(book.bookUrl).executeAsOneOrNull()
            if (stored == null) {
                insertBook(book)
                book
            } else {
                val progressChanged = stored.dur_chapter_index.toInt() != book.durChapterIndex ||
                    stored.dur_chapter_title != book.durChapterTitle ||
                    stored.dur_chapter_pos.toInt() != book.durChapterPos ||
                    stored.dur_chapter_time != book.durChapterTime
                val merged = book.copy(
                    durChapterIndex = stored.dur_chapter_index.toInt(),
                    durChapterTitle = stored.dur_chapter_title,
                    durChapterPos = stored.dur_chapter_pos.toInt(),
                    durChapterTime = stored.dur_chapter_time,
                    lastCheckCount = if (progressChanged) stored.last_check_count.toInt() else book.lastCheckCount,
                )
                updateBook(merged)
                merged
            }
        }
    }

    override suspend fun updateGroupPreservingState(bookUrl: String, groupId: Long, addToShelf: Boolean): Book? {
        require(groupId >= 0) { "Book group must be a custom-group mask" }
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            val current = mapToBook(stored)
            val updated = current.copy(
                group = groupId,
                type = if (addToShelf) current.type and BookType.NOT_SHELF.inv() else current.type,
            )
            context.ensureActive()
            updateBook(updated)
            updated
        }
    }

    override suspend fun updateBookInfoPreservingState(
        bookUrl: String,
        name: String?,
        author: String?,
        coverUrl: String?,
        intro: String?,
        bookType: Int?
    ): Book? {
        require(bookType == null || bookType in 0..2) { "Book type must be an index from 0 to 2" }
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            val typeMask = (BookType.TEXT or BookType.AUDIO or BookType.IMAGE).toLong()
            val selectedType = when (bookType) {
                0 -> BookType.TEXT.toLong()
                1 -> BookType.AUDIO.toLong()
                2 -> BookType.IMAGE.toLong()
                else -> null
            }
            // Copy the SQL row directly so raw JSON and every unrelated column remain intact.
            val updated = stored.copy(
                name = name ?: stored.name,
                author = author ?: stored.author,
                custom_cover_url = if (coverUrl == null) stored.custom_cover_url
                    else coverUrl.takeUnless { it == stored.cover_url },
                custom_intro = if (intro == null) stored.custom_intro
                    else intro.takeUnless { it == stored.intro },
                type = selectedType?.let { (stored.type and typeMask.inv()) or it } ?: stored.type,
            )
            context.ensureActive()
            database.bookQueries.update(
                toc_url = updated.toc_url,
                origin = updated.origin,
                origin_name = updated.origin_name,
                name = updated.name,
                author = updated.author,
                kind = updated.kind,
                custom_tag = updated.custom_tag,
                cover_url = updated.cover_url,
                custom_cover_url = updated.custom_cover_url,
                intro = updated.intro,
                custom_intro = updated.custom_intro,
                charset = updated.charset,
                type = updated.type,
                group = updated.group,
                latest_chapter_title = updated.latest_chapter_title,
                latest_chapter_time = updated.latest_chapter_time,
                last_check_time = updated.last_check_time,
                last_check_count = updated.last_check_count,
                total_chapter_num = updated.total_chapter_num,
                dur_chapter_title = updated.dur_chapter_title,
                dur_chapter_index = updated.dur_chapter_index,
                dur_chapter_pos = updated.dur_chapter_pos,
                dur_chapter_time = updated.dur_chapter_time,
                word_count = updated.word_count,
                can_update = updated.can_update,
                order = updated.order,
                origin_order = updated.origin_order,
                variable = updated.variable,
                read_config = updated.read_config,
                sync_time = updated.sync_time,
                book_url = updated.book_url
            )
            context.ensureActive()
            mapToBook(updated)
        }
    }

    override suspend fun updateCustomVariable(bookUrl: String, expectedOrigin: String, value: String): Book? {
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            if (stored.origin != expectedOrigin) return@transactionWithResult null
            val variables = runCatching {
                variableMapJson.parseToJsonElement(stored.variable.orEmpty()) as? JsonObject
            }.getOrNull().orEmpty().toMutableMap()
            variables["custom"] = JsonPrimitive(value)
            val updated = stored.copy(variable = JsonObject(variables).toString())
            context.ensureActive()
            database.bookQueries.updateVariable(updated.variable, bookUrl)
            context.ensureActive()
            mapToBook(updated)
        }
    }

    override suspend fun updatePageAnimation(bookUrl: String, expectedOrigin: String, pageAnimation: Int): Book? {
        require(pageAnimation in -1..4) { "Page animation must be -1 or an index from 0 to 4" }
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            if (stored.book_url != bookUrl || stored.origin != expectedOrigin) return@transactionWithResult null

            val encodedConfig = Json.parseToJsonElement(
                ReadConfig.fromJson(stored.read_config)
                    .copy(pageAnim = pageAnimation.takeIf { it >= 0 })
                    .toJson()
            ).jsonObject
            val latestConfig = stored.read_config?.takeIf { it.isNotBlank() }?.let {
                Json.parseToJsonElement(it)
            }
            val fields = when (latestConfig) {
                null, JsonNull -> emptyMap()
                is JsonObject -> latestConfig
                else -> error("Stored reading configuration must be a JSON object")
            }
            // Keep even unknown keys; re-encoding the full ReadConfig would discard them.
            val readConfig = JsonObject(fields + ("pageAnim" to encodedConfig.getValue("pageAnim"))).toString()
            context.ensureActive()
            database.bookQueries.updateReadConfigIfSourceUnchanged(
                read_config = readConfig,
                book_url = bookUrl,
                expected_origin = expectedOrigin,
            )
            context.ensureActive()
            val persisted = database.bookQueries.selectByBookUrl(bookUrl).executeAsOne()
            context.ensureActive()
            mapToBook(persisted)
        }
    }

    override suspend fun updateReadSimulation(
        bookUrl: String,
        expectedOrigin: String,
        enabled: Boolean,
        startDateIso: String,
        startChapter: Int,
        dailyChapters: Int,
    ): Book? {
        val context = currentCoroutineContext()
        context.ensureActive()
        require(bookUrl.isNotBlank()) { "Book URL is empty" }
        require(startChapter >= 0) { "Start chapter must be nonnegative" }
        require(dailyChapters >= 0) { "Daily chapters must be nonnegative" }
        require(startDateIso.length == 10) { "Start date must use yyyy-MM-dd" }
        val startDate = LocalDate.parse(startDateIso)
        require(startDate.toString() == startDateIso) { "Start date must use yyyy-MM-dd" }
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            if (stored.book_url != bookUrl || stored.origin != expectedOrigin) return@transactionWithResult null

            val fields = stored.read_config?.let { raw ->
                val parsed = try {
                    Json.parseToJsonElement(raw)
                } catch (error: IllegalArgumentException) {
                    throw IllegalStateException("Cannot update read simulation: stored reading configuration is not valid JSON", error)
                }
                check(parsed is JsonObject) { "Cannot update read simulation: stored reading configuration must be a JSON object" }
                parsed.toMutableMap()
            } ?: mutableMapOf()
            fields["readSimulating"] = JsonPrimitive(enabled)
            fields["startDate"] = JsonPrimitive(startDate.toString())
            fields["startChapter"] = JsonPrimitive(startChapter)
            fields["dailyChapters"] = JsonPrimitive(dailyChapters)
            context.ensureActive()
            database.bookQueries.updateReadConfigIfSourceUnchanged(
                read_config = JsonObject(fields).toString(),
                book_url = bookUrl,
                expected_origin = expectedOrigin,
            )
            context.ensureActive()
            val persisted = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            if (persisted.book_url != bookUrl || persisted.origin != expectedOrigin) return@transactionWithResult null
            val updated = mapToBook(persisted)
            context.ensureActive()
            updated
        }
    }

    override suspend fun updateImageStyle(bookUrl: String, expectedOrigin: String, imageStyle: String): Book? {
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            if (stored.origin != expectedOrigin) return@transactionWithResult null

            val latestConfig = stored.read_config?.takeIf { it.isNotBlank() }?.let {
                try {
                    Json.parseToJsonElement(it)
                } catch (error: IllegalArgumentException) {
                    throw IllegalStateException("Cannot update image style: stored reading configuration is not valid JSON", error)
                }
            }
            val fields = when (latestConfig) {
                null, JsonNull -> emptyMap()
                is JsonObject -> latestConfig
                else -> error("Cannot update image style: stored reading configuration must be a JSON object")
            }.toMutableMap()
            fields["imageStyle"] = JsonPrimitive(imageStyle)
            if (imageStyle.equals(ReadConfig.Companion.ImageStyles.SINGLE, ignoreCase = true)) {
                fields["pageAnim"] = JsonPrimitive(0)
            }
            context.ensureActive()
            database.bookQueries.updateReadConfigIfSourceUnchanged(
                read_config = JsonObject(fields).toString(),
                book_url = bookUrl,
                expected_origin = expectedOrigin,
            )
            context.ensureActive()
            val persisted = database.bookQueries.selectByBookUrl(bookUrl).executeAsOne()
            context.ensureActive()
            mapToBook(persisted)
        }
    }

    override suspend fun updateCharset(bookUrl: String, expectedOrigin: String, charset: String): Book? {
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            context.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            if (stored.origin != expectedOrigin) return@transactionWithResult null
            val latest = mapToBook(stored)
            context.ensureActive()
            if (stored.charset == charset) return@transactionWithResult latest

            database.bookQueries.updateCharsetIfSourceUnchanged(
                charset = charset,
                book_url = bookUrl,
                expected_origin = expectedOrigin,
            )
            if (latest.isLocal || latest.isTxtLocalBook) {
                context.ensureActive()
                database.bookChapterQueries.deleteByBookUrl(bookUrl)
            }
            context.ensureActive()
            val persisted = database.bookQueries.selectByBookUrl(bookUrl).executeAsOne()
            context.ensureActive()
            mapToBook(persisted)
        }
    }

    override suspend fun saveMetadataIfSourceUnchanged(
        expected: Book,
        replacement: Book,
        chapters: List<BookChapter>?,
        allowInsert: Boolean,
        epubReflowPlan: EpubCatalogReflowPlan?,
    ): Book? {
        val coroutineContext = currentCoroutineContext()
        coroutineContext.ensureActive()
        val expectedReverseToc = expected.config.reverseToc
        require(replacement.bookUrl == expected.bookUrl) { "Replacement book URL must match expected" }
        return database.bookQueries.transactionWithResult {
            coroutineContext.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(expected.bookUrl).executeAsOneOrNull()
            coroutineContext.ensureActive()
            if (stored == null) {
                if (!allowInsert) return@transactionWithResult null
            } else if (stored.origin != expected.origin ||
                mapToBook(stored).config.reverseToc != expectedReverseToc ||
                (chapters != null && (stored.toc_url != expected.tocUrl ||
                    stored.total_chapter_num != expected.totalChapterNum.toLong()))
            ) {
                return@transactionWithResult null
            }
            require(replacement.origin == expected.origin) { "Replacement origin must match expected" }
            chapters?.forEach { chapter ->
                coroutineContext.ensureActive()
                require(chapter.bookUrl == expected.bookUrl) { "Chapter book URL must match expected" }
            }

            val preserved = if (stored == null) {
                replacement
            } else {
                val progressChanged = stored.dur_chapter_index.toInt() != replacement.durChapterIndex ||
                    stored.dur_chapter_title != replacement.durChapterTitle ||
                    stored.dur_chapter_pos.toInt() != replacement.durChapterPos ||
                    stored.dur_chapter_time != replacement.durChapterTime
                replacement.copy(
                    durChapterIndex = stored.dur_chapter_index.toInt(),
                    durChapterTitle = stored.dur_chapter_title,
                    durChapterPos = stored.dur_chapter_pos.toInt(),
                    durChapterTime = stored.dur_chapter_time,
                    lastCheckCount = if (progressChanged) stored.last_check_count.toInt() else replacement.lastCheckCount,
                ).also { merged ->
                    // Book.copy does not carry transient response data.
                    merged.infoHtml = replacement.infoHtml
                    merged.tocHtml = replacement.tocHtml
                    merged.downloadUrls = replacement.downloadUrls
                }
            }

            val persisted = if (stored == null) preserved else {
                val epub = mapEpubCatalogState(
                    database, mapToBook(stored), preserved, chapters, epubReflowPlan,
                ) { coroutineContext.ensureActive() }
                mapMobiCatalogState(database, mapToBook(stored), epub, chapters) { coroutineContext.ensureActive() }
            }
            coroutineContext.ensureActive()
            if (stored == null) {
                insertBook(persisted)
            } else {
                updateBook(persisted)
                // Catalog/metadata refreshes must not discard fields unknown to this ReadConfig version.
                val readConfig = if (replacement.readConfig == expected.readConfig) {
                    stored.read_config
                } else {
                    val previous = stored.read_config?.let { raw ->
                        runCatching { Json.parseToJsonElement(raw) as? JsonObject }.getOrNull()
                    }
                    val encoded = persisted.readConfig?.toJson()
                    if (previous != null && encoded != null) {
                        // toJson encodes all known defaults, so intentional resets still replace old values.
                        JsonObject(previous + (Json.parseToJsonElement(encoded) as JsonObject)).toString()
                    } else encoded
                }
                database.bookQueries.updateReadConfigIfSourceUnchanged(
                    read_config = readConfig,
                    book_url = expected.bookUrl,
                    expected_origin = expected.origin,
                )
            }
            if (chapters != null) {
                coroutineContext.ensureActive()
                database.bookChapterQueries.deleteByBookUrl(expected.bookUrl)
                chapters.forEach { chapter ->
                    coroutineContext.ensureActive()
                    database.insertBookChapter(chapter)
                }
            }
            coroutineContext.ensureActive()
            persisted
        }
    }

    override suspend fun replaceSourceIfUnchanged(
        current: Book,
        replacement: Book,
        chapters: List<BookChapter>
    ): Book? {
        val coroutineContext = currentCoroutineContext()
        coroutineContext.ensureActive()
        val expectedReverseToc = current.readConfig?.reverseToc ?: false
        val replacementChapters = chapters.toList()
        return database.bookQueries.transactionWithResult {
            coroutineContext.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(current.bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            coroutineContext.ensureActive()
            val oldBook = mapToBook(stored)
            if (oldBook.origin != current.origin ||
                oldBook.tocUrl != current.tocUrl ||
                oldBook.name != current.name ||
                oldBook.author != current.author ||
                oldBook.totalChapterNum != current.totalChapterNum ||
                oldBook.config.reverseToc != expectedReverseToc ||
                oldBook.durChapterIndex != current.durChapterIndex ||
                oldBook.durChapterTitle != current.durChapterTitle ||
                oldBook.durChapterPos != current.durChapterPos ||
                oldBook.durChapterTime != current.durChapterTime
            ) {
                return@transactionWithResult null
            }

            require(replacement.bookUrl.isNotBlank()) { "Replacement book URL must not be blank" }
            require(replacementChapters.isNotEmpty()) { "Replacement chapter list must not be empty" }
            val chapterIndices = HashSet<Int>()
            val chapterUrls = HashSet<String>()
            replacementChapters.forEach { chapter ->
                coroutineContext.ensureActive()
                require(chapter.bookUrl == replacement.bookUrl) { "Chapter book URL must match the replacement" }
                require(chapter.index in replacementChapters.indices) { "Chapter indices must cover the full zero-based list" }
                require(chapterIndices.add(chapter.index)) { "Chapter indices must be unique" }
                require(chapter.url.isNotBlank()) { "Chapter URL must not be blank" }
                require(chapterUrls.add(chapter.url)) { "Chapter URLs must be unique" }
            }
            require(replacement.durChapterIndex in chapterIndices) { "Replacement progress must refer to a chapter" }

            val sameUrl = oldBook.bookUrl == replacement.bookUrl
            if (!sameUrl && database.bookQueries.selectByBookUrl(replacement.bookUrl).executeAsOneOrNull() != null) {
                return@transactionWithResult null
            }
            coroutineContext.ensureActive()
            val persisted = replacement.copy(
                type = (replacement.type and BookType.NOT_SHELF.inv()) or (oldBook.type and BookType.NOT_SHELF),
                group = oldBook.group,
                order = oldBook.order,
                originOrder = oldBook.originOrder,
                customCoverUrl = oldBook.customCoverUrl,
                customIntro = oldBook.customIntro,
                customTag = oldBook.customTag,
                charset = oldBook.charset,
                canUpdate = oldBook.canUpdate,
                readConfig = oldBook.readConfig?.copy(),
                syncTime = oldBook.syncTime,
                durChapterTime = oldBook.durChapterTime,
                durChapterPos = if (oldBook.isAudio && replacement.isAudio || oldBook.isImage && replacement.isImage) {
                    oldBook.durChapterPos
                } else 0,
                totalChapterNum = replacementChapters.size,
            )

            coroutineContext.ensureActive()
            if (sameUrl) {
                updateBook(persisted)
            } else {
                insertBook(persisted)
            }
            coroutineContext.ensureActive()
            database.bookChapterQueries.deleteByBookUrl(persisted.bookUrl)
            replacementChapters.forEach { chapter ->
                coroutineContext.ensureActive()
                database.insertBookChapter(chapter)
            }
            if (!sameUrl) {
                coroutineContext.ensureActive()
                database.bookChapterQueries.deleteByBookUrl(oldBook.bookUrl)
                coroutineContext.ensureActive()
                database.bookQueries.delete(oldBook.bookUrl)
            }
            coroutineContext.ensureActive()
            persisted
        }
    }

    override suspend fun reverseChapterListIfUnchanged(
        expected: Book,
        expectedChapters: List<BookChapter>
    ): ChapterListReorderResult? {
        val coroutineContext = currentCoroutineContext()
        coroutineContext.ensureActive()
        val expectedReverseToc = expected.config.reverseToc
        val snapshot = expectedChapters.sortedBy { it.index }
        require(snapshot.isNotEmpty()) { "Cannot reverse an empty chapter list" }
        val urls = HashSet<String>()
        snapshot.forEachIndexed { index, chapter ->
            coroutineContext.ensureActive()
            require(chapter.bookUrl == expected.bookUrl) { "Chapter book URL must match expected" }
            require(chapter.index == index) { "Chapter indices must be unique and complete from zero" }
            require(chapter.url.isNotBlank() && urls.add(chapter.url)) { "Chapter URLs must be nonblank and unique" }
        }
        return database.bookQueries.transactionWithResult {
            coroutineContext.ensureActive()
            val stored = database.bookQueries.selectByBookUrl(expected.bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            val latest = mapToBook(stored)
            if (latest.origin != expected.origin || latest.tocUrl != expected.tocUrl ||
                latest.name != expected.name || latest.author != expected.author ||
                stored.total_chapter_num != expected.totalChapterNum.toLong() || latest.config.reverseToc != expectedReverseToc
            ) {
                return@transactionWithResult null
            }
            val rows = database.bookChapterQueries.selectByBookUrl(expected.bookUrl).executeAsList()
            coroutineContext.ensureActive()
            if (rows.size != snapshot.size) return@transactionWithResult null
            val chapters = rows.mapIndexed { index, row ->
                coroutineContext.ensureActive()
                if (row.chapter_index != index.toLong()) return@transactionWithResult null
                val chapter = BookChapter.from(
                    url = row.url,
                    title = row.title,
                    is_volume = row.is_volume,
                    base_url = row.base_url,
                    book_url = row.book_url,
                    chapter_index = row.chapter_index,
                    is_vip = row.is_vip,
                    is_pay = row.is_pay,
                    resource_url = row.resource_url,
                    tag = row.tag,
                    word_count = row.word_count,
                    start = row.start,
                    end = row.end,
                    start_fragment_id = row.start_fragment_id,
                    end_fragment_id = row.end_fragment_id,
                    variable = row.variable,
                )
                if (!sameChapterStructure(chapter, snapshot[index])) return@transactionWithResult null
                chapter
            }

            check(stored.dur_chapter_index in 0L..chapters.lastIndex.toLong()) {
                "Cannot reverse chapters: current reading chapter cannot be mapped by URL"
            }
            val currentChapter = chapters.getOrNull(latest.durChapterIndex)
            check(currentChapter != null) { "Cannot reverse chapters: current reading chapter cannot be mapped by URL" }
            val bookmarks = database.bookmarkQueries.selectByBook(latest.name, latest.author).executeAsList()
            if (bookmarks.isNotEmpty()) {
                val matchingBooks = database.bookQueries.selectAll().executeAsList().count {
                    coroutineContext.ensureActive()
                    it.name == latest.name && it.author == latest.author
                }
                check(matchingBooks == 1) {
                    "Cannot reverse chapters: multiple books with the same name and author share bookmarks"
                }
            }
            val reordered = chapters.asReversed().mapIndexed { index, chapter ->
                coroutineContext.ensureActive()
                chapter.copy(index = index)
            }
            val currentIndex = reordered.indexOfFirst { it.url == currentChapter.url }
            check(currentIndex >= 0) { "Cannot reverse chapters: current chapter URL is missing" }
            val persisted = latest.copy(
                durChapterIndex = currentIndex,
                readConfig = latest.config.copy(reverseToc = !expectedReverseToc),
            )

            coroutineContext.ensureActive()
            database.bookChapterQueries.deleteByBookUrl(latest.bookUrl)
            reordered.forEach { chapter ->
                coroutineContext.ensureActive()
                database.insertBookChapter(chapter)
            }
            coroutineContext.ensureActive()
            updateBook(persisted)
            if (bookmarks.isNotEmpty()) {
                coroutineContext.ensureActive()
                database.bookQueries.reverseBookmarkChapterIndices(
                    last_index = reordered.lastIndex.toLong(),
                    book_name = latest.name,
                    book_author = latest.author,
                )
            }
            coroutineContext.ensureActive()
            ChapterListReorderResult(persisted, reordered)
        }
    }

    private fun sameChapterStructure(latest: BookChapter, expected: BookChapter): Boolean {
        // BookChapter.equals compares only URL; wordCount is intentionally allowed to advance.
        return latest.bookUrl == expected.bookUrl && latest.url == expected.url && latest.index == expected.index &&
            latest.title == expected.title && latest.isVolume == expected.isVolume && latest.baseUrl == expected.baseUrl &&
            latest.isVip == expected.isVip && latest.isPay == expected.isPay && latest.resourceUrl == expected.resourceUrl &&
            latest.tag == expected.tag && latest.start == expected.start && latest.end == expected.end &&
            latest.startFragmentId == expected.startFragmentId && latest.endFragmentId == expected.endFragmentId &&
            latest.variable == expected.variable
    }

    override suspend fun completePreviewReadingExit(bookUrl: String, expectedOrigin: String, addToShelf: Boolean): Book? {
        require(bookUrl.isNotBlank()) { "Book URL is empty" }
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookQueries.transactionWithResult {
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
            if (stored == null) {
                check(!addToShelf) { "书籍已不存在，请重新打开" }
                return@transactionWithResult null
            }
            check(stored.origin == expectedOrigin) { "书籍已换源，请重新返回" }
            if (stored.type and BookType.NOT_SHELF.toLong() == 0L) return@transactionWithResult mapToBook(stored)
            context.ensureActive()
            val updated = if (addToShelf) {
                val row = stored.copy(type = stored.type and BookType.NOT_SHELF.toLong().inv())
                // This narrow update also preserves unknown reading-config and variable JSON fields.
                database.bookQueries.updateShelfType(row.type, bookUrl)
                mapToBook(row)
            } else {
                // Android Book.delete removes only this row, not chapters, bookmarks, cached text or files.
                database.bookQueries.delete(bookUrl)
                null
            }
            context.ensureActive()
            updated
        }
    }

    override suspend fun delete(book: Book) {
        database.bookQueries.delete(book.bookUrl)
    }

    override suspend fun deleteByUrl(bookUrl: String) {
        database.bookQueries.delete(bookUrl)
    }

    override suspend fun deleteByGroup(groupId: Long) {
        database.bookQueries.deleteByGroup(groupId)
    }

    override suspend fun updateReadingProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int
    ) {
        updateReadingProgressAndGet(bookUrl, chapterIndex, chapterTitle, chapterPos)
    }

    override suspend fun updateReadingProgressAndGet(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int
    ): Book? {
        currentCoroutineContext().ensureActive()
        return database.bookQueries.transactionWithResult {
            val stored = database.bookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult null
            val updated = mapToBook(stored).updateReadingProgress(chapterIndex, chapterTitle, chapterPos)
            writeReadingProgress(updated)
            updated
        }
    }

    override suspend fun updateReadingProgressIfUnchanged(
        current: Book,
        updated: Book,
        importedTimestamp: Long?,
    ): ReadingProgressUpdateResult {
        require(current.bookUrl == updated.bookUrl) { "Progress snapshots must refer to the same book" }
        require(importedTimestamp == null || importedTimestamp >= 0) { "Imported progress time cannot be negative" }
        currentCoroutineContext().ensureActive()
        return database.bookQueries.transactionWithResult {
            val stored = database.bookQueries.selectByBookUrl(current.bookUrl).executeAsOneOrNull()
                ?: return@transactionWithResult ReadingProgressUpdateResult(null, persisted = false)
            val latest = mapToBook(stored)
            val revisionMatches = latest.origin == current.origin && latest.tocUrl == current.tocUrl &&
                latest.config.reverseToc == current.config.reverseToc &&
                latest.durChapterIndex == current.durChapterIndex &&
                latest.durChapterTitle == current.durChapterTitle &&
                latest.durChapterPos == current.durChapterPos &&
                latest.durChapterTime == current.durChapterTime
            val progressChanged = latest.durChapterIndex != updated.durChapterIndex ||
                latest.durChapterTitle != updated.durChapterTitle ||
                latest.durChapterPos != updated.durChapterPos ||
                (importedTimestamp != null && latest.durChapterTime != importedTimestamp)
            if (!revisionMatches || !progressChanged) {
                return@transactionWithResult ReadingProgressUpdateResult(latest, persisted = false)
            }
            val progress = latest.updateReadingProgress(
                updated.durChapterIndex,
                updated.durChapterTitle,
                updated.durChapterPos,
            )
            val persisted = if (importedTimestamp != null) progress.copy(durChapterTime = importedTimestamp) else progress
            writeReadingProgress(persisted)
            ReadingProgressUpdateResult(persisted, persisted = true)
        }
    }

    private fun writeReadingProgress(book: Book) {
        database.bookQueries.updateReadingProgress(
            dur_chapter_title = book.durChapterTitle,
            dur_chapter_index = book.durChapterIndex.toLong(),
            dur_chapter_pos = book.durChapterPos.toLong(),
            dur_chapter_time = book.durChapterTime,
            book_url = book.bookUrl
        )
    }

    override suspend fun updateAudioReadingProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int
    ) {
        database.bookQueries.updateAudioReadingProgress(
            dur_chapter_title = chapterTitle,
            dur_chapter_index = chapterIndex.toLong(),
            dur_chapter_pos = chapterPos.toLong(),
            dur_chapter_time = io.legado.kmp.shared.util.currentTimeMillis(),
            book_url = bookUrl
        )
    }

    override suspend fun updateLatestChapter(bookUrl: String, chapterTitle: String?) {
        database.bookQueries.updateLatestChapter(
            latest_chapter_title = chapterTitle,
            latest_chapter_time = io.legado.kmp.shared.util.currentTimeMillis(),
            book_url = bookUrl
        )
    }

    override suspend fun getBookCount(): Int {
        return database.bookQueries.countAll().executeAsOne().toInt()
    }

    override suspend fun getBookCountByGroup(groupId: Long): Int {
        return database.bookQueries.countByGroup(groupId).executeAsOne().toInt()
    }

    override suspend fun getRecentBooks(limit: Int): List<Book> {
        return getAllBooks()
            .sortedByDescending { it.durChapterTime }
            .take(limit)
    }

    override suspend fun getUpdatedBooks(limit: Int): List<Book> {
        return getAllBooks()
            .sortedByDescending { it.latestChapterTime }
            .take(limit)
    }

    /**
     * Map SQLDelight generated book to domain model
     */
    private fun mapToBook(book: Books): Book = Book.from(
        book_url = book.book_url,
        toc_url = book.toc_url,
        origin = book.origin,
        origin_name = book.origin_name,
        name = book.name,
        author = book.author,
        kind = book.kind,
        custom_tag = book.custom_tag,
        cover_url = book.cover_url,
        custom_cover_url = book.custom_cover_url,
        intro = book.intro,
        custom_intro = book.custom_intro,
        charset = book.charset,
        type = book.type,
        group = book.group,
        latest_chapter_title = book.latest_chapter_title,
        latest_chapter_time = book.latest_chapter_time,
        last_check_time = book.last_check_time,
        last_check_count = book.last_check_count,
        total_chapter_num = book.total_chapter_num,
        dur_chapter_title = book.dur_chapter_title,
        dur_chapter_index = book.dur_chapter_index,
        dur_chapter_pos = book.dur_chapter_pos,
        dur_chapter_time = book.dur_chapter_time,
        word_count = book.word_count,
        can_update = book.can_update,
        order = book.order,
        origin_order = book.origin_order,
        variable = book.variable,
        read_config = book.read_config,
        sync_time = book.sync_time
    )
}
