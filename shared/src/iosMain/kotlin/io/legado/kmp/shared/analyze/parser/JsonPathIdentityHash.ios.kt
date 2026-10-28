package io.legado.kmp.shared.analyze.parser

import kotlin.experimental.ExperimentalNativeApi
import kotlin.native.identityHashCode

@OptIn(ExperimentalNativeApi::class)
internal actual fun jsonPathIdentityHashCode(value: Any): Int = value.identityHashCode()
