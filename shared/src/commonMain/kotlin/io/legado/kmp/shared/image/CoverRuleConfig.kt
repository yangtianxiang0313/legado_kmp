package io.legado.kmp.shared.image

import kotlinx.serialization.Serializable

/**
 * Cover search rule configuration.
 * Mirrors legado BookCover.CoverRule data class.
 *
 * When enabled, [searchUrl] is an AnalyzeUrl template
 * and [coverRule] is an AnalyzeRule string expression.
 */
@Serializable
data class CoverRuleConfig(
    val enable: Boolean = true,
    val searchUrl: String = "",
    val coverRule: String = "",
    val concurrentRate: String? = null,
    val loginUrl: String? = null,
    val loginUi: String? = null,
    val header: String? = null,
    val jsLib: String? = null,
    val enabledCookieJar: Boolean? = false,
)
