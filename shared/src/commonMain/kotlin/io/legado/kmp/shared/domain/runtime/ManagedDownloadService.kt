package io.legado.kmp.shared.domain.runtime

import io.legado.kmp.shared.platform.createSystemDownloadService
import io.legado.kmp.shared.preferences.AppPreferencesStore

/** Standalone file transfers; deliberately independent of chapter-cache scheduling. */
class ManagedDownloadService(
    private val preferencesStore: AppPreferencesStore,
) : DownloadService by createSystemDownloadService()
