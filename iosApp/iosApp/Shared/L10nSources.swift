import Foundation

extension L10n {
    enum SourceManagement {
        static let title = text("source_management.title", "书源管理")
        static let searchPlaceholder = text("source_management.search_placeholder", "搜索书源")
        static let allGroups = text("source_management.all_groups", "全部分组")
        static let groupFilter = text("source_management.group_filter", "分组")
        static let addSourceAction = text("source_management.add_source_action", "添加书源")
        static let importAction = text("source_management.import_action", "导入")
        static let importLocalAction = text("source_management.import_local_action", "本地导入")
        static let importOnlineAction = text("source_management.import_online_action", "网络导入")
        static let importQrAction = text("source_management.import_qr_action", "扫码导入")
        static let helpAction = text("source_management.help_action", "帮助")
        static let deleteAction = text("source_management.delete_action", "删除")
        static let editAction = text("source_management.edit_action", "编辑")
        static let searchSourceAction = text("source_management.search_source_action", "搜索该源")
        static let debugAction = text("source_management.debug_action", "调试书源")
        static let enableAction = text("source_management.enable_action", "启用")
        static let disableAction = text("source_management.disable_action", "禁用")
        static let enableExploreAction = text("source_management.enable_explore_action", "启用探索")
        static let disableExploreAction = text("source_management.disable_explore_action", "禁用探索")
        static let addGroupAction = text("source_management.add_group_action", "加分组")
        static let removeGroupAction = text("source_management.remove_group_action", "移除分组")
        static let exportAction = text("source_management.export_action", "导出")
        static let moveToTopAction = text("source_management.move_to_top_action", "置顶")
        static let moveToBottomAction = text("source_management.move_to_bottom_action", "置底")
        static let sortAction = text("source_management.sort_action", "排序")
        static let selectAction = text("source_management.select_action", "多选")
        static let finishSelectionAction = text("source_management.finish_selection_action", "完成多选")
        static let sortManual = text("source_management.sort_manual", "手动排序")
        static let sortName = text("source_management.sort_name", "按名称")
        static let sortUrl = text("source_management.sort_url", "按 URL")
        static let sortWeight = text("source_management.sort_weight", "智能排序")
        static let sortUpdated = text("source_management.sort_updated", "按更新时间")
        static let sortRespond = text("source_management.sort_respond", "按响应时间")
        static let sortEnabled = text("source_management.sort_enabled", "按启用状态")
        static let sortAscendingAction = text("source_management.sort_ascending_action", "切换升序")
        static let sortDescendingAction = text("source_management.sort_descending_action", "切换降序")
        static let enabledBadge = text("source_management.enabled_badge", "已启用")
        static let disabledBadge = text("source_management.disabled_badge", "已禁用")
        static let exploreEnabledBadge = text("source_management.explore_enabled_badge", "探索开")
        static let exploreDisabledBadge = text("source_management.explore_disabled_badge", "探索关")
        static let loginRequiredBadge = text("source_management.login_required_badge", "需登录")
        static let groupNamePlaceholder = text("source_management.group_name_placeholder", "输入分组名")
        static let helpMessage = text(
            "source_management.help_message",
            "支持 legado 风格的导入、筛选、排序、单源编辑和批量操作。搜索框也支持启用、禁用、需登录、无分组、启用探索、禁用探索以及 group:分组名。")
        static let qrDeferredMessage = text(
            "source_management.qr_deferred_message", "二维码导入入口已保留，本轮先交付可用的 JSON、文件和 URL 导入链路。")
        static let groupByDomainAction = text("source_management.group_by_domain_action", "按域名分组")
        static let groupManageAction = text("source_management.group_manage_action", "管理分组")
        static let groupManageTitle = text("source_management.group_manage_title", "书源分组")
        static let addGroupTitle = text("source_management.add_group_title", "新增分组")
        static let renameGroupTitle = text("source_management.rename_group_title", "重命名分组")
        static let deleteGroupTitle = text("source_management.delete_group_title", "删除分组")
        static let persistSortAction = text("source_management.persist_sort_action", "保存当前排序")
        static let persistSortDone = text("source_management.persist_sort_done", "已写回当前排序")
        static let deleteConfirmSingle = text("source_management.delete_confirm_single", "确定删除这条书源？")
        static let loading = text("source_management.loading", "正在加载书源…")
        static let unavailable = text("source_management.unavailable", "书源管理不可用")
        static let loadFailed = text("source_management.load_failed", "书源加载失败")
        static let searchFailed = text("source_management.search_failed", "书源搜索失败")
        static let empty = text("source_management.empty", "还没有书源，先点右上角导入。")
        static let noMatch = text("source_management.no_match", "没有匹配的书源。")
        static let emptyStateTitle = text("source_management.empty_state_title", "还没有书源")
        static let emptyStateMessage = text(
            "source_management.empty_state_message", "可以先导入内置默认书源，确认搜索和阅读链路跑通后，再导入其他书源。")
        static let importBundledAction = text("source_management.import_bundled_action", "导入内置书源")
        static let importBundledLoading = text("source_management.import_bundled_loading", "正在导入内置书源…")
        static let importBundledFailed = text("source_management.import_bundled_failed", "导入内置书源失败")
        static let importBundledDoneTitle = text("source_management.import_bundled_done_title", "内置书源已导入")
        static let importBundledDoneMessage = text(
            "source_management.import_bundled_done_message", "现在可以直接去搜索，确认从书源到阅读页的主链路。")
        static let stayHere = text("source_management.stay_here", "留在这里")
        static let goSearch = text("source_management.go_search", "去搜索")

        // F33: Import preview
        static let importPreviewTitle = text("source_management.import_preview_title", "导入预览")
        static let importPreviewConfirm = text("source_management.import_preview_confirm", "确认导入")
        static let importPreviewParsing = text("source_management.import_preview_parsing", "正在解析书源…")

        static func importPreviewMessage(_ count: Int) -> String {
            format("source_management.import_preview_message", "即将导入 %d 条书源：", count)
        }

        static func selectionTitle(_ count: Int) -> String {
            format("source_management.selection_title", "已选 %d 条书源", count)
        }

        static func deleteConfirmMultiple(_ count: Int) -> String {
            format("source_management.delete_confirm_multiple", "确定删除这 %d 条书源？", count)
        }
        // F104: 批量校验书源
        static let verifyAll = text("source_management.verify_all", "校验全部")
        static let verifyProgress = text("source_management.verify_progress", "校验进度")
        static let verifyRunning = text("source_management.verify_running", "正在校验…")
        static let verifyPaused = text("source_management.verify_paused", "校验已暂停")
        static let verifyDone = text("source_management.verify_done", "校验完成")
        static let verifyPause = text("source_management.verify_pause", "暂停校验")
        static let verifyResume = text("source_management.verify_resume", "继续校验")
        static let verifyCancel = text("source_management.verify_cancel", "取消校验")
    }

    enum SourceMgmt {
        static let scanQrCode = text("source_mgmt.scan_qr_code", "扫码导入")
        static let scanQrCodeTitle = text("source_mgmt.scan_qr_code_title", "扫描二维码")
        static let cameraPermissionDeniedTitle = text("source_mgmt.camera_permission_denied_title", "相机权限未开启")
        static let cameraPermissionDeniedMessage = text(
            "source_mgmt.camera_permission_denied_message", "请在系统设置中开启相机权限，以便扫描二维码导入书源。")
        static let cameraUnavailableTitle = text("source_mgmt.camera_unavailable_title", "相机不可用")
        static let cameraUnavailableMessage = text("source_mgmt.camera_unavailable_message", "无法访问相机设备。")
        static let openSettings = text("source_mgmt.open_settings", "前往设置")
        static let qrImportingMessage = text("source_mgmt.qr_importing_message", "正在导入…")

        static func qrImportSuccess(_ count: Int) -> String {
            format("source_mgmt.qr_import_success", "成功导入 %d 个书源", count)
        }

        static let qrInvalidContent = text("source_mgmt.qr_invalid_content", "无效的二维码内容")
    }

    enum SourceEdit {
        static let createTitle = text("source_edit.create_title", "新建书源")
        static let editTitle = text("source_edit.edit_title", "编辑书源")
        static let saveAction = text("source_edit.save_action", "保存")
        static let debugAction = text("source_edit.debug_action", "调试书源")
        static let clearCookieAction = text("source_edit.clear_cookie_action", "清 Cookie")
        static let copyAction = text("source_edit.copy_action", "复制书源")
        static let pasteAction = text("source_edit.paste_action", "粘贴书源")
        static let shareAction = text("source_edit.share_action", "分享 JSON")
        static let qrShareAction = text("source_edit.qr_share_action", "二维码分享")
        static let loginAction = text("source_edit.login_action", "登录")
        static let searchAction = text("source_edit.search_action", "搜索该源")
        static let variableHelpAction = text("source_edit.variable_help_action", "书源变量/帮助")
        static let variableHelpMessage = text(
            "source_edit.variable_help_message", "这里显示当前书源的变量说明；如果书源没有填写变量注释，就只保留帮助入口。")
        static let qrDeferredMessage = text("source_edit.qr_deferred_message", "二维码分享入口已保留，本轮先交付真实 JSON 复制和分享。")
        static let loginExecutedMessage = text("source_edit.login_executed_message", "shared 已执行登录脚本并刷新登录态。")
        static let loginUnavailableMessage = text("source_edit.login_unavailable_message", "当前书源没有可跳转的登录地址。")
        static let loading = text("source_edit.loading", "正在加载书源…")
        static let loadFailed = text("source_edit.load_failed", "书源加载失败")
        static let saving = text("source_edit.saving", "正在保存书源…")
        static let unsavedTitle = text("source_edit.unsaved_title", "放弃未保存修改？")
        static let unsavedMessage = text("source_edit.unsaved_message", "当前修改尚未保存，返回会丢失本次编辑内容。")
        static let discardAction = text("source_edit.discard_action", "放弃修改")
        static let baseTab = text("source_edit.base_tab", "基础")
        static let searchTab = text("source_edit.search_tab", "搜索")
        static let exploreTab = text("source_edit.explore_tab", "发现")
        static let infoTab = text("source_edit.info_tab", "详情")
        static let tocTab = text("source_edit.toc_tab", "目录")
        static let contentTab = text("source_edit.content_tab", "正文")
        static let nameTitle = text("source_edit.name_title", "名称")
        static let urlTitle = text("source_edit.url_title", "URL")
        static let groupTitle = text("source_edit.group_title", "分组")
        static let typeTitle = text("source_edit.type_title", "类型")
        static let bookUrlPatternTitle = text("source_edit.book_url_pattern_title", "详情页 URL Pattern")
        static let concurrentRateTitle = text("source_edit.concurrent_rate_title", "并发")
        static let jsLibTitle = text("source_edit.js_lib_title", "JS Lib")
        static let enabledTitle = text("source_edit.enabled_title", "启用")
        static let enabledExploreTitle = text("source_edit.enabled_explore_title", "启用探索")
        static let cookieJarTitle = text("source_edit.cookie_jar_title", "CookieJar")
        static let headerTitle = text("source_edit.header_title", "Header")
        static let loginUrlTitle = text("source_edit.login_url_title", "Login URL")
        static let loginUiTitle = text("source_edit.login_ui_title", "Login UI")
        static let loginCheckJsTitle = text("source_edit.login_check_js_title", "Login Check JS")
        static let coverDecodeJsTitle = text("source_edit.cover_decode_js_title", "Cover Decode JS")
        static let commentTitle = text("source_edit.comment_title", "备注")
        static let variableCommentTitle = text("source_edit.variable_comment_title", "变量说明")
        static let searchUrlTitle = text("source_edit.search_url_title", "Search URL")
        static let exploreUrlTitle = text("source_edit.explore_url_title", "Explore URL")
        static let exploreScreenTitle = text("source_edit.explore_screen_title", "Explore Screen")
        static let ruleSearchTitle = text("source_edit.rule_search_title", "搜索规则 JSON")
        static let ruleExploreTitle = text("source_edit.rule_explore_title", "发现规则 JSON")
        static let ruleBookInfoTitle = text("source_edit.rule_book_info_title", "详情规则 JSON")
        static let ruleReviewTitle = text("source_edit.rule_review_title", "评论规则 JSON")
        static let ruleTocTitle = text("source_edit.rule_toc_title", "目录规则 JSON")
        static let ruleContentTitle = text("source_edit.rule_content_title", "正文规则 JSON")
    }

    enum SourceImport {
        static let title = text("source_import.title", "导入书源")
        static let jsonMode = text("source_import.json_mode", "JSON")
        static let urlMode = text("source_import.url_mode", "URL")
        static let fileMode = text("source_import.file_mode", "文件")
        static let urlPlaceholder = text("source_import.url_placeholder", "https://example.com/book-sources.json")
        static let filePlaceholder = text("source_import.file_placeholder", "未选择文件")
        static let chooseFile = text("source_import.choose_file", "选择文件")
        static let helperPayload = text(
            "source_import.helper_payload", "支持粘贴单个书源对象、书源数组 JSON，或填写远程书源 JSON 地址。导入后会写入 shared 数据库，搜索页直接可用。")
        static let helperUrl = text("source_import.helper_url", "填写远程书源 JSON 地址。shared 会先拉取内容，再做书源解析和入库。")
        static let helperJson = text("source_import.helper_json", "粘贴单个书源对象或书源数组 JSON。导入后会写入 shared 数据库，搜索页直接可用。")
        static let helperFile = text(
            "source_import.helper_file", "选择本地 .json 或 .txt 书源文件。iOS 只读取文本内容，实际解析和入库仍统一走 shared。")
        static let importAction = text("source_import.import_action", "导入")
        static let cancelAction = text("source_import.cancel_action", "取消")
        static let resultPanelTitle = text("source_import.result_panel_title", "导入结果")
        static let resultPanelWaiting = text("source_import.result_panel_waiting", "导入完成后会在这里显示结果摘要。")
        static let loadingPrepare = text("source_import.loading_prepare", "正在准备导入能力…")
        static let unavailable = text("source_import.unavailable", "导入能力不可用")
        static let failed = text("source_import.failed", "导入失败")
        static let loadingPayload = text("source_import.loading_payload", "正在导入书源…")
        static let loadingUrl = text("source_import.loading_url", "正在拉取并导入书源…")
        static let loadingFile = text("source_import.loading_file", "正在读取并导入文件…")
        static let successTitle = text("source_import.success_title", "导入完成")
        static let stayImporting = text("source_import.stay_importing", "继续导入")
        static let openSearch = text("source_import.open_search", "立即搜索")
        static let backToSourceManagement = text("source_import.back_to_source_management", "返回书源管理")

        static func successMessage(
            importedCount: Int,
            addedCount: Int,
            updatedCount: Int,
            duplicateCount: Int,
            invalidCount: Int
        ) -> String {
            let lines = [
                format("source_import.success_message_imported", "已写入 %d 条书源。", importedCount),
                format("source_import.success_message_added", "新增 %d 条。", addedCount),
                format("source_import.success_message_updated", "更新 %d 条。", updatedCount),
                format("source_import.success_message_duplicate", "重复合并 %d 条。", duplicateCount),
                format("source_import.success_message_invalid", "无效忽略 %d 条。", invalidCount),
            ]
            return lines.joined(separator: "\n")
        }
    }

    enum RssSourceDebug {
        static let title = text("rss.source_debug_title", "源调试")
        static let startAction = text("rss.source_debug_start_action", "开始调试")
        static let step1Name = text("rss.source_debug_step1_name", "Step 1: 分类加载")
        static let step2Name = text("rss.source_debug_step2_name", "Step 2: 文章列表")
        static let step3Name = text("rss.source_debug_step3_name", "Step 3: 内容加载")
        static let statusLoading = text("rss.source_debug_status_loading", "⏳")
        static let statusSuccess = text("rss.source_debug_status_success", "✅")
        static let statusFailed = text("rss.source_debug_status_failed", "❌")
        static let loadingMessage = text("rss.source_debug_loading_message", "正在加载…")
        static let emptyResult = text("rss.source_debug_empty_result", "结果为空")
        static let noSorts = text("rss.source_debug_no_sorts", "未获取到分类数据")
        static let noArticles = text("rss.source_debug_no_articles", "未获取到文章数据")
    }
}
