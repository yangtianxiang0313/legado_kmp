package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookSource

data class SourceImportPreview(
    val candidates: List<SourceImportCandidate>,
    val totalCount: Int,
    val duplicateCount: Int,
    val invalidCount: Int,
)

data class SourceImportCandidate(
    val source: BookSource,
    val localSource: BookSource?,
) {
    val isNew: Boolean
        get() = localSource == null

    val isUpdate: Boolean
        get() = localSource != null && source.lastUpdateTime > localSource.lastUpdateTime

    val selectedByDefault: Boolean
        get() = isNew || isUpdate
}

data class SourceImportOptions(
    val keepName: Boolean = false,
    val keepGroup: Boolean = false,
    val keepEnabled: Boolean = false,
    val groupName: String? = null,
    val appendGroup: Boolean = false,
)
