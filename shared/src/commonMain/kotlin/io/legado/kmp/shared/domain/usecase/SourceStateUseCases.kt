package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.source.SourceStateStore

class GetLoginHeaderUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String): String? {
        return sourceStateStore.getLoginHeader(sourceKey)
    }
}

class PutLoginHeaderUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String, header: String) {
        sourceStateStore.putLoginHeader(sourceKey, header)
    }
}

class GetLoginInfoUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String): String? {
        return sourceStateStore.getLoginInfo(sourceKey)
    }
}

class PutLoginInfoUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String, info: String): Boolean {
        return sourceStateStore.putLoginInfo(sourceKey, info)
    }
}

class GetSourceVariableUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String): String? {
        return sourceStateStore.getSourceVariable(sourceKey)
    }

    suspend fun getMap(sourceKey: String): Map<String, String> {
        return sourceStateStore.getSourceVariableMap(sourceKey)
    }
}

class PutSourceVariableUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String, value: String?) {
        sourceStateStore.setSourceVariable(sourceKey, value)
    }

    suspend fun putEntry(sourceKey: String, key: String, value: String?) {
        sourceStateStore.putSourceVariable(sourceKey, key, value)
    }
}

class GetSourceValueUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String, key: String): String? {
        return sourceStateStore.getStoredValue(sourceKey, key)
    }
}

class PutSourceValueUseCase(
    private val sourceStateStore: SourceStateStore
) {
    suspend operator fun invoke(sourceKey: String, key: String, value: String?) {
        sourceStateStore.putStoredValue(sourceKey, key, value)
    }
}
