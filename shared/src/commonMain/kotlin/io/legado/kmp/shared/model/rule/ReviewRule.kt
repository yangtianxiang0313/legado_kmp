package io.legado.kmp.shared.model.rule

import kotlinx.serialization.Serializable

/**
 * Review (comment) rule
 * Currently not actively used but kept for future compatibility
 */
@Serializable
data class ReviewRule(
    var reviewList: String? = null,
    var reviewContent: String? = null,
    var reviewUser: String? = null,
    var reviewTime: String? = null,
    var reviewCount: String? = null
)
