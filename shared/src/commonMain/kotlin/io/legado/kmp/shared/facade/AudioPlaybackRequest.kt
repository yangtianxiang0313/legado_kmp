package io.legado.kmp.shared.facade

import io.legado.kmp.shared.network.PreparedMediaRequest

data class AudioPlaybackRequest(val actualChapterIndex: Int, val request: PreparedMediaRequest)
