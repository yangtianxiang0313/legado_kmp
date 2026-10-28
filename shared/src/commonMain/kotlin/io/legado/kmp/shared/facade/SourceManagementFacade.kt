package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ExecuteLoginUrlUseCase
import io.legado.kmp.shared.domain.usecase.DeleteBookSourceUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookSourceUseCase
import io.legado.kmp.shared.network.extractCookieDomain
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SourceGroups
import io.legado.kmp.shared.domain.usecase.DeleteCookieUseCase
import io.legado.kmp.shared.domain.usecase.LoginAction
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.source.SourceStateStore
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class SourceImportResult(
    val importedCount: Int,
    val totalCount: Int,
    val addedCount: Int,
    val updatedCount: Int,
    val duplicateCount: Int,
    val invalidCount: Int,
    val failureSummary: String? = null,
    val skipped: Boolean = false,
)

class SourceImportException(
    override val message: String,
    override val cause: Throwable? = null,
) : Exception(message, cause)

data class SourceLoginResult(
    val webUrl: String? = null,
    val loginHeader: String? = null,
    val executedJs: Boolean = false,
)

class SourceManagementFacade(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val saveBookSourceUseCase: SaveBookSourceUseCase,
    private val deleteBookSourceUseCase: DeleteBookSourceUseCase,
    private val httpUseCase: HttpUseCase,
    private val executeLoginUrlUseCase: ExecuteLoginUrlUseCase,
    private val deleteCookieUseCase: DeleteCookieUseCase,
    private val sourceStateStore: SourceStateStore,
) {
    fun watchSources(onUpdate: (List<BookSource>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase(), onUpdate, label = "SourceManagementFacade.sources")
    }

    fun watchGroups(onUpdate: (List<String>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase.observeAllGroups(), onUpdate, label = "SourceManagementFacade.groups")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getAllSources(): List<BookSource> {
        return runRecoverable("SourceManagementFacade.getAllSources") {
            getBookSourcesUseCase.getAll()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getSource(sourceUrl: String): BookSource? {
        return runRecoverable("SourceManagementFacade.getSource") {
            getBookSourcesUseCase.getByUrl(sourceUrl.trim())
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchSources(keyword: String): List<BookSource> {
        return runRecoverable("SourceManagementFacade.searchSources") {
            searchSources(keyword = keyword, group = null)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchSources(keyword: String, group: String?): List<BookSource> {
        return runRecoverable("SourceManagementFacade.searchSourcesInGroup") {
            val trimmed = keyword.trim()
            val base = if (group.isNullOrBlank()) {
                getBookSourcesUseCase.getAll()
            } else {
                getBookSourcesUseCase.getByGroup(group)
            }
            if (trimmed.isEmpty()) {
                base
            } else {
                base.filter { source ->
                    source.bookSourceName.contains(trimmed, ignoreCase = true) ||
                        source.bookSourceUrl.contains(trimmed, ignoreCase = true) ||
                        (source.bookSourceGroup?.contains(trimmed, ignoreCase = true) == true)
                }
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun previewSourceImport(payload: String): SourceImportPreview {
        return runRecoverable("SourceManagementFacade.previewSourceImport") {
            runImportOperation("Failed to preview book sources") {
                val sources = normalizePayloads(payload)
                SourceImportPreview(
                    candidates = sources.persisted.map { source ->
                        SourceImportCandidate(
                            source = source,
                            localSource = getBookSourcesUseCase.getByUrl(source.bookSourceUrl),
                        )
                    },
                    totalCount = sources.parsed.size,
                    duplicateCount = sources.duplicateCount,
                    invalidCount = sources.parsed.size - sources.normalized.size,
                )
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun previewSourceImportByUrl(url: String): SourceImportPreview {
        return runRecoverable("SourceManagementFacade.previewSourceImportByUrl") {
            runImportOperation("Failed to preview book sources from URL") {
                val request = normalizeImportUrl(url)
                val payload = httpUseCase.getAsString(request.url, request.headers).getOrElse { throwable -> throw throwable }
                previewSourceImport(payload)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importSelectedSources(
        sources: List<BookSource>,
        options: SourceImportOptions,
    ): SourceImportResult {
        return runRecoverable("SourceManagementFacade.importSelectedSources") {
            runImportOperation("Failed to import selected book sources") {
                val normalized = sources
                    .filter { it.bookSourceUrl.isNotBlank() && it.bookSourceName.isNotBlank() }
                    .map { it.normalizedForSave() }
                val deduplicatedByUrl = LinkedHashMap<String, BookSource>()
                normalized.forEach { source ->
                    deduplicatedByUrl[source.bookSourceUrl] = source
                }
                val selected = NormalizedSources(
                    parsed = sources,
                    normalized = normalized,
                    persisted = deduplicatedByUrl.values.toList(),
                    duplicateCount = normalized.size - deduplicatedByUrl.size,
                )
                if (selected.persisted.isEmpty()) {
                    return@runImportOperation selected.toImportResult(emptySet()).copy(skipped = true)
                }

                val existingUrls = mutableSetOf<String>()
                val updated = selected.persisted.map { source ->
                    val localSource = getBookSourcesUseCase.getByUrl(source.bookSourceUrl)
                    if (localSource != null) {
                        existingUrls.add(source.bookSourceUrl)
                    }
                    source.withImportOptions(localSource, options)
                }
                saveBookSourceUseCase.insertOrUpdate(updated)
                selected.toImportResult(existingUrls)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importSources(payload: String): SourceImportResult {
        return runRecoverable("SourceManagementFacade.importSources") {
            runImportOperation("Failed to import book sources") {
                val sources = normalizePayloads(payload)
                val existingUrls = getBookSourcesUseCase.getAll().map { it.bookSourceUrl }.toSet()
                saveBookSourceUseCase.insertOrUpdate(sources.persisted)
                sources.toImportResult(existingUrls)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importSourcesIfEmpty(payload: String): SourceImportResult {
        return runRecoverable("SourceManagementFacade.importSourcesIfEmpty") {
            runImportOperation("Failed to import bundled book sources") {
                if (getBookSourcesUseCase.getAll().isNotEmpty()) {
                    return@runImportOperation SourceImportResult(
                        importedCount = 0,
                        totalCount = 0,
                        addedCount = 0,
                        updatedCount = 0,
                        duplicateCount = 0,
                        invalidCount = 0,
                        skipped = true,
                    )
                }
                val sources = normalizePayloads(payload)
                saveBookSourceUseCase.insertOrUpdate(sources.persisted)
                sources.toImportResult(existingUrls = emptySet())
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importSourcesByUrl(url: String): SourceImportResult {
        return runRecoverable("SourceManagementFacade.importSourcesByUrl") {
            runImportOperation("Failed to import book sources from URL") {
                val request = normalizeImportUrl(url)
                val payload = httpUseCase.getAsString(request.url, request.headers).getOrElse { throwable -> throw throwable }
                importSources(payload)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnabled(sourceUrl: String, enabled: Boolean) {
        runRecoverable("SourceManagementFacade.setEnabled") {
            saveBookSourceUseCase.setEnabled(sourceUrl, enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnabledExplore(sourceUrl: String, enabled: Boolean) {
        runRecoverable("SourceManagementFacade.setEnabledExplore") {
            saveBookSourceUseCase.setEnabledExplore(sourceUrl, enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveSource(source: BookSource): BookSource {
        return runRecoverable("SourceManagementFacade.saveSource") {
            val normalized = source.normalizedForSave()
            saveBookSourceUseCase(normalized)
            getBookSourcesUseCase.getByUrl(normalized.bookSourceUrl) ?: normalized
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteSource(sourceUrl: String) {
        runRecoverable("SourceManagementFacade.deleteSource") {
            deleteBookSourceUseCase(sourceUrl)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteSources(sourceUrls: List<String>) {
        runRecoverable("SourceManagementFacade.deleteSources") {
            val targets =
                sourceUrls
                    .map(String::trim)
                    .filter(String::isNotEmpty)
                    .distinct()
                    .mapNotNull { getBookSourcesUseCase.getByUrl(it) }
            if (targets.isNotEmpty()) {
                deleteBookSourceUseCase.deleteAll(targets)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateSourceOrder(sourceUrl: String, order: Int) {
        runRecoverable("SourceManagementFacade.updateSourceOrder") {
            saveBookSourceUseCase.updateOrder(sourceUrl, order)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateSourceOrders(sources: List<BookSource>) {
        runRecoverable("SourceManagementFacade.updateSourceOrders") {
            saveBookSourceUseCase.insertOrUpdate(sources.map { it.normalizedForSave() })
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateSourceGroup(sourceUrl: String, group: String?) {
        runRecoverable("SourceManagementFacade.updateSourceGroup") {
            saveBookSourceUseCase.updateGroup(sourceUrl, group?.trim().takeUnless { it.isNullOrEmpty() })
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addSourcesToGroup(sourceUrls: List<String>, group: String): List<BookSource> {
        return runRecoverable("SourceManagementFacade.addSourcesToGroup") {
            updateGroups(sourceUrls, group) { source, normalizedGroup -> source.addGroups(normalizedGroup) }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun removeSourcesFromGroup(sourceUrls: List<String>, group: String): List<BookSource> {
        return runRecoverable("SourceManagementFacade.removeSourcesFromGroup") {
            updateGroups(sourceUrls, group) { source, normalizedGroup -> source.removeGroups(normalizedGroup) }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearSourceCheckState(sourceUrl: String): BookSource? {
        return runRecoverable("SourceManagementFacade.clearSourceCheckState") {
            val source = getBookSourcesUseCase.getByUrl(sourceUrl.trim()) ?: return@runRecoverable null
            val updated = source
                .removeInvalidGroups()
                .removeErrorComment()
                .normalizedForSave()
            saveBookSourceUseCase(updated)
            getBookSourcesUseCase.getByUrl(updated.bookSourceUrl) ?: updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearSourceCheckState(sourceUrls: List<String>): List<BookSource> {
        return runRecoverable("SourceManagementFacade.clearSourceCheckStates") {
            val updated = resolveSources(sourceUrls)
                .map { source ->
                    source
                        .removeInvalidGroups()
                        .removeErrorComment()
                        .normalizedForSave()
                }
            if (updated.isNotEmpty()) {
                saveBookSourceUseCase.insertOrUpdate(updated)
            }
            updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addGroup(group: String): List<BookSource> {
        return runRecoverable("SourceManagementFacade.addGroup") {
            val normalizedGroup = group.trim()
            require(normalizedGroup.isNotEmpty()) { "Book source group cannot be empty" }
            val updated = getBookSourcesUseCase.getAll()
                .filter { it.bookSourceGroup.isNullOrBlank() }
                .map { it.copy(bookSourceGroup = normalizedGroup).normalizedForSave() }
            if (updated.isNotEmpty()) {
                saveBookSourceUseCase.insertOrUpdate(updated)
            }
            updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun renameGroup(oldGroup: String, newGroup: String?): List<BookSource> {
        return runRecoverable("SourceManagementFacade.renameGroup") {
            val normalizedOld = oldGroup.trim()
            require(normalizedOld.isNotEmpty()) { "Old book source group cannot be empty" }
            val normalizedNew = newGroup?.trim().takeUnless { it.isNullOrEmpty() }
            val updated = getBookSourcesUseCase.getByGroup(normalizedOld)
                .map { source ->
                    val renamed = source.removeGroups(normalizedOld)
                    (normalizedNew?.let { renamed.addGroups(it) } ?: renamed).normalizedForSave()
                }
            if (updated.isNotEmpty()) {
                saveBookSourceUseCase.insertOrUpdate(updated)
            }
            updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteGroup(group: String): List<BookSource> {
        return runRecoverable("SourceManagementFacade.deleteGroup") {
            val normalizedGroup = group.trim()
            require(normalizedGroup.isNotEmpty()) { "Book source group cannot be empty" }
            val updated = getBookSourcesUseCase.getByGroup(normalizedGroup)
                .map { it.removeGroups(normalizedGroup).normalizedForSave() }
            if (updated.isNotEmpty()) {
                saveBookSourceUseCase.insertOrUpdate(updated)
            }
            updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportSources(sourceUrls: List<String>): String {
        return runRecoverable("SourceManagementFacade.exportSources") {
            val targets = resolveSources(sourceUrls)
            importJson.encodeToString(ListSerializer(BookSource.serializer()), targets)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportSource(sourceUrl: String): String {
        return runRecoverable("SourceManagementFacade.exportSource") {
            val source = getBookSourcesUseCase.getByUrl(sourceUrl)
                ?: throw IllegalArgumentException("Book source not found: $sourceUrl")
            importJson.encodeToString(BookSource.serializer(), source)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun parseSourcePayload(payload: String): List<BookSource> {
        return runRecoverable("SourceManagementFacade.parseSourcePayload") {
            val root = importJson.parseToJsonElement(payload)
            val compatible = if (root is JsonObject) sourceEditorTypedPayload(root) else payload
            normalizePayloads(compatible).persisted
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    fun completeEditorSourcePayload(payload: String, enabled: Boolean): String {
        return try {
            BookSourceRuleCompletion.payload(payload, enabled)
        } catch (throwable: Throwable) {
            if (throwable is CancellationException) throw throwable
            throw throwable.asRecoverableSharedException("SourceManagementFacade.completeEditorSourcePayload")
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun previewEditorSourceImport(payload: String): SourceEditorImportPreview {
        return runRecoverable("SourceManagementFacade.previewEditorSourceImport") {
            suspend fun resolve(text: String, depth: Int): List<JsonObject> {
                require(depth <= 5) { "Too many nested source URLs" }
                val trimmed = text.trim()
                if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
                    val request = normalizeImportUrl(trimmed)
                    val downloaded = httpUseCase.getAsString(request.url, request.headers).getOrElse { throw it }
                    return resolve(downloaded, depth + 1)
                }
                val urls = extractSourceUrls(trimmed)
                return if (urls == null) sourceEditorObjects(trimmed) else urls.flatMap { resolve(it, depth + 1) }
            }
            var invalid = 0
            val candidates = resolve(payload, 0).mapNotNull { objectValue ->
                try {
                    // The same parser/normalizer as the import preview, without importing anything.
                    val parsed = normalizeBookSourcePayload(sourceEditorTypedPayload(objectValue))
                    SourceEditorImportCandidate(parsed.persisted.single(), objectValue.toString())
                } catch (throwable: Throwable) {
                    if (throwable is CancellationException) throw throwable
                    invalid += 1
                    null
                }
            }
            require(candidates.isNotEmpty()) { "No valid book sources found in payload" }
            SourceEditorImportPreview(candidates, invalid)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getSourceVariable(sourceUrl: String): String? {
        return runRecoverable("SourceManagementFacade.getSourceVariable") {
            val source = getBookSourcesUseCase.getByUrl(sourceUrl.trim())
                ?: throw IllegalArgumentException("Book source not found: $sourceUrl")
            sourceStateStore.getSourceVariable(source.bookSourceUrl)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSourceVariable(sourceUrl: String, value: String) {
        runRecoverable("SourceManagementFacade.setSourceVariable") {
            val source = getBookSourcesUseCase.getByUrl(sourceUrl.trim())
                ?: throw IllegalArgumentException("Book source not found: $sourceUrl")
            sourceStateStore.setSourceVariable(source.bookSourceUrl, value)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    fun encodeImportSource(source: BookSource): String {
        return try {
            importJson.encodeToString(BookSource.serializer(), source)
        } catch (throwable: Throwable) {
            if (throwable is CancellationException) {
                throw throwable
            }
            CrashCollector.record("SourceManagementFacade", "encodeImportSource", error = throwable)
            throw throwable.asRecoverableSharedException("SourceManagementFacade.encodeImportSource")
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun executeLogin(sourceUrl: String): SourceLoginResult {
        return runRecoverable("SourceManagementFacade.executeLogin") {
            val source = getBookSourcesUseCase.getByUrl(sourceUrl.trim())
                ?: throw IllegalArgumentException("Book source not found: $sourceUrl")
            when (val action = executeLoginUrlUseCase(source).getOrElse { throw it }) {
                LoginAction.None -> SourceLoginResult()
                is LoginAction.JsExecuted -> SourceLoginResult(loginHeader = action.loginHeader, executedJs = true)
                is LoginAction.WebView -> SourceLoginResult(webUrl = action.url, executedJs = false)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearSourceCookies(sourceUrl: String) {
        runRecoverable("SourceManagementFacade.clearSourceCookies") {
            deleteCookieUseCase.delete(extractCookieDomain(sourceUrl.trim()))
        }
    }

    private suspend fun updateGroups(
        sourceUrls: List<String>,
        group: String,
        operation: (BookSource, String) -> BookSource,
    ): List<BookSource> {
        val normalizedGroup = group.trim()
        require(normalizedGroup.isNotEmpty()) { "Book source group cannot be empty" }
        val updated = resolveSources(sourceUrls).map { operation(it, normalizedGroup).normalizedForSave() }
        if (updated.isNotEmpty()) {
            saveBookSourceUseCase.insertOrUpdate(updated)
        }
        return updated
    }

    private suspend fun resolveSources(sourceUrls: List<String>): List<BookSource> {
        return sourceUrls
            .map(String::trim)
            .filter(String::isNotEmpty)
            .distinct()
            .mapNotNull { getBookSourcesUseCase.getByUrl(it) }
    }

    private fun BookSource.normalizedForSave(): BookSource {
        return copy(
            bookSourceUrl = bookSourceUrl.trim(),
            bookSourceName = bookSourceName.trim(),
            bookSourceGroup = SourceGroups.normalize(bookSourceGroup),
            bookUrlPattern = bookUrlPattern?.takeUnless(String::isBlank),
            jsLib = jsLib?.takeUnless(String::isBlank),
            concurrentRate = concurrentRate?.takeUnless(String::isBlank),
            header = header?.takeUnless(String::isBlank),
            loginUrl = loginUrl?.takeUnless(String::isBlank),
            loginUi = loginUi?.takeUnless(String::isBlank),
            loginCheckJs = loginCheckJs?.takeUnless(String::isBlank),
            coverDecodeJs = coverDecodeJs?.takeUnless(String::isBlank),
            bookSourceComment = bookSourceComment?.takeUnless(String::isBlank),
            variableComment = variableComment?.takeUnless(String::isBlank),
            exploreUrl = exploreUrl?.takeUnless(String::isBlank),
            exploreScreen = exploreScreen?.takeUnless(String::isBlank),
            searchUrl = searchUrl?.takeUnless(String::isBlank),
        ).also {
            require(it.bookSourceUrl.isNotEmpty()) { "Book source URL cannot be empty" }
            require(it.bookSourceName.isNotEmpty()) { "Book source name cannot be empty" }
        }
    }

    private fun BookSource.withImportOptions(
        localSource: BookSource?,
        options: SourceImportOptions,
    ): BookSource {
        val merged = if (localSource == null) {
            this
        } else {
            copy(
                bookSourceName = if (options.keepName) localSource.bookSourceName else bookSourceName,
                bookSourceGroup = if (options.keepGroup) localSource.bookSourceGroup else bookSourceGroup,
                customOrder = localSource.customOrder,
                enabled = if (options.keepEnabled) localSource.enabled else enabled,
                enabledExplore = if (options.keepEnabled) localSource.enabledExplore else enabledExplore,
            )
        }
        val groupName = SourceGroups.normalize(options.groupName) ?: return merged
        return merged.copy(
            bookSourceGroup = if (options.appendGroup) {
                SourceGroups.add(merged.bookSourceGroup, groupName)
            } else {
                groupName
            },
        )
    }

    private suspend fun normalizePayloads(payload: String): NormalizedSources {
        val payloads = expandSourceUrlPayload(payload)
        val normalizedPayloads = payloads.map(::normalizeBookSourcePayload)
        val parsed = normalizedPayloads.flatMap { it.parsed }
        val normalized = normalizedPayloads.flatMap { it.normalized }
        val deduplicatedByUrl = LinkedHashMap<String, BookSource>()
        normalizedPayloads.forEach { normalizedPayload ->
            normalizedPayload.persisted.forEach { source ->
                deduplicatedByUrl[source.bookSourceUrl] = source
            }
        }
        return NormalizedSources(
            parsed = parsed,
            normalized = normalized,
            persisted = deduplicatedByUrl.values.toList(),
            duplicateCount = normalized.size - deduplicatedByUrl.size,
        )
    }

    private suspend fun expandSourceUrlPayload(payload: String): List<String> {
        val sourceUrls = extractSourceUrls(payload)
        if (sourceUrls == null) {
            return listOf(payload)
        }
        return sourceUrls.map { sourceUrl ->
            val request = normalizeImportUrl(sourceUrl)
            httpUseCase.getAsString(request.url, request.headers).getOrElse { throwable -> throw throwable }
        }
    }

    private fun extractSourceUrls(payload: String): List<String>? {
        val root = runCatching { importJson.parseToJsonElement(payload.trim()) as? JsonObject }.getOrNull()
            ?: return null
        val sourceUrls = root["sourceUrls"] as? JsonArray ?: return null
        return sourceUrls.mapNotNull { element ->
            (element as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
        }
    }

    private data class NormalizedSources(
        val parsed: List<BookSource>,
        val normalized: List<BookSource>,
        val persisted: List<BookSource>,
        val duplicateCount: Int,
    ) {
        fun toImportResult(existingUrls: Set<String>): SourceImportResult {
            val addedCount = persisted.count { it.bookSourceUrl !in existingUrls }
            val updatedCount = persisted.size - addedCount
            return SourceImportResult(
                importedCount = persisted.size,
                totalCount = parsed.size,
                addedCount = addedCount,
                updatedCount = updatedCount,
                duplicateCount = duplicateCount,
                invalidCount = parsed.size - normalized.size,
            )
        }
    }

    private fun normalizeImportUrl(url: String): ImportUrlRequest {
        val normalized = url.trim()
        require(normalized.isNotEmpty()) { "Source URL is empty" }
        require(normalized.startsWith("http://") || normalized.startsWith("https://")) {
            "Source URL must start with http:// or https://"
        }
        return if (normalized.endsWith(REQUEST_WITHOUT_UA_SUFFIX)) {
            ImportUrlRequest(
                url = normalized.substringBeforeLast(REQUEST_WITHOUT_UA_SUFFIX),
                headers = mapOf(USER_AGENT_HEADER to "null"),
            )
        } else {
            ImportUrlRequest(url = normalized)
        }
    }

    private suspend fun <T> runImportOperation(message: String, block: suspend () -> T): T {
        return try {
            block()
        } catch (throwable: Throwable) {
            if (throwable is CancellationException) {
                throw throwable
            }
            if (throwable is SourceImportException) {
                throw throwable
            }
            val userVisibleMessage = throwable.message?.takeIf { it.isNotBlank() } ?: message
            throw SourceImportException(userVisibleMessage, throwable)
        }
    }

    private data class ImportUrlRequest(
        val url: String,
        val headers: Map<String, String> = emptyMap(),
    )

    private companion object {
        private const val REQUEST_WITHOUT_UA_SUFFIX = "#requestWithoutUA"
        private const val USER_AGENT_HEADER = "User-Agent"
    }
}
