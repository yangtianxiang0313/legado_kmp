package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.Cookie

class GetCookiesUseCase(
    private val repository: CookieRepository
) {
    suspend fun get(url: String): Cookie? = repository.get(url)
    suspend fun getAll(): List<Cookie> = repository.getAll()
    suspend fun getOkHttpCookies(): List<Cookie> = repository.getOkHttpCookies()
}

class SaveCookieUseCase(
    private val repository: CookieRepository
) {
    suspend fun insert(cookie: Cookie) = repository.insert(cookie)
    suspend fun update(cookie: Cookie) = repository.update(cookie)
}

class DeleteCookieUseCase(
    private val repository: CookieRepository
) {
    suspend fun delete(url: String) = repository.delete(url)
    suspend fun deleteOkHttp() = repository.deleteOkHttp()
}
