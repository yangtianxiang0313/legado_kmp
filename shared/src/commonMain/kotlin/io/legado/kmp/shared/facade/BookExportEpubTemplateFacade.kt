package io.legado.kmp.shared.facade

/** Counts exclude the chapter template; totalBytes includes every expanded file, including it. */
public data class BookExportEpubTemplateInfo(
    val resourceCount: Int,
    val sectionCount: Int,
    val totalBytes: Long,
) {
    override fun toString(): String =
        "BookExportEpubTemplateInfo(resourceCount=$resourceCount, sectionCount=$sectionCount, totalBytes=$totalBytes)"
}

/** Inspects an in-memory Asset ZIP without exporting a book, writing files or recording input diagnostics. */
public class BookExportEpubTemplateFacade {
    @Throws(RecoverableSharedException::class)
    fun inspect(base64Zip: String): BookExportEpubTemplateInfo = try {
        val archive = BookExportEpubTemplateArchive.read(base64Zip)
        BookExportEpubTemplateInfo(
            resourceCount = archive.resources.size,
            sectionCount = archive.sectionTemplates.size,
            totalBytes = archive.chapterTemplate.encodeToByteArray().size.toLong() +
                archive.sectionTemplates.sumOf { it.data.size.toLong() } +
                archive.resources.sumOf { it.data.size.toLong() },
        )
    } catch (error: Throwable) {
        findFacadeRequestCancellation(error)?.let { throw it }
        throw RecoverableSharedException(
            "BookExportEpubTemplateFacade.inspect",
            (error as? BookExportEpubTemplateFailure)?.problem?.message
                ?: BookExportEpubTemplateProblem.INVALID_ARCHIVE.message,
        )
    }
}
