package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.RssStar
import kotlinx.coroutines.flow.Flow

interface RssStarRepository {
    suspend fun getAll(): List<RssStar>
    fun observeGroups(): Flow<List<String>>
    fun observeByGroup(group: String): Flow<List<RssStar>>
    suspend fun get(origin: String, link: String): RssStar?
    fun observeAll(): Flow<List<RssStar>>

    suspend fun insert(vararg rssStar: RssStar)
    suspend fun update(vararg rssStar: RssStar)
    suspend fun retainContent(origin: String, link: String, content: String)
    suspend fun updateOrigin(origin: String, oldOrigin: String)
    suspend fun delete(origin: String)
    suspend fun delete(origin: String, link: String)
    suspend fun deleteByGroup(group: String)
    suspend fun deleteAll()
}
