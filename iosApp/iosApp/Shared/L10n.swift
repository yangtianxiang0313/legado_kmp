import Foundation

enum L10n {
    enum Common {
        static let retry = text("common.retry", "重试")
        static let cancel = text("common.cancel", "取消")
        static let ok = text("common.ok", "确定")
        static let confirm = text("common.confirm", "确认")
        static let close = text("common.close", "知道了")
        static let save = text("common.save", "保存")
        static let edit = text("common.edit", "编辑")
        static let delete = text("common.delete", "删除")
        static let clear = text("common.clear", "清空")
        static let refresh = text("common.refresh", "刷新")
        static let loadMore = text("common.load_more", "加载更多")
        static let loadingTitle = text("common.loading_title", "加载中")
        static let unavailableTitle = text("common.unavailable_title", "暂时不可用")
        static let loadFailedTitle = text("common.load_failed_title", "加载失败")
        static let notImplementedMessage = text("common.not_implemented_message", "%@ 仍未实现，当前只保留 legacy 结构入口。")
    }

    enum Tabs {
        static let bookshelf = text("tabs.bookshelf", "书架")
        static let discovery = text("tabs.discovery", "发现")
        static let rss = text("tabs.rss", "RSS")
        static let settings = text("tabs.settings", "我的")
    }

    enum Startup {
        static let appTitle = text("startup.app_title", "Legado")
        static let bootstrapping = text("startup.bootstrapping", "正在初始化书城…")
        static let retrying = text("startup.retrying", "正在重新初始化书城…")
    }

    enum Shared {
        static let emptyValue = text("shared.empty_value", "Shared 调用未返回结果")
    }

    enum Errors {
        static let bundledSourcesMissing = text("errors.bundled_sources_missing", "没有找到内置书源文件")
        static let sourceUrlEmpty = text("errors.source_url_empty", "先输入书源 URL")
        static let sourcePayloadEmpty = text("errors.source_payload_empty", "先粘贴书源 JSON")
        static let sourceFileEmpty = text("errors.source_file_empty", "先选择书源文件")
        static let sourceFileReadFailed = text("errors.source_file_read_failed", "书源文件读取失败，请确认文件可访问且内容是 UTF-8 文本。")
        static let sourcePayloadParse = text("errors.source_payload_parse", "书源内容解析失败，请检查 JSON 格式。")
        static let sourcePayloadInvalid = text("errors.source_payload_invalid", "没有识别到有效书源。")
        static let sourceUrlInvalid = text("errors.source_url_invalid", "书源 URL 必须以 http:// 或 https:// 开头。")
        static let xpathUnsupported = text("errors.xpath_unsupported", "当前 iOS 版本还不支持 XPath 规则。")
        static let webViewUnsupported = text("errors.webview_unsupported", "当前 iOS 版本还不支持 WebView 请求规则。")
        static let proxyUnsupported = text("errors.proxy_unsupported", "当前 iOS 版本还不支持代理请求规则。")
        static let mediaUnsupported = text("errors.media_unsupported", "当前 iOS 版本还不支持媒体请求规则。")
    }

    enum ContentState {
        static let emptyTable = text("content_state.empty_table", "暂无内容")
    }

    enum Settings {
        static let title = text("settings.title", "我的")
        static let helpTitle = text("settings.help_title", "帮助")
        static let helpMessage = text("settings.help_message", "这里集中管理书源、净化规则、阅读外观、备份恢复、书签、阅读记录和本地/远程文件。")
        static let configTitle = text("settings.config_title", "设置")
        static let loading = text("settings.loading", "正在加载设置…")
        static let unavailable = text("settings.unavailable", "设置暂时不可用")
        static let failed = text("settings.failed", "设置加载失败")
        static let bookshelfSectionTitle = text("settings.bookshelf_section_title", "书城与书架")
        static let readingSectionTitle = text("settings.reading_section_title", "阅读")
        static let configSectionTitle = text("settings.config_section_title", "应用")
        static let otherSectionTitle = text("settings.other_section_title", "其它")
        static let sourceManagementEntryDetail = text("settings.source_management_entry_detail", "书源导入、筛选和启停")
        static let txtTocRuleTitle = text("settings.txt_toc_rule_title", "TXT目录规则")
        static let txtTocRuleDetail = text("settings.txt_toc_rule_detail", "TXT目录识别与分章规则")
        static let txtTocRuleListEmptyTitle = text("settings.txt_toc_rule_list_empty_title", "还没有目录规则")
        static let txtTocRuleListEmptyDetail = text(
            "settings.txt_toc_rule_list_empty_detail", "新增正则后，本地 TXT 会按已启用规则识别目录并分章。")
        static let txtTocRuleAddAction = text("settings.txt_toc_rule_add_action", "新增规则")
        static let txtTocRuleEditTitle = text("settings.txt_toc_rule_edit_title", "编辑目录规则")
        static let txtTocRuleCreateTitle = text("settings.txt_toc_rule_create_title", "新增目录规则")
        static let txtTocRuleNameTitle = text("settings.txt_toc_rule_name_title", "规则名")
        static let txtTocRulePatternTitle = text("settings.txt_toc_rule_pattern_title", "正则")
        static let txtTocRuleExampleTitle = text("settings.txt_toc_rule_example_title", "示例")
        static let txtTocRuleEnabled = text("settings.txt_toc_rule_enabled", "已启用")
        static let txtTocRuleDisabled = text("settings.txt_toc_rule_disabled", "未启用")
        static let txtTocRuleDeleteTitle = text("settings.txt_toc_rule_delete_title", "删除目录规则")
        static let txtTocRuleDeleteMessage = text("settings.txt_toc_rule_delete_message", "删除后，本地 TXT 将不再使用这条规则识别目录。")
        static let txtTocRuleValidationMessage = text("settings.txt_toc_rule_validation_message", "规则名和正则都不能为空。")
        static let txtTocRuleNamePlaceholder = text("settings.txt_toc_rule_name_placeholder", "例如：章节标题")
        static let txtTocRulePatternPlaceholder = text("settings.txt_toc_rule_pattern_placeholder", "^第.+章.*$")
        static let txtTocRuleExamplePlaceholder = text("settings.txt_toc_rule_example_placeholder", "例如：第一章 开始")
        static let replaceRuleTitle = text("settings.replace_rule_title", "替换净化")
        static let replaceRuleDetail = text("settings.replace_rule_detail", "正文替换、净化与显示处理")
        static let dictRuleTitle = text("settings.dict_rule_title", "字典规则")
        static let dictRuleDetail = text("settings.dict_rule_detail", "词典与划词规则")
        static let dictRuleAddAction = text("settings.dict_rule_add_action", "添加")
        static let dictRuleCreateTitle = text("settings.dict_rule_create_title", "新建字典规则")
        static let dictRuleEditTitle = text("settings.dict_rule_edit_title", "编辑字典规则")
        static let dictRuleNamePlaceholder = text("settings.dict_rule_name_placeholder", "规则名称")
        static let dictRuleUrlPlaceholder = text("settings.dict_rule_url_placeholder", "URL规则")
        static let dictRuleShowPlaceholder = text("settings.dict_rule_show_placeholder", "显示规则")
        static let dictRuleDeleteTitle = text("settings.dict_rule_delete_title", "删除字典规则")
        static let dictRuleDeleteMessage = text("settings.dict_rule_delete_message", "确定要删除该字典规则吗？")
        static let dictRuleValidationMessage = text("settings.dict_rule_validation_message", "规则名称不能为空。")
        static let dictRuleListEmptyTitle = text("settings.dict_rule_list_empty_title", "暂无字典规则")
        static let dictRuleListEmptyDetail = text("settings.dict_rule_list_empty_detail", "点击添加按钮创建新规则")
        static let dictRuleEnabled = text("settings.dict_rule_enabled", "已启用")
        static let dictRuleDisabled = text("settings.dict_rule_disabled", "已停用")
        static let dictRuleImportTitle = text("settings.dict_rule_import_title", "导入字典规则")
        static let dictRuleImportMessage = text("settings.dict_rule_import_message", "请粘贴字典规则 JSON")
        static let dictRuleImportSuccess = text("settings.dict_rule_import_success", "成功导入 %d 条规则")
        static let dictRuleExportTitle = text("settings.dict_rule_export_title", "导出字典规则")
        static let dictRuleExportSuccess = text("settings.dict_rule_export_success", "已复制到剪贴板")
        static let themeModeRootDetail = text("settings.theme_mode_root_detail", "选择主题模式")
        static let webServiceTitle = text("settings.web_service_title", "Web服务")
        static let webServiceDetail = text("settings.web_service_detail", "局域网访问与传输")
        static let webServiceMessage = text(
            "settings.web_service_message", "iOS 端保留局域网传输入口；本地书导入可从书架页或系统文件分享进入，远程文件通过 WebDAV 文件管理同步。")
        static let themeSettingRootTitle = text("settings.theme_setting_root_title", "主题设置")
        static let themeSettingRootDetail = text("settings.theme_setting_root_detail", "主题模式、主题预设与外观")
        static let backupTitle = text("settings.backup_title", "备份恢复")
        static let backupDetail = text("settings.backup_detail", "WebDAV 与配置备份恢复")
        static let backupPathTitle = text("settings.backup_path_title", "备份路径")
        static let backupNowTitle = text("settings.backup_now_title", "备份")
        static let restoreNowTitle = text("settings.restore_now_title", "恢复")
        static let webDavTitle = text("settings.web_dav_title", "WebDAV")
        static let webDavCheckDetail = text("settings.web_dav_check_detail", "检查连接并初始化远程目录")
        static let webDavChecking = text("settings.web_dav_checking", "正在检查 WebDAV...")
        static let webDavCheckSuccess = text("settings.web_dav_check_success", "WebDAV 连接正常，远程目录已就绪。")
        static let webDavCheckFailed = text("settings.web_dav_check_failed", "WebDAV 未配置或连接失败，请先检查服务器地址、账号和授权密码。")
        static let webDavUrlTitle = text("settings.web_dav_url_title", "WebDAV 服务器地址")
        static let webDavUrlPlaceholder = text("settings.web_dav_url_placeholder", "输入你的服务器地址")
        static let webDavAccountTitle = text("settings.web_dav_account_title", "WebDAV 账号")
        static let webDavAccountPlaceholder = text("settings.web_dav_account_placeholder", "输入你的 WebDAV 账号")
        static let webDavPasswordTitle = text("settings.web_dav_password_title", "WebDAV 密码")
        static let webDavPasswordPlaceholder = text("settings.web_dav_password_placeholder", "输入你的 WebDAV 授权密码")
        static let webDavPasswordMask = text("settings.web_dav_password_mask", "••••••")
        static let webDavDirTitle = text("settings.web_dav_dir_title", "WebDAV 子目录")
        static let webDavDeviceNameTitle = text("settings.web_dav_device_name_title", "设备名")
        static let syncBookProgressTitle = text("settings.sync_book_progress_title", "同步阅读进度")
        static let syncBookProgressPlusTitle = text("settings.sync_book_progress_plus_title", "增强阅读进度同步")
        static let restoreIgnoreTitle = text("settings.restore_ignore_title", "恢复时忽略项")
        static let onlyLatestBackupTitle = text("settings.only_latest_backup_title", "仅保留最新备份")
        static let autoCheckNewBackupTitle = text("settings.auto_check_new_backup_title", "自动检查新备份")
        static let notImplementedValue = text("settings.not_implemented_value", "未设置")
        static let backupNowDetail = text("settings.backup_now_detail", "本地 ZIP 备份与 WebDAV 云备份")
        static let restoreNowDetail = text("settings.restore_now_detail", "本地文件或 WebDAV，支持 Android ZIP 和旧版 JSON")
        static let backupProcessing = text("settings.backup_processing", "正在备份...")
        static let backupSuccess = text("settings.backup_success", "备份成功")
        static let restoreProcessing = text("settings.restore_processing", "正在恢复...")
        static let restoreSuccess = text("settings.restore_success", "恢复成功")
        static let restoreConfirmTitle = text("settings.restore_confirm_title", "确认恢复")
        static let restoreConfirmMessage = text("settings.restore_confirm_message", "恢复将覆盖当前数据，确定继续吗？")
        static let backupRestoreSummary = text("settings.backup_restore_summary", "书籍 %d，书源 %d，RSS源 %d，替换规则 %d，书签 %d")
        static let readerAppearanceEntryDetail = text("settings.reader_appearance_entry_detail", "排版、亮度、点击区和翻页")
        static let appConfigEntryTitle = text("settings.app_config_entry_title", "其它设置")
        static let appConfigEntryDetail = text("settings.app_config_entry_detail", "与功能相关的一些设置")
        static let bookmarkTitle = text("settings.bookmark_title", "书签")
        static let bookmarkDetail = text("settings.bookmark_detail", "查看全部书签")
        static let readRecordTitle = text("settings.read_record_title", "阅读记录")
        static let readRecordDetail = text("settings.read_record_detail", "最近阅读与历史记录")
        static let readRecordEmpty = text("settings.read_record_empty", "暂无阅读记录")
        static let readRecordClearTitle = text("settings.read_record_clear_title", "清空阅读记录")
        static let readRecordClearMessage = text("settings.read_record_clear_message", "确定清空全部阅读记录？")
        static let readRecordClearSuccess = text("settings.read_record_clear_success", "阅读记录已清空")
        static let readRecordMinutes = text("settings.read_record_minutes", "分钟")
        static let readRecordHours = text("settings.read_record_hours", "小时")
        static func readRecordSummary(time: String, date: String) -> String {
            format("settings.read_record_summary", "累计 %@ · 最近 %@", time, date)
        }
        static let fileManageTitle = text("settings.file_manage_title", "文件管理")
        static let fileManageDetail = text("settings.file_manage_detail", "本地文件与下载文件管理")
        static let fileManageUnavailable = text("settings.file_manage_unavailable", "文件管理依赖书架和远程书籍能力，当前运行时未就绪。")
        static let aboutTitle = text("settings.about_title", "关于")
        static let aboutDetail = text("settings.about_detail", "版本信息与项目说明")
        static let exitTitle = text("settings.exit_title", "退出")
        static let exitDetail = text("settings.exit_detail", "退出当前应用")
        static let exitMessage = text("settings.exit_message", "iOS 不允许应用自行退出。可以从系统多任务界面关闭应用。")
        static let sourceManagementTitle = text("settings.source_management_title", "书源管理")
        static let sourceManagementDetail = text("settings.source_management_detail", "导入、启用和删除书源")
        static let readerAppearanceTitle = text("settings.reader_appearance_title", "阅读样式")
        static let themePresetTitle = text("settings.theme_preset_title", "主题预设")
        static let themeModeTitle = text("settings.theme_mode_title", "主题模式")
        static let bookshelfLayoutTitle = text("settings.bookshelf_layout_title", "书架布局")
        static let precisionSearchTitle = text("settings.precision_search_title", "精准搜索")
        static let threadCountTitle = text("settings.thread_count_title", "并发线程")
        static let themePresetPicker = text("settings.theme_preset_picker", "主题预设")
        static let themeModePicker = text("settings.theme_mode_picker", "主题模式")
        static let bookshelfLayoutPicker = text("settings.bookshelf_layout_picker", "书架布局")
        static let threadCountPicker = text("settings.thread_count_picker", "并发线程")
        static let themeModeSystem = text("settings.theme_mode_system", "跟随系统")
        static let themeModeLight = text("settings.theme_mode_light", "浅色")
        static let themeModeDark = text("settings.theme_mode_dark", "深色")
        static let layoutGrid = text("settings.layout_grid", "网格")
        static let layoutList = text("settings.layout_list", "列表")
        static let layoutGrid3 = text("settings.layout_grid_3", "网格3列")
        static let layoutGrid4 = text("settings.layout_grid_4", "网格4列")
        static let layoutGrid5 = text("settings.layout_grid_5", "网格5列")
        static let layoutGrid6 = text("settings.layout_grid_6", "网格6列")
        static let precisionSearchOn = text("settings.precision_search_on", "已开启")
        static let precisionSearchOff = text("settings.precision_search_off", "已关闭")
        static let enabled = text("settings.enabled", "已开启")
        static let disabled = text("settings.disabled", "已关闭")
        static let readerPresetFallback = text("settings.reader_preset_fallback", "Legado 默认")
        static let themePresetFallback = text("settings.theme_preset_fallback", "Default")
        static let backupIgnoreNone = text("settings.backup_ignore_none", "不忽略任何项")
        static let backupIgnoreDialog = text("settings.backup_ignore_dialog", "恢复忽略项")
        static let keepScreenOnTitle = text("settings.keep_screen_on_title", "屏幕常亮")
        static let keepScreenOnDetail = text("settings.keep_screen_on_detail", "阅读时保持屏幕常亮")
        static let aboutVersion = text("settings.about_version", "版本")
        static let aboutBuild = text("settings.about_build", "构建号")
        static let aboutPrivacyPolicy = text("settings.about_privacy_policy", "隐私政策")
        static let aboutOpenSourceLicense = text("settings.about_open_source_license", "开源许可")
        static let aboutContributors = text("settings.about_contributors", "贡献者")
        static let aboutDisclaimer = text("settings.about_disclaimer", "免责声明")
        static let aboutRateApp = text("settings.about_rate_app", "给应用评分")
        static let aboutShareApp = text("settings.about_share_app", "分享应用")
        static let aboutShareText = text("settings.about_share_text", "随身阅读器")
        static let aboutDisclaimerContent = text(
            "settings.about_disclaimer_content",
            "本应用是阅读工具。使用书源、订阅、网页或网络媒体时，请确认您有权访问和使用相关内容，并遵守内容提供方的条款。导入规则不代表已取得内容授权，免责声明也不能替代必要授权。")
        static let showDiscoveryTitle = text("settings.show_discovery_title", "显示发现")
        static let showRssTitle = text("settings.show_rss_title", "显示订阅")
        static let defaultHomeTitle = text("settings.default_home_title", "默认首页")
        static let defaultHomePicker = text("settings.default_home_picker", "选择默认首页")
        static let clearCacheTitle = text("settings.clear_cache_title", "清除缓存")
        static let clearCacheDetail = text("settings.clear_cache_detail", "清除图片与网络缓存")
        static let clearCacheSuccess = text("settings.clear_cache_success", "缓存已清除")
        // F67: 隐藏状态栏（阅读设置）
        static let hideStatusBarTitle = text("settings.hide_status_bar_title", "隐藏状态栏")
        static let hideStatusBarDetail = text("settings.hide_status_bar_detail", "阅读时隐藏状态栏")
        // F68: 隐藏导航栏（阅读设置）
        static let hideNavigationBarTitle = text("settings.hide_navigation_bar_title", "隐藏导航栏")
        static let hideNavigationBarDetail = text("settings.hide_navigation_bar_detail", "阅读时隐藏系统导航栏")
        // F74: 两端对齐（阅读设置）
        static let textFullJustifyTitle = text("settings.text_full_justify_title", "两端对齐")
        static let textFullJustifyDetail = text("settings.text_full_justify_detail", "阅读时文字两端对齐")
        // F75: 底部对齐（阅读设置）
        static let textBottomJustifyTitle = text("settings.text_bottom_justify_title", "底部对齐")
        static let textBottomJustifyDetail = text("settings.text_bottom_justify_detail", "分页时正文尽量贴底")
        // F103: 启动自动刷新（其它设置）
        static let autoRefreshOnStartTitle = text("settings.auto_refresh_on_start_title", "启动自动刷新")
        static let autoRefreshOnStartDetail = text("settings.auto_refresh_on_start_detail", "应用启动时自动刷新书架")
        // F109: 自定义 User-Agent（其它设置）
        static let userAgentTitle = text("settings.user_agent_title", "User-Agent")
        static let userAgentDetail = text("settings.user_agent_detail", "自定义网络请求 User-Agent")
        static let userAgentPlaceholder = text("settings.user_agent_placeholder", "留空使用默认值")
        // 阅读设置分组标题
        static let readingSettingsSectionTitle = text("settings.reading_settings_section_title", "阅读设置")
        // F102: 语言切换
        static let languageTitle = text("settings.language_title", "语言")
        static let languageDetail = text("settings.language_detail", "切换应用显示语言")
        static let languagePicker = text("settings.language_picker", "选择语言")
        static let languageFollowSystem = text("settings.language_follow_system", "跟随系统")
        static let languageSimplifiedChinese = text("settings.language_simplified_chinese", "简体中文")
        static let languageTraditionalChinese = text("settings.language_traditional_chinese", "繁體中文")
        static let languageEnglish = text("settings.language_english", "English")
        static let languageGoToSystemSettings = text(
            "settings.language_go_to_system_settings", "iOS 需要在系统设置中切换语言。点击确定将跳转到系统设置。")
        // F108: 应用密码（应用锁）
        static let appLockTitle = text("settings.app_lock_title", "应用密码")
        static let appLockDetail = text("settings.app_lock_detail", "设置应用启动密码")
        static let appLockEnabled = text("settings.app_lock_enabled", "已设置")
        static let appLockDisabled = text("settings.app_lock_disabled", "未设置")
        static let appLockSetTitle = text("settings.app_lock_set_title", "设置密码")
        static let appLockSetMessage = text("settings.app_lock_set_message", "设置后每次启动应用需要输入密码")
        static let appLockPasswordPlaceholder = text("settings.app_lock_password_placeholder", "输入密码")
        static let appLockConfirmPlaceholder = text("settings.app_lock_confirm_placeholder", "确认密码")
        static let appLockMismatch = text("settings.app_lock_mismatch", "两次输入的密码不一致")
        static let appLockEmpty = text("settings.app_lock_empty", "密码不能为空")
        static let appLockClearTitle = text("settings.app_lock_clear_title", "清除密码")
        static let appLockClearMessage = text("settings.app_lock_clear_message", "确认清除应用密码？")
        static let appLockClearAction = text("settings.app_lock_clear_action", "清除")
        static let appLockVerifyTitle = text("settings.app_lock_verify_title", "输入密码")
        static let appLockVerifyMessage = text("settings.app_lock_verify_message", "请输入应用密码以继续")
        static let appLockWrongPassword = text("settings.app_lock_wrong_password", "密码错误")
        static let appLockSetSuccess = text("settings.app_lock_set_success", "密码已设置")
        static let appLockClearSuccess = text("settings.app_lock_clear_success", "密码已清除")
        // F81: 自动换源
        static let autoChangeSourceTitle = text("settings.auto_change_source_title", "自动换源")
        static let autoChangeSourceDetail = text("settings.auto_change_source_detail", "加载失败时自动尝试其他书源")
        // F131: 压缩数据库
        static let vacuumDatabaseTitle = text("settings.vacuum_database_title", "压缩数据库")
        static let vacuumDatabaseDetail = text("settings.vacuum_database_detail", "压缩并优化数据库文件")
        static let vacuumDatabaseConfirmTitle = text("settings.vacuum_database_confirm_title", "压缩数据库")
        static let vacuumDatabaseConfirmMessage = text(
            "settings.vacuum_database_confirm_message", "执行 VACUUM 操作将压缩数据库文件，回收未使用的空间。操作期间请勿关闭应用。")
        static let vacuumDatabaseSuccess = text("settings.vacuum_database_success", "数据库压缩完成")
        static let vacuumDatabaseProcessing = text("settings.vacuum_database_processing", "正在压缩数据库…")
    }

    enum RSS {
        static let articleRefresh = text("rss.article_refresh", "刷新文章")
        static let articleSourceLogin = text("rss.article_source_login", "订阅源登录")
        static let articleExternalOpen = text("rss.article_external_open", "在外部应用中打开")
        static let favoriteRetentionFailed = text("rss.favorite_retention_failed", "收藏正文保留失败，请重试")
        static let articleSessionSaveFailed = text("rss.article_session_save_failed", "订阅网页会话保存失败，请刷新重试")
        static let articleProcessStopped = text("rss.article_process_stopped", "订阅网页已停止运行，请刷新重试")
        static let articleLinkBlocked = text("rss.article_link_blocked", "订阅源的内容规则已拦截此链接")
        static let imagePhotosDestination = text("rss.image_photos_destination", "保存到相册")
        static let imageFilesDestination = text("rss.image_files_destination", "保存到文件")
        static let imageShareDestination = text("rss.image_share_destination", "系统分享")
        static let imageLoading = text("rss.image_loading", "正在获取图片")
        static let imageSavingPhotos = text("rss.image_saving_photos", "正在保存到相册")
        static let imageProcessingFailed = text("rss.image_processing_failed", "图片处理失败")
        static let imageExported = text("rss.image_exported", "图片已导出到文件")
        static let title = text("rss.title", "RSS")
        static let loading = text("rss.loading", "正在加载 RSS 源…")
        static let unavailable = text("rss.unavailable", "RSS 暂时不可用")
        static let sourceFallback = text("rss.source_fallback", "RSS 源")
        static let sortFallback = text("rss.sort_fallback", "分类")
        static let favoritesTitle = text("rss.favorites_title", "收藏")
        static let nextPage = text("rss.next_page", "下一页")
        static let loadingNextPage = text("rss.loading_next_page", "正在加载下一页 RSS…")
        static let refreshArticles = text("rss.refresh_articles", "刷新列表")
        static let emptySourcesTitle = text("rss.empty_sources_title", "还没有可用 RSS 源")
        static let emptySourcesMessage = text("rss.empty_sources_message", "先导入并启用至少一个 RSS 源，再回来阅读。")
        static let emptySourcesPlaceholder = text("rss.empty_sources_placeholder", "暂无可用 RSS 源。")
        static let emptySortPlaceholder = text("rss.empty_sort_placeholder", "先选择 RSS 源和分类。")
        static let loadingSorts = text("rss.loading_sorts", "正在加载分类…")
        static let loadingArticles = text("rss.loading_articles", "正在加载文章…")
        static let loadingContent = text("rss.loading_content", "正在加载正文…")
        static let loadArticlesFailed = text("rss.load_articles_failed", "RSS 加载失败")
        static let savedArticles = text("rss.saved_articles", "已保存的文章")
        static let directoryRetentionFailed = text("rss.directory_retention_failed", "文章目录未能保存，请稍后刷新")
        static let readRecordFailed = text("rss.read_record_failed", "已读状态保存失败")
        static let readRecordsTitle = text("rss.read_records_title", "阅读记录")
        static let emptyReadRecords = text("rss.empty_read_records", "暂无阅读记录")
        static let clearArticles = text("rss.clear_articles", "清除文章")
        static let clearArticlesConfirmMessage = text(
            "rss.clear_articles_confirm_message", "确定清除当前订阅源的全部文章和正文缓存？收藏和阅读记录将保留。")
        static let articlesCleared = text("rss.articles_cleared", "文章已清除")
        static let contentFailed = text("rss.content_failed", "正文加载失败")
        static let emptyArticles = text("rss.empty_articles", "当前分类还没有文章。")
        static let favoriteAdded = text("rss.favorite_added", "已加入收藏")
        static let favoriteRemoved = text("rss.favorite_removed", "已取消收藏")
        static let openFavorites = text("rss.open_favorites", "查看收藏")
        static let favoritesEmpty = text("rss.favorites_empty", "还没有收藏文章。")
        static let sourceSection = text("rss.source_section", "来源：%@")
        static let articleReaderTitle = text("rss.article_reader_title", "文章")
        static let markFavorite = text("rss.mark_favorite", "收藏")
        static let unmarkFavorite = text("rss.unmark_favorite", "取消收藏")
        static let sourceUnavailable = text("rss.source_unavailable", "当前没有可切换的 RSS 订阅源。")
        static let sortUnavailable = text("rss.sort_unavailable", "当前没有可切换的 RSS 分类。")
        static let shareLink = text("rss.share_link", "分享链接")
        static let openInBrowser = text("rss.open_in_browser", "在浏览器中打开")
        // F12: 列表布局样式
        static let switchLayout = text("rss.switch_layout", "切换布局")
        static let articleLayoutCompact = text("rss.article_layout_compact", "紧凑列表")
        static let articleLayoutLargeImage = text("rss.article_layout_large_image", "大图列表")
        static let articleLayoutGrid = text("rss.article_layout_grid", "网格")
        static let layoutTitleOnly = text("rss.layout_title_only", "仅标题")
        static let layoutTitleDescription = text("rss.layout_title_description", "标题+描述")
        static let layoutTitleImageDescription = text("rss.layout_title_image_description", "标题+图片+描述")
        // F29: 清除缓存
        static let clearCache = text("rss.clear_cache", "清除缓存")
        static let clearCacheSuccess = text("rss.clear_cache_success", "文章缓存已清除")
        static let clearCacheConfirmTitle = text("rss.clear_cache_confirm_title", "清除文章缓存")
        static let clearCacheConfirmMessage = text("rss.clear_cache_confirm_message", "确定清除已缓存的 RSS 文章内容？")
        // F20: 清除阅读记录
        static let clearReadRecords = text("rss.clear_read_records", "清除阅读记录")
        static let clearReadRecordsConfirmTitle = text("rss.clear_read_records_confirm_title", "清除阅读记录")
        static let clearReadRecordsConfirmMessage = text(
            "rss.clear_read_records_confirm_message", "确定清除全部 RSS 阅读记录？清除后文章将重新显示为未读状态。")
        static let clearReadRecordsSuccess = text("rss.clear_read_records_success", "阅读记录已清除")
        // F21: 收藏编辑
        static let editFavoriteTitle = text("rss.edit_favorite_title", "编辑收藏")
        static let editFavoriteTitleField = text("rss.edit_favorite_title_field", "标题")
        static let editFavoriteGroupField = text("rss.edit_favorite_group_field", "分组")
        static let editFavoriteSuccess = text("rss.edit_favorite_success", "收藏已更新")
        // F22: 收藏分组显示
        static let allGroups = text("rss.all_groups", "全部")
        static let favoriteGroupFallback = text("rss.favorite_group_fallback", "分组")
        // F26: 源导入/导出
        static let importSources = text("rss.import_sources", "导入订阅源")
        static let exportSources = text("rss.export_sources", "导出订阅源")
        static let exportSourcesEmpty = text("rss.export_sources_empty", "当前没有可导出的 RSS 源。")
        static let importSourcesTitle = text("rss.import_sources_title", "导入 RSS 源")
        static let importSourcesPlaceholder = text("rss.import_sources_placeholder", "粘贴 RSS 源 JSON 数据")
        static let importSourcesSuccess = text("rss.import_sources_success", "已导入 %d 个 RSS 源")
        static let importSourcesFailed = text("rss.import_sources_failed", "导入失败")
        static let importSourcesInvalidJSON = text("rss.import_sources_invalid_json", "无法解析 JSON 数据，请检查格式是否正确。")
        // F27: 分组管理
        static let groupManageAction = text("rss.group_manage_action", "分组管理")
        static let groupManageTitle = text("rss.group_manage_title", "RSS 源分组")
        static let addGroupTitle = text("rss.add_group_title", "新增分组")
        static let renameGroupTitle = text("rss.rename_group_title", "重命名分组")
        static let deleteGroupTitle = text("rss.delete_group_title", "删除分组")
        static let deleteGroupConfirmMessage = text("rss.delete_group_confirm_message", "确定删除分组「%@」？该分组下的源将变为未分组状态。")
        static let groupNamePlaceholder = text("rss.group_name_placeholder", "输入分组名")
        static let selectGroupSourcesTitle = text("rss.select_group_sources_title", "选择 RSS 源")
        static let groupUpdated = text("rss.group_updated", "已更新 %d 个 RSS 源")
        static let groupNoSourcesSelected = text("rss.group_no_sources_selected", "请选择至少一个 RSS 源")
        // F16/F18: WebView 内容渲染 + 长按图片保存
        static let saveImage = text("rss.save_image", "保存图片")
        static let saveImageSuccess = text("rss.save_image_success", "图片已保存到相册")
        static let saveImageFailed = text("rss.save_image_failed", "图片保存失败")
        static let saveImagePermissionDenied = text("rss.save_image_permission_denied", "需要相册权限才能保存图片")
        // F30: 登录书源
        static let loginSource = text("rss.login_source", "登录书源")
        static let loginSourceUnavailable = text("rss.login_source_unavailable", "当前源不支持登录")
        static let loginSourceFailed = text("rss.login_source_failed", "登录失败")
        // F19: TTS 朗读
        static let readAloud = text("rss.read_aloud", "朗读")
        static let stopReadAloud = text("rss.stop_read_aloud", "停止朗读")
        // F23: RSS 源管理
        static let sourceManagementTitle = text("rss.source_management_title", "RSS 源管理")
        static let sourceManagementAction = text("rss.source_management_action", "源管理")
        static let sourceManagementLoading = text("rss.source_management_loading", "正在加载 RSS 源…")
        static let sourceManagementUnavailable = text("rss.source_management_unavailable", "RSS 源管理不可用")
        static let sourceManagementLoadFailed = text("rss.source_management_load_failed", "RSS 源加载失败")
        static let sourceManagementEmpty = text("rss.source_management_empty", "还没有 RSS 源，点右上角添加或导入。")
        static let sourceManagementNoMatch = text("rss.source_management_no_match", "没有匹配的 RSS 源。")
        static let sourceManagementSearchPlaceholder = text("rss.source_management_search_placeholder", "搜索 RSS 源")
        static let sourceManagementDeleteConfirm = text("rss.source_management_delete_confirm", "确定删除这条 RSS 源？")
        static let sourceManagementDeleteAction = text("rss.source_management_delete_action", "删除")
        static let sourceManagementEditAction = text("rss.source_management_edit_action", "编辑")
        static let sourceManagementEnableAction = text("rss.source_management_enable_action", "启用")
        static let sourceManagementDisableAction = text("rss.source_management_disable_action", "禁用")
        static let sourceManagementAddAction = text("rss.source_management_add_action", "添加 RSS 源")
        static let sourceManagementImportAction = text("rss.source_management_import_action", "导入")
        static let sourceManagementExportAction = text("rss.source_management_export_action", "导出")
        static let sourceManagementSelectAction = text("rss.source_management_select_action", "多选")
        static let sourceManagementFinishSelectAction = text("rss.source_management_finish_select_action", "完成多选")
        static let sourceManagementEnabledBadge = text("rss.source_management_enabled_badge", "已启用")
        static let sourceManagementDisabledBadge = text("rss.source_management_disabled_badge", "已禁用")
        static let sourceManagementGroupFilter = text("rss.source_management_group_filter", "分组")
        static let sourceManagementAllGroups = text("rss.source_management_all_groups", "全部分组")
        static let sourceManagementImportTitle = text("rss.source_management_import_title", "导入 RSS 源")
        static let sourceManagementImportPlaceholder = text(
            "rss.source_management_import_placeholder", "粘贴 RSS 源 JSON 数据")
        static func sourceManagementImportSuccess(_ count: Int32) -> String {
            format("rss.source_management_import_success", "已导入 %d 个 RSS 源", Int(count))
        }
        static let sourceManagementImportFailed = text("rss.source_management_import_failed", "导入失败")
        static let sourceManagementExportEmpty = text("rss.source_management_export_empty", "当前没有可导出的 RSS 源。")
        static func sourceManagementSelectionTitle(_ count: Int) -> String {
            format("rss.source_management_selection_title", "已选 %d 条", count)
        }
        // F24: RSS 源编辑
        static let sourceEditCreateTitle = text("rss.source_edit_create_title", "新建 RSS 源")
        static let sourceEditEditTitle = text("rss.source_edit_edit_title", "编辑 RSS 源")
        static let sourceEditSaveAction = text("rss.source_edit_save_action", "保存")
        static let sourceEditLoading = text("rss.source_edit_loading", "正在加载 RSS 源…")
        static let sourceEditLoadFailed = text("rss.source_edit_load_failed", "RSS 源加载失败")
        static let sourceEditSaving = text("rss.source_edit_saving", "正在保存 RSS 源…")
        static let sourceEditUnsavedTitle = text("rss.source_edit_unsaved_title", "放弃未保存修改？")
        static let sourceEditUnsavedMessage = text("rss.source_edit_unsaved_message", "当前修改尚未保存，返回会丢失本次编辑内容。")
        static let sourceEditDiscardAction = text("rss.source_edit_discard_action", "放弃修改")
        static let sourceEditBaseSection = text("rss.source_edit_base_section", "基础信息")
        static let sourceEditRuleSection = text("rss.source_edit_rule_section", "规则")
        static let sourceEditAdvancedSection = text("rss.source_edit_advanced_section", "高级")
        static let sourceEditNameTitle = text("rss.source_edit_name_title", "名称")
        static let sourceEditUrlTitle = text("rss.source_edit_url_title", "URL")
        static let sourceEditGroupTitle = text("rss.source_edit_group_title", "分组")
        static let sourceEditIconTitle = text("rss.source_edit_icon_title", "图标")
        static let sourceEditCommentTitle = text("rss.source_edit_comment_title", "备注")
        static let sourceEditEnabledTitle = text("rss.source_edit_enabled_title", "启用")
        static let sourceEditSortUrlTitle = text("rss.source_edit_sort_url_title", "排序 URL")
        static let sourceEditSingleUrlTitle = text("rss.source_edit_single_url_title", "单 URL")
        static let sourceEditArticleStyleTitle = text("rss.source_edit_article_style_title", "文章样式")
        static let sourceEditRuleArticlesTitle = text("rss.source_edit_rule_articles_title", "文章列表规则")
        static let sourceEditRuleNextPageTitle = text("rss.source_edit_rule_next_page_title", "下一页规则")
        static let sourceEditRuleTitleTitle = text("rss.source_edit_rule_title_title", "标题规则")
        static let sourceEditRulePubDateTitle = text("rss.source_edit_rule_pub_date_title", "发布日期规则")
        static let sourceEditRuleDescriptionTitle = text("rss.source_edit_rule_description_title", "描述规则")
        static let sourceEditRuleImageTitle = text("rss.source_edit_rule_image_title", "图片规则")
        static let sourceEditRuleLinkTitle = text("rss.source_edit_rule_link_title", "链接规则")
        static let sourceEditRuleContentTitle = text("rss.source_edit_rule_content_title", "正文规则")
        static let sourceEditHeaderTitle = text("rss.source_edit_header_title", "Header")
        static let sourceEditLoginUrlTitle = text("rss.source_edit_login_url_title", "Login URL")
        static let sourceEditConcurrentRateTitle = text("rss.source_edit_concurrent_rate_title", "并发")
        static let sourceEditStyleTitle = text("rss.source_edit_style_title", "注入 Style")
        static let sourceEditJsLibTitle = text("rss.source_edit_js_lib_title", "JS Lib")
        static let sourceEditEnableJsTitle = text("rss.source_edit_enable_js_title", "启用 JS")
        static let sourceEditLoadWithBaseUrlTitle = text("rss.source_edit_load_with_base_url_title", "加载 Base URL")
        static let sourceEditVariableCommentTitle = text("rss.source_edit_variable_comment_title", "变量说明")
        static let sourceEditContentWhitelistTitle = text("rss.source_edit_content_whitelist_title", "内容白名单")
        static let sourceEditContentBlacklistTitle = text("rss.source_edit_content_blacklist_title", "内容黑名单")
        // F25: RSS 源调试
        static let sourceDebugAction = text("rss.source_debug_action", "调试")
    }

    enum WebDav {
        static let notConfigured = text("webdav.not_configured", "WebDAV 未配置")
        static let connectionSuccess = text("webdav.connection_success", "WebDAV 连接成功")
        static let connectionFailed = text("webdav.connection_failed", "WebDAV 连接失败")
        static let uploadProgressSuccess = text("webdav.upload_progress_success", "已覆盖云端进度")
        static let uploadProgressFailed = text("webdav.upload_progress_failed", "上传进度失败")
        static let getProgressTitle = text("webdav.get_progress_title", "获取云端进度")
        static let getProgressEmpty = text("webdav.get_progress_empty", "没有找到云端进度")
        static let getProgressFailed = text("webdav.get_progress_failed", "获取云端进度失败")
        static let uploadBookSuccess = text("webdav.upload_book_success", "已上传到 WebDAV")
        static let uploadBookFailed = text("webdav.upload_book_failed", "上传到 WebDAV 失败")
        static let uploadBookTitle = text("webdav.upload_book_title", "上传到WebDav")
        static let getCloudProgress = text("webdav.get_cloud_progress", "获取云端进度")
        static let overrideCloudProgress = text("webdav.override_cloud_progress", "覆盖云端进度")
        static let cloudProgressAhead = text("webdav.cloud_progress_ahead", "云端进度更新")
        static let localProgressAhead = text("webdav.local_progress_ahead", "本地进度更新")
        static let applyCloudProgress = text("webdav.apply_cloud_progress", "应用云端进度")
        static let keepLocalProgress = text("webdav.keep_local_progress", "保留本地进度")
        static let autoSyncProgress = text("webdav.auto_sync_progress", "自动同步进度")
        static let syncingProgress = text("webdav.syncing_progress", "正在同步阅读进度…")

        static func cloudProgressDetail(chapter: String, index: Int) -> String {
            format("webdav.cloud_progress_detail", "云端：第 %d 章 %@", index, chapter)
        }

        static func localProgressDetail(chapter: String, index: Int) -> String {
            format("webdav.local_progress_detail", "本地：第 %d 章 %@", index, chapter)
        }
    }

    enum AudioPlay {
        static let unavailable = text("audio_play.unavailable", "音频播放暂时不可用")
        static let timerTitle = text("audio_play.timer_title", "定时关闭")
        static let timerOff = text("audio_play.timer_off", "关闭定时")
        static func timerMinutes(_ minutes: Int) -> String {
            format("audio_play.timer_minutes", "%d 分钟", minutes)
        }
        static let chapterList = text("audio_play.chapter_list", "章节列表")
    }

    enum PDFNavigation {
        static let contents = text("pdf.navigation.contents", "目录")
        static let outline = text("pdf.navigation.outline", "大纲")
        static let pages = text("pdf.navigation.pages", "页面")
        static let currentPage = text("pdf.navigation.current_page", "当前页")
        static func page(_ number: Int) -> String {
            format("pdf.navigation.page", "第 %d 页", number)
        }
    }

    enum PDFReader {
        static func locationSaveFailed(_ message: String) -> String {
            format("pdf.reader.location_save_failed", "阅读位置保存失败：%@", message)
        }
        static let searchContent = text("pdf.reader.search_content", "搜索正文")
        static let previousPage = text("pdf.reader.previous_page", "上一页")
        static let nextPage = text("pdf.reader.next_page", "下一页")
        static let pageNumber = text("pdf.reader.page_number", "PDF 页码")
        static let unreadableDocument = text("pdf.reader.unreadable_document", "PDF 已加密、损坏或没有可阅读的页面")
        static func progressSaveFailed(_ message: String) -> String {
            format("pdf.reader.progress_save_failed", "阅读进度保存失败：%@", message)
        }
        static let continuousScrolling = text("pdf.reader.continuous_scrolling", "连续滚动")
        static let pagedReading = text("pdf.reader.paged_reading", "逐页阅读")
        static let fitPage = text("pdf.reader.fit_page", "适合页面")
        static let jumpToPage = text("pdf.reader.jump_to_page", "跳转页码")
        static let addBookmark = text("pdf.reader.add_bookmark", "添加书签")
        static let returnBeforeJump = text("pdf.reader.return_before_jump", "返回跳转前位置")
        static let clearSearchHighlight = text("pdf.reader.clear_search_highlight", "清除搜索高亮")
        static let jump = text("pdf.reader.jump", "跳转")
        static let invalidLocation = text("pdf.reader.invalid_location", "PDF 页码、坐标或缩放比例无效")
        static let locationSaveUnavailable = text("pdf.reader.location_save_unavailable", "无法保存 PDF 阅读位置")
        static let locationRecordTooLarge = text("pdf.reader.location_record_too_large", "PDF 阅读位置记录超过大小限制")
        static let locationRequiresLocalFile = text("pdf.reader.location_requires_local_file", "PDF 阅读位置需要本地文件")
        static let fileMetadataReadFailed = text("pdf.reader.file_metadata_read_failed", "无法读取 PDF 文件信息")
        static let fileMetadataInvalid = text("pdf.reader.file_metadata_invalid", "PDF 文件信息缺失或无效")
    }

    enum PDFContent {
        static let searchTitle = text("pdf.content.search_title", "正文查找")

        static let searchClose = text("pdf.content.search_close", "关闭查找")

        static let searchPlaceholder = text("pdf.content.search_placeholder", "搜索正文")

        static let searchStop = text("pdf.content.search_stop", "停止查找")

        static func searchInProgress(_ count: Int) -> String {
            format(
                "pdf.content.search_in_progress", "正在查找 · %d 个结果", count)
        }

        static func searchResultCount(_ count: Int) -> String {
            format(
                "pdf.content.search_result_count", "%d 个结果", count)
        }

        static let searchNoMatches = text("pdf.content.search_no_matches", "未找到匹配内容")

        static func searchStoppedResultCount(_ count: Int) -> String {
            format(
                "pdf.content.search_stopped_result_count", "查找已停止 · %d 个结果", count)
        }

        static let searchStopped = text("pdf.content.search_stopped", "查找已停止")

        static func searchLimitReached(_ count: Int) -> String {
            format(
                "pdf.content.search_limit_reached", "达到上限，显示前%d项", count)
        }

        static let searchFailed = text("pdf.content.search_failed", "查找失败")

        static func searchFailureRetainingResults(_ message: String, _ count: Int) -> String {
            format(
                "pdf.content.search_failure_retaining_results", "%1$@（保留 %2$d 个结果）", message, count)
        }

        static func searchQueryTooLong(_ limit: Int) -> String {
            format(
                "pdf.content.search_query_too_long", "搜索词过长（最多 %d 个 UTF-16 单元）", limit)
        }

        static let searchRequiresLocalFile = text("pdf.content.search_requires_local_file", "PDF 查找需要本地文件")

        static let searchDocumentUnavailable = text("pdf.content.search_document_unavailable", "PDF 无法打开，文件可能已移除或损坏")

        static let searchDocumentLocked = text("pdf.content.search_document_locked", "PDF 已锁定，无法查找正文")

        static let searchNoPages = text("pdf.content.search_no_pages", "PDF 没有可查找的页面")

        static let searchMatchUnavailable = text("pdf.content.search_match_unavailable", "PDF 匹配内容无法定位")

        static func pageNumber(_ number: Int) -> String {
            format(
                "pdf.content.page_number", "第 %d 页", number)
        }

        static func pageRange(_ first: Int, _ last: Int) -> String {
            format(
                "pdf.content.page_range", "第 %1$d–%2$d 页", first, last)
        }

        static let bookmarkSortPage = text("pdf.content.bookmark_sort_page", "按页码")

        static let bookmarkSortTime = text("pdf.content.bookmark_sort_time", "按时间")

        static let bookmarkAdd = text("pdf.content.bookmark_add", "添加书签")

        static let bookmarkClose = text("pdf.content.bookmark_close", "关闭书签")

        static let bookmarkSearchPlaceholder = text("pdf.content.bookmark_search_placeholder", "搜索摘录、备注或章名")

        static let bookmarkLoading = text("pdf.content.bookmark_loading", "正在加载书签")

        static func bookmarkCount(_ count: Int) -> String {
            format(
                "pdf.content.bookmark_count", "%d 个书签", count)
        }

        static let bookmarkNoMatches = text("pdf.content.bookmark_no_matches", "未找到匹配书签")

        static let bookmarkOperationFailed = text("pdf.content.bookmark_operation_failed", "操作失败，请重试")

        static let bookmarkExcerptField = text("pdf.content.bookmark_excerpt_field", "摘录")

        static let bookmarkPageTitleField = text("pdf.content.bookmark_page_title_field", "页面标题")

        static let bookmarkNoteField = text("pdf.content.bookmark_note_field", "备注")

        static let bookmarkTimeExists = text("pdf.content.bookmark_time_exists", "书签时间标识已存在，请重新添加")

        static let bookmarkDraftExpired = text("pdf.content.bookmark_draft_expired", "书签草稿已失效或定位已变化，请重新添加")

        static let bookmarkPageTitleChanged = text("pdf.content.bookmark_page_title_changed", "PDF 页面标题已变化，请重新添加书签")

        static let bookmarkTimeOccupied = text("pdf.content.bookmark_time_occupied", "书签时间标识已被占用，未覆盖现有书签，请重新加载")

        static let bookmarkSaveUnconfirmed = text("pdf.content.bookmark_save_unconfirmed", "书签保存未确认，请重新加载书签后再操作")

        static let bookmarkDeleteUnconfirmed = text("pdf.content.bookmark_delete_unconfirmed", "书签删除未确认，请重新加载书签后再操作")

        static let bookmarkServiceUnavailable = text("pdf.content.bookmark_service_unavailable", "书签服务暂不可用，请稍后重试")

        static let bookmarkBookInvalid = text("pdf.content.bookmark_book_invalid", "PDF 书籍地址或页面数量无效")

        static let bookmarkBookReadFailed = text("pdf.content.bookmark_book_read_failed", "无法读取当前 PDF 书籍，请稍后重试")

        static let bookmarkBookRemoved = text("pdf.content.bookmark_book_removed", "书籍已移除，请返回书架重新打开")

        static let bookmarkBookUnavailable = text("pdf.content.bookmark_book_unavailable", "当前书籍不是可用的本地 PDF")

        static let bookmarkPageCountChanged = text("pdf.content.bookmark_page_count_changed", "PDF 页面数量已变化，请重新打开书籍")

        static let bookmarkTocReversed = text("pdf.content.bookmark_toc_reversed", "PDF 目录已反转，不能按物理页定位，请恢复目录后重新打开书籍")

        static let bookmarkBookIdentityChanged = text(
            "pdf.content.bookmark_book_identity_changed", "PDF 书籍归属或书签分组已变化，请重新打开书籍")

        static let bookmarkGroupReadFailed = text("pdf.content.bookmark_group_read_failed", "无法核实书签分组，请稍后重试")

        static let bookmarkDuplicateOwners = text(
            "pdf.content.bookmark_duplicate_owners", "存在多本同名同作者书籍（含预览），无法确认书签归属，请先处理重复书籍")

        static let bookmarkTocCountMismatch = text("pdf.content.bookmark_toc_count_mismatch", "PDF 目录与页面数量不一致，请重新打开书籍")

        static let bookmarkTocIdentityChanged = text(
            "pdf.content.bookmark_toc_identity_changed", "PDF 目录页身份已变化，请重新打开书籍")

        static let bookmarkTocReadTimeout = text("pdf.content.bookmark_toc_read_timeout", "读取 PDF 目录超时，请稍后重试")

        static let bookmarkTocReadFailed = text("pdf.content.bookmark_toc_read_failed", "无法读取 PDF 目录，请稍后重试")

        static let bookmarkReadFailed = text("pdf.content.bookmark_read_failed", "无法读取最新书签，请稍后重试")

        static let bookmarkRemovedOrInvalid = text("pdf.content.bookmark_removed_or_invalid", "书签已被删除或标识无效，请重新加载书签")

        static let bookmarkIdentityChanged = text("pdf.content.bookmark_identity_changed", "书签归属或定位已变化，请重新加载书签")

        static let bookmarkTextChanged = text("pdf.content.bookmark_text_changed", "书签摘录或备注已被修改，请重新加载后再操作")

        static let bookmarkPositionInvalid = text("pdf.content.bookmark_position_invalid", "书签不是有效的 PDF 页面起始位置")

        static let bookmarkOwnerMismatch = text("pdf.content.bookmark_owner_mismatch", "书签不属于当前 PDF 的书名、作者分组")

        static let bookmarkPageOutOfRange = text("pdf.content.bookmark_page_out_of_range", "PDF 书签页码超出可读范围")

        static func bookmarkTextTooLong(_ field: String, _ limit: Int) -> String {
            format(
                "pdf.content.bookmark_text_too_long", "%1$@过长，最多允许 %2$d 个 UTF-16 字符", field, limit)
        }

        static let bookmarkOperationBusy = text("pdf.content.bookmark_operation_busy", "书签操作尚未结束，请稍后重试")

        static let bookmarkTimeInvalid = text("pdf.content.bookmark_time_invalid", "无法生成有效的书签时间标识，请稍后重试")

        static let bookmarkPageUnavailable = text("pdf.content.bookmark_page_unavailable", "PDF 页面已不可用")

        static func bookmarkUnavailablePage(_ number: Int64) -> String {
            format(
                "pdf.content.bookmark_unavailable_page", "页码不可用（%lld）", number)
        }

        static let bookmarkLocationUnavailable = text("pdf.content.bookmark_location_unavailable", "定位不可用")

        static let bookmarkCurrentPage = text("pdf.content.bookmark_current_page", "当前页")

        static let bookmarkInvalidLocationHint = text(
            "pdf.content.bookmark_invalid_location_hint", "此书签页码或定位与当前 PDF 不一致，仍可编辑或删除")
    }

    static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback), locale: Locale.current, arguments: arguments)
    }
}
