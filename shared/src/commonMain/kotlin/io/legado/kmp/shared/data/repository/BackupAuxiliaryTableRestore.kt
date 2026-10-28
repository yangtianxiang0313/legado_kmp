package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.model.BackupData

/**
 * Restores auxiliary rows inside the caller-owned synchronous SQL transaction.
 * SQL and cancellation failures propagate to the caller for rollback. JSON-backed
 * string fields are persisted verbatim, matching the repository write paths.
 */
internal fun restoreBackupAuxiliaryTables(
    database: LegadoDatabase,
    data: BackupData,
    checkActive: () -> Unit,
): Unit {
    data.rssSource.forEach { source ->
        checkActive()
        database.rssSourceQueries.insertRssSource(
            source_url = source.sourceUrl,
            source_name = source.sourceName,
            source_icon = source.sourceIcon,
            source_group = source.sourceGroup,
            source_comment = source.sourceComment,
            enabled = if (source.enabled) 1L else 0L,
            variable_comment = source.variableComment,
            js_lib = source.jsLib,
            enabled_cookie_jar = if (source.enabledCookieJar) 1L else 0L,
            concurrent_rate = source.concurrentRate,
            header_ = source.header,
            login_url = source.loginUrl,
            login_ui = source.loginUi,
            login_check_js = source.loginCheckJs,
            cover_decode_js = source.coverDecodeJs,
            sort_url = source.sortUrl,
            single_url = if (source.singleUrl) 1L else 0L,
            article_style = source.articleStyle.toLong(),
            rule_articles = source.ruleArticles,
            rule_next_page = source.ruleNextPage,
            rule_title = source.ruleTitle,
            rule_pub_date = source.rulePubDate,
            rule_description = source.ruleDescription,
            rule_image = source.ruleImage,
            rule_link = source.ruleLink,
            rule_content = source.ruleContent,
            content_whitelist = source.contentWhitelist,
            content_blacklist = source.contentBlacklist,
            should_override_url_loading = source.shouldOverrideUrlLoading,
            style = source.style,
            enable_js = if (source.enableJs) 1L else 0L,
            load_with_base_url = if (source.loadWithBaseUrl) 1L else 0L,
            inject_js = source.injectJs,
            last_update_time = source.lastUpdateTime,
            custom_order = source.customOrder.toLong(),
        )
    }

    data.replaceRule.forEach { rule ->
        checkActive()
        database.replaceRuleQueries.insert(
            id = rule.id,
            name = rule.name,
            rule_group = rule.group,
            pattern = rule.pattern,
            replacement = rule.replacement,
            scope = rule.scope,
            scope_title = if (rule.scopeTitle) 1L else 0L,
            scope_content = if (rule.scopeContent) 1L else 0L,
            exclude_scope = rule.excludeScope,
            is_enabled = if (rule.isEnabled) 1L else 0L,
            is_regex = if (rule.isRegex) 1L else 0L,
            timeout_millisecond = rule.timeoutMillisecond,
            sort_order = rule.order.toLong(),
        )
    }

    data.txtTocRule.forEach { rule ->
        checkActive()
        if (database.txtTocRuleQueries.selectById(rule.id).executeAsOneOrNull() == null) {
            database.txtTocRuleQueries.insert(
                id = rule.id,
                name = rule.name,
                rule = rule.rule,
                example = rule.example,
                serial_number = rule.serialNumber.toLong(),
                enable = if (rule.enable) 1L else 0L,
            )
        } else {
            database.txtTocRuleQueries.update(
                name = rule.name,
                rule = rule.rule,
                example = rule.example,
                serial_number = rule.serialNumber.toLong(),
                enable = if (rule.enable) 1L else 0L,
                id = rule.id,
            )
        }
    }

    data.dictRule.forEach { rule ->
        checkActive()
        database.dictRuleQueries.insert(
            name = rule.name,
            url_rule = rule.urlRule,
            show_rule = rule.showRule,
            enabled = if (rule.enabled) 1L else 0L,
            sort_number = rule.sortNumber.toLong(),
        )
    }

    data.searchHistory.forEach { keyword ->
        checkActive()
        if (database.searchKeywordQueries.selectByWord(keyword.word).executeAsOneOrNull() == null) {
            database.searchKeywordQueries.insert(
                word = keyword.word,
                usage = keyword.usage.toLong(),
                last_use_time = keyword.lastUseTime,
            )
        } else {
            database.searchKeywordQueries.update(
                usage = keyword.usage.toLong(),
                last_use_time = keyword.lastUseTime,
                word = keyword.word,
            )
        }
    }

    data.rssStar.forEach { star ->
        checkActive()
        database.rssStarQueries.insertRssStar(
            origin = star.origin,
            sort = star.sort,
            title = star.title,
            star_time = star.starTime,
            link = star.link,
            pub_date = star.pubDate,
            description = star.description,
            content = star.content,
            image = star.image,
            star_group = star.group,
            variable = star.variable,
        )
    }

    data.sourceSub.forEach { subscription ->
        checkActive()
        database.ruleSubQueries.insert(
            id = subscription.id,
            name = subscription.name,
            url = subscription.url,
            type = subscription.type.toLong(),
            custom_order = subscription.customOrder.toLong(),
            auto_update = if (subscription.autoUpdate) 1L else 0L,
            updated_at = subscription.update,
        )
    }

    data.httpTTS.forEach { engine ->
        checkActive()
        database.httpTTSQueries.insert(
            id = engine.id,
            name = engine.name,
            url = engine.url,
            content_type = engine.contentType,
            concurrent_rate = engine.concurrentRate,
            login_url = engine.loginUrl,
            login_ui = engine.loginUi,
            header_ = engine.header,
            js_lib = engine.jsLib,
            enabled_cookie_jar = if (engine.enabledCookieJar) 1L else 0L,
            login_check_js = engine.loginCheckJs,
            last_update_time = engine.lastUpdateTime,
        )
    }

    data.keyboardAssists.forEach { assist ->
        checkActive()
        database.keyboardAssistQueries.insert(
            type = assist.type.toLong(),
            key = assist.key,
            value_ = assist.value,
            serial_no = assist.serialNo.toLong(),
        )
    }

    data.servers.forEach { server ->
        checkActive()
        database.serverQueries.insert(
            id = server.id,
            name = server.name,
            type = server.type.name,
            config = server.config,
            sort_number = server.sortNumber.toLong(),
        )
    }
}
