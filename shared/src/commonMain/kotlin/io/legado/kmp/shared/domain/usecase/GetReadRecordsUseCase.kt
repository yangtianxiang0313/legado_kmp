package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.model.ReadRecord
import io.legado.kmp.shared.model.ReadRecordShow

class GetReadRecordsUseCase(
    private val repository: ReadRecordRepository
) {
    suspend fun getAll(): List<ReadRecord> = repository.getAll()
    suspend fun getAllShow(): List<ReadRecordShow> = repository.getAllShow()
    suspend fun getAllTime(): Long = repository.getAllTime()
    suspend fun search(searchKey: String): List<ReadRecordShow> = repository.search(searchKey)
    suspend fun getReadTime(bookName: String): Long? = repository.getReadTime(bookName)
    suspend fun getReadTime(deviceId: String, bookName: String): Long? =
        repository.getReadTime(deviceId, bookName)
}

class SaveReadRecordUseCase(
    private val repository: ReadRecordRepository
) {
    suspend fun insert(record: ReadRecord) = repository.insert(record)
    suspend fun update(record: ReadRecord) = repository.update(record)
}

class DeleteReadRecordUseCase(
    private val repository: ReadRecordRepository
) {
    suspend fun delete(record: ReadRecord) = repository.delete(record)
    suspend fun clear() = repository.clear()
    suspend fun deleteByName(bookName: String) = repository.deleteByName(bookName)
}
