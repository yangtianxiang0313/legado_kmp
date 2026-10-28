@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.image

import kotlinx.coroutines.suspendCancellableCoroutine
import platform.WebKit.WKContentRuleList
import platform.WebKit.WKContentRuleListStore
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Accessed only on main while holding the render mutex. Only constant policy, never book data,
// is stored in WebKit's compiled-rule cache; each web view still has a new ephemeral data store.
private var localBookSvgRules: WKContentRuleList? = null

internal suspend fun localBookSvgContentRules(): WKContentRuleList {
    localBookSvgRules?.let { return it }
    return suspendCancellableCoroutine { continuation ->
        checkNotNull(WKContentRuleListStore.defaultStore()).compileContentRuleListForIdentifier(
            identifier = "io.legado.local-book-svg.data-images-only.v1",
            encodedContentRuleList = LOCAL_SVG_RULES,
        ) { rules, error ->
            onLocalBookSvgMain {
                if (!continuation.isActive) return@onLocalBookSvgMain
                if (error != null || rules == null) {
                    continuation.resumeWithException(IllegalStateException(
                        "Local book SVG content blocker failed: ${error?.localizedDescription ?: "no rule list"}",
                    ))
                } else {
                    localBookSvgRules = rules
                    continuation.resume(rules)
                }
            }
        }
    }
}

// Deny all schemes (including file:, blob:, network and custom handlers), then allow only
// data images and the one native-created HTML document. Fonts remain blocked, even data fonts.
private const val LOCAL_SVG_RULES = """
    [
      {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^data:image/","resource-type":["image","svg-document"]},
       "action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^about:blank$","resource-type":["document"]},
       "action":{"type":"ignore-previous-rules"}}
    ]
"""
