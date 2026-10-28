package io.legado.kmp.shared.facade

data class BookExportProgress(
    val completed: Int,
    val total: Int,
) {
    override fun toString(): String = "BookExportProgress(completed=$completed, total=$total)"
}

data class BookExportResult(
    val data: ByteArray,
    val fileExtension: String,
    val chapterCount: Int,
    val readableChapterCount: Int,
    val missingChapterCount: Int,
    val missingImageCount: Int,
) {
    override fun toString(): String = "BookExportResult(redacted)"
}

data class BookExportRequestResult(
    val export: BookExportResult? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "BookExportRequestResult(redacted)"
}
