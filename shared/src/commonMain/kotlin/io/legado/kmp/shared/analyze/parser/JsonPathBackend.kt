package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.JsonPath
import at.asitplus.jsonpath.core.JsonPathQuery
import at.asitplus.jsonpath.implementation.AntlrJsonPathCompiler
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement

internal data class JsonPathResolvedValue(val value: JsonElement, val isKeySet: Boolean = false)

internal object JsonPathBackend {
    private val guard = JsonPathCompilerGuard()
    private val compiler = AntlrJsonPathCompiler()
    private val compiledPaths = LinkedHashMap<String, JsonPathQuery>()
    private val documentStack = mutableListOf<JsonPathFunctionDocument>()
    private const val MAX_COMPILED_PATHS = 32

    fun resolve(path: String, root: JsonElement): JsonElement? = resolveValue(path, root)?.value

    /** Stateless at the outer boundary; recursive reads inherit only the active query's document. */
    fun resolveValue(path: String, root: JsonElement): JsonPathResolvedValue? = withFunctionDocument { document ->
        resolveValueOrNull(path, root, document)
    }

    /** Mutations belong to the session even when a later token makes this read fail. */
    fun resolveValue(path: String, session: JsonPathDocumentSession): JsonPathResolvedValue? =
        guard.withLock {
            withFunctionDocument(session.document) { document ->
                resolveValueOrNull(path, session.root, document)
            }
        }

    /** Refresh earlier raw branch references before the outer public read's checkpoint. */
    fun currentValue(value: JsonElement, session: JsonPathDocumentSession): JsonElement = guard.withLock {
        session.document.current(value)
    }

    /** Keep result conversion and checkpoint in the same identity/collection-kind scope. */
    fun <T> withSessionRead(session: JsonPathDocumentSession, block: () -> T): T = guard.withLock {
        try {
            block()
        } finally {
            finishRead(session)
        }
    }

    /** Parser calls this once in the outer public read's finally, never between rule branches. */
    fun finishRead(session: JsonPathDocumentSession) = guard.withLock {
        check(documentStack.none { it === session.document }) {
            "Cannot checkpoint a JSONPath session during query evaluation"
        }
        session.checkpoint()
    }

    private fun resolveValueOrNull(
        path: String,
        root: JsonElement,
        document: JsonPathFunctionDocument,
    ): JsonPathResolvedValue? = try {
        resolveValue(path, root, document)
    } catch (failure: CancellationException) {
        throw failure
    } catch (_: Exception) {
        null
    }

    /** PATH function parameters retain collection kinds; only filter ValueNodes reject a Set. */
    fun resolveFunctionPath(path: String, root: JsonElement): JsonElement? = withFunctionDocument { document ->
        resolveValue(path, root, document)?.value
    }

    /** A filter PathNode catches missing paths, not failures while evaluating an existing value. */
    fun resolveNested(path: String, root: JsonElement): JsonElement? = withFunctionDocument { document ->
        try {
            resolveValue(path, root, document)?.let { resolved ->
                check(!resolved.isKeySet && !document.collections.isKeySet(resolved.value)) {
                    "A key set cannot be converted to a Jayway filter ValueNode"
                }
                resolved.value
            }
        } catch (_: JsonPathMissingPathException) {
            null
        }
    }

    private fun resolveValue(
        path: String,
        root: JsonElement,
        document: JsonPathFunctionDocument,
    ): JsonPathResolvedValue? {
        val normalized = JsonPathFilterSupport.normalize(path)
        val functionResult = JsonPathFunctionSupport.resolve(normalized, root, ::resolveFunctionPath)
        return if (functionResult != null) {
            functionResult.failure?.let { throw it }
            functionResult.value?.let { JsonPathResolvedValue(it, functionResult.isKeySet) }
        } else {
            val query = compiledQuery(normalized)
            val currentRoot = document.current(root)
            val value = JsonPathFilterSupport.withRoot(currentRoot) {
                JsonPathQuerySupport.evaluate(query, currentRoot, isKeySet = document.collections::isKeySet)
            }
            value?.let { document.current(it) }?.let { JsonPathResolvedValue(it, document.collections.isKeySet(it)) }
        }
    }

    /** A predicate's exists branch separates the traversal document from its '$' filter context. */
    fun resolveFrom(path: String, current: JsonElement, root: JsonElement): JsonElement? =
        withFunctionDocument { document ->
            try {
                val normalized = JsonPathFilterSupport.normalize(path)
                val function = JsonPathFunctionSupport.resolve(normalized, root, ::resolveFunctionPath, current)
                if (function != null) {
                    function.failure?.let { throw it }
                    function.value
                } else {
                    val selection = JsonPathQuerySupport.functionSelection(compiledQuery(normalized), terminal = true)
                    val values = buildList {
                        JsonPathFilterSupport.withRoot(document.current(root)) {
                            JsonPathQuerySupport.forEachFunctionMatch(
                                selection, document.current(current), { document.current(root) }, upstreamDefinite = true,
                                currentValue = document::current, onMatch = { add(it) },
                                isKeySet = document.collections::isKeySet,
                            )
                        }
                    }
                    val value = if (selection.definite) values.singleOrNull() else JsonArray(values)
                    value?.let(document::current)
                }
            } catch (_: JsonPathMissingPathException) {
                null
            }
        }

    /** Also guards direct function calls made by filter extensions. */
    fun <T> withFunctionDocument(
        document: JsonPathFunctionDocument? = null,
        block: (JsonPathFunctionDocument) -> T,
    ): T = guard.withLock {
        // ANTLR prediction caches and all document/root stacks share this recursive lock.
        val active = document ?: documentStack.lastOrNull() ?: JsonPathFunctionDocument()
        documentStack.add(active)
        try {
            block(active)
        } finally {
            documentStack.removeAt(documentStack.lastIndex)
        }
    }

    fun functionPrefix(
        path: String,
        scanTail: JsonPathScanTail = JsonPathScanTail.NONE,
    ): JsonPathQuerySupport.FunctionSelection = guard.withLock {
        val prefix = if (scanTail == JsonPathScanTail.NONE) path else path.dropLast(1)
        JsonPathQuerySupport.functionSelection(
            compiledQuery(JsonPathFilterSupport.normalize(prefix)), terminal = false, scanTail = scanTail,
        )
    }

    fun <T> withLiveDocument(
        root: () -> JsonElement,
        currentValue: (JsonElement) -> JsonElement,
        block: () -> T,
    ): T = guard.withLock {
        JsonPathFilterSupport.withLiveRoot(root, currentValue, block)
    }

    fun forEachFunctionMatch(
        selection: JsonPathQuerySupport.FunctionSelection,
        current: JsonElement,
        root: () -> JsonElement,
        upstreamDefinite: Boolean,
        currentIsKeySet: Boolean = false,
        currentValue: (JsonElement) -> JsonElement,
        onMatch: (JsonElement) -> Unit,
    ) = withFunctionDocument { document ->
        JsonPathFilterSupport.withOccurrence(selection.cacheIdentity) {
            JsonPathQuerySupport.forEachFunctionMatch(
                selection, current, root, upstreamDefinite, currentIsKeySet, currentValue, onMatch,
                isKeySet = document.collections::isKeySet,
            )
        }
    }

    fun functionSelection(
        fragment: String,
        terminal: Boolean,
        scanTail: JsonPathScanTail = JsonPathScanTail.NONE,
    ): JsonPathQuerySupport.FunctionSelection =
        guard.withLock {
            val prefix = if (scanTail == JsonPathScanTail.NONE) fragment else fragment.dropLast(1)
            val query = compiledQuery(JsonPathFilterSupport.normalize("\$$prefix"))
            JsonPathQuerySupport.functionSelection(query, terminal, scanTail)
        }

    fun functionMatches(
        selection: JsonPathQuerySupport.FunctionSelection,
        current: JsonElement,
        root: JsonElement,
        upstreamDefinite: Boolean,
        currentIsKeySet: Boolean = false,
    ): List<JsonElement> = withFunctionDocument { document ->
        JsonPathFilterSupport.withRoot(root) {
            JsonPathQuerySupport.functionMatches(
                selection, current, root, upstreamDefinite, currentIsKeySet, document.collections::isKeySet,
            )
        }
    }

    private fun compiledQuery(normalized: String): JsonPathQuery {
        val query = compiledPaths.remove(normalized) ?: compiler.compile(
            jsonPath = normalized,
            functionExtensionRetriever = { name ->
                JsonPathFilterSupport.function(name)
                    ?: JsonPath.defaultFunctionExtensionRepository.getExtension(name)
            }
        )
        if (compiledPaths.size >= MAX_COMPILED_PATHS) {
            compiledPaths.remove(compiledPaths.keys.first())
        }
        compiledPaths[normalized] = query
        return query
    }

    fun isValidPath(path: String): Boolean = guard.withLock {
        try {
            compiledQuery(JsonPathFilterSupport.normalize(if (path.startsWith('@')) "$" + path.drop(1) else path))
            true
        } catch (_: Exception) {
            false
        }
    }
}
