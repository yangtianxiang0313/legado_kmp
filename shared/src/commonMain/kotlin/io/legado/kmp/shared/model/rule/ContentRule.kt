package io.legado.kmp.shared.model.rule

import kotlinx.serialization.Serializable

/**
 * Content page processing rule
 */
@Serializable
data class ContentRule(
    var content: String? = null,
    var title: String? = null,
    var nextContentUrl: String? = null,
    var webJs: String? = null,
    var sourceRegex: String? = null,
    var replaceRegex: String? = null,
    var imageStyle: String? = null,
    var imageDecode: String? = null,
    var payAction: String? = null
)
