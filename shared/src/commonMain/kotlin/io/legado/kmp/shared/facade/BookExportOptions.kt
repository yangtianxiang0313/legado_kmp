package io.legado.kmp.shared.facade

data class BookExportOptions(
    val chapterScope: String = "",
    val chaptersPerFile: Int = 0,
    val charset: String = "UTF-8",
    val includeChapterTitle: Boolean = true,
    val useReplaceRules: Boolean = true,
    val fileNameScript: String = "",
    val splitFileNameScript: String = "",
    val includeImages: Boolean = false,
    val epubTemplateBase64: String = "",
) {
    override fun toString(): String = "BookExportOptions(redacted)"
}

data class BookExportPart(val fileName: String, val export: BookExportResult) {
    override fun toString(): String = "BookExportPart(redacted)"
}

data class BookExportBatchResult(val parts: List<BookExportPart>) {
    override fun toString(): String = "BookExportBatchResult(redacted)"
}

data class BookExportBatchRequestResult(
    val export: BookExportBatchResult? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "BookExportBatchRequestResult(redacted)"
}
