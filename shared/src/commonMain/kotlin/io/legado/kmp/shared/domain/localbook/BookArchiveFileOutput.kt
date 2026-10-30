package io.legado.kmp.shared.domain.localbook

/**
 * Synchronous, exclusively created app-owned file. Use only on Default, serially.
 * The parent directory must already exist; existing targets are never overwritten.
 * [finish] synchronizes and closes all descriptors and is safe to repeat.
 * [abort] closes and discards only this instance's file, even after [finish].
 * Moving the file away transfers ownership: abort never follows it to a new name.
 */
internal expect class BookArchiveFileOutput(path: String, maximumBytes: Long) {
    fun write(bytes: ByteArray)
    fun finish()
    fun abort()
}
