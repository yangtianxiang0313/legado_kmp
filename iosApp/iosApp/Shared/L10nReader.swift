import Foundation

extension L10n {
    enum ReaderAppearance {
        static let title = text("reader_appearance.title", "阅读样式")
        static let quickActionsTitle = text("reader_appearance.quick_actions_title", "快捷项")
        static let quickActionsDetail = text("reader_appearance.quick_actions_detail", "对齐 legado 的主快捷项，直接打开阅读内次级半弹层。")
        static let layoutSectionTitle = text("reader_appearance.layout_section_title", "排版")
        static let layoutSectionDetail = text("reader_appearance.layout_section_detail", "字距、行距、段距即时生效。")
        static let pageSectionTitle = text("reader_appearance.page_section_title", "翻页与共享排版")
        static let pageSectionDetail = text("reader_appearance.page_section_detail", "翻页动画和共享排版与阅读页同步。")
        static let behaviorSectionDetail = text(
            "reader_appearance.behavior_section_detail", "阅读内方向、亮度栏布局和点击区域直接回写到当前 iOS Reader 配置。")
        static let presetHint = text("reader_appearance.preset_hint", "点按切换样式，长按可重命名、删除或细调配色。")
        static let fontWeightQuickTitle = text("reader_appearance.font_weight_quick_title", "字重")
        static let fontQuickTitle = text("reader_appearance.font_quick_title", "字体")
        static let indentQuickTitle = text("reader_appearance.indent_quick_title", "首行缩进")
        static let chineseQuickTitle = text("reader_appearance.chinese_quick_title", "简繁")
        static let paddingQuickTitle = text("reader_appearance.padding_quick_title", "边距")
        static let tipQuickTitle = text("reader_appearance.tip_quick_title", "提示信息")
        static let themePageTitle = text("reader_appearance.theme_page_title", "背景与翻页")
        static let layoutPageTitle = text("reader_appearance.layout_page_title", "排版与文字")
        static let brightnessPageTitle = text("reader_appearance.brightness_page_title", "亮度与自动翻页")
        static let tapZonePageTitle = text("reader_appearance.tap_zone_page_title", "点击区域设置")
        static let loading = text("reader_appearance.loading", "正在加载阅读样式…")
        static let unavailable = text("reader_appearance.unavailable", "阅读样式不可用")
        static let presetSectionTitle = text("reader_appearance.preset_section_title", "阅读预设")
        static let presetSectionDetail = text("reader_appearance.preset_section_detail", "快速切换一组默认排版")
        static let presetFallbackName = text("reader_appearance.preset_fallback_name", "文字")
        static let fontSizeTitle = text("reader_appearance.font_size_title", "字体大小")
        static let fontSizeDetail = text("reader_appearance.font_size_detail", "调整正文显示大小")
        static let letterSpacingTitle = text("reader_appearance.letter_spacing_title", "字间距")
        static let lineSpacingTitle = text("reader_appearance.line_spacing_title", "行间距")
        static let lineSpacingDetail = text("reader_appearance.line_spacing_detail", "控制段落纵向疏密")
        static let paragraphSpacingTitle = text("reader_appearance.paragraph_spacing_title", "段间距")
        static let paddingTitle = text("reader_appearance.padding_title", "左右边距")
        static let verticalPaddingTitle = text("reader_appearance.vertical_padding_title", "上下边距")
        static let paddingDetail = text("reader_appearance.padding_detail", "控制阅读区域宽度")
        static let backgroundTitle = text("reader_appearance.background_title", "背景模式")
        static let backgroundDetail = text("reader_appearance.background_detail", "切换阅读底色与文字颜色")
        static let backgroundPicker = text("reader_appearance.background_picker", "背景模式")
        static let pageAnimationTitle = text("reader_appearance.page_animation_title", "翻页动画")
        static let pageAnimationDetail = text("reader_appearance.page_animation_detail", "对齐 legacy 的主链路翻页模式")
        static let brightnessTitle = text("reader_appearance.brightness_title", "亮度")
        static let brightnessDayTitle = text("reader_appearance.brightness_day_title", "白天亮度")
        static let brightnessDayDetail = text("reader_appearance.brightness_day_detail", "控制日间阅读亮度")
        static let brightnessNightTitle = text("reader_appearance.brightness_night_title", "夜间亮度")
        static let brightnessNightDetail = text("reader_appearance.brightness_night_detail", "控制夜间阅读亮度")
        static let autoReadSpeedTitle = text("reader_appearance.auto_read_speed_title", "自动翻页速度")
        static let autoReadSpeedDetail = text("reader_appearance.auto_read_speed_detail", "按 legacy 秒数配置自动翻页")
        static let layoutBehaviorTitle = text("reader_appearance.layout_behavior_title", "排版与界面")
        static let layoutBehaviorDetail = text("reader_appearance.layout_behavior_detail", "共享排版、对齐策略和系统栏显示")
        static let tapZoneTitle = text("reader_appearance.tap_zone_title", "点击区域设置")
        static let tapZoneDetail = text("reader_appearance.tap_zone_detail", "为九宫格点击区域指定动作")
        static let tapZoneChangeHint = text("reader_appearance.tap_zone_change_hint", "轻点更改动作")
        static let tapZoneMenuRequired = text("reader_appearance.tap_zone_menu_required", "当前没有配置菜单区域,自动恢复中间区域为菜单.")
        static let tapZoneClose = text("reader_appearance.tap_zone_close", "关闭")
        static let optionSelected = text("reader_appearance.option_selected", "已选中")
        static let optionNotSelected = text("reader_appearance.option_not_selected", "未选中")
        static let optionDestructive = text("reader_appearance.option_destructive", "危险操作")
        static let shareLayout = text("reader_appearance.share_layout", "共享排版")
        static let shareLayoutDetail = text("reader_appearance.share_layout_detail", "让所有书籍使用同一套阅读排版")
        static let bgTextSheetTitle = text("reader_appearance.bg_text_sheet_title", "背景与文字")
        static let bgTextSectionTitle = text("reader_appearance.bg_text_section_title", "当前样式细配")
        static let bgTextSectionDetail = text("reader_appearance.bg_text_section_detail", "背景、文字、透明度和状态栏图标即时预览。")
        static let bgTextEffectSection = text("reader_appearance.bg_text_effect_section", "文字与效果")
        static let paddingSheetTitle = text("reader_appearance.padding_sheet_title", "边距")
        static let paddingSheetDetail = text("reader_appearance.padding_sheet_detail", "正文、页眉、页脚边距直接重排当前页。")
        static let tipSheetTitle = text("reader_appearance.tip_sheet_title", "提示信息")
        static let tipSheetDetail = text("reader_appearance.tip_sheet_detail", "页眉、页脚和章节标题设置即时更新。")
        static let tipHeaderSection = text("reader_appearance.tip_header_section", "页眉区")
        static let tipFooterSection = text("reader_appearance.tip_footer_section", "页脚区")
        static let tipColorSection = text("reader_appearance.tip_color_section", "颜色")
        static let tipModeAuto = text("reader_appearance.tip_mode_auto", "自动")
        static let tipModeShow = text("reader_appearance.tip_mode_show", "显示")
        static let tipModeHidden = text("reader_appearance.tip_mode_hidden", "隐藏")
        static let tipSlotLeft = text("reader_appearance.tip_slot_left", "左侧")
        static let tipSlotCenter = text("reader_appearance.tip_slot_center", "中间")
        static let tipSlotRight = text("reader_appearance.tip_slot_right", "右侧")
        static let tipColorDefault = text("reader_appearance.tip_color_default", "跟随正文")
        static let tipDividerColorDefault = text("reader_appearance.tip_divider_color_default", "默认")
        static let tipDividerColorFollowText = text("reader_appearance.tip_divider_color_follow_text", "跟随正文")
        static let advancedSheetTitle = text("reader_appearance.advanced_sheet_title", "正文标题")
        static let advancedTextSection = text("reader_appearance.advanced_text_section", "正文标题")
        static let backgroundAlphaTitle = text("reader_appearance.background_alpha_title", "背景透明度")
        static let backgroundImageTitle = text("reader_appearance.background_image_title", "背景图")
        static let backgroundImageUnset = text("reader_appearance.background_image_unset", "未设置背景图")
        static let backgroundImageImport = text("reader_appearance.background_image_import", "导入背景图")
        static let backgroundImageChange = text("reader_appearance.background_image_change", "更换背景图")
        static let backgroundImageClear = text("reader_appearance.background_image_clear", "清除背景图")
        static let backgroundImageImportFailed = text("reader_appearance.background_image_import_failed", "背景图导入失败")
        static let darkStatusIcon = text("reader_appearance.dark_status_icon", "状态栏深色图标")
        static let underlineTitle = text("reader_appearance.underline_title", "下划线")
        static let textColorTitle = text("reader_appearance.text_color_title", "文字颜色")
        static let backgroundColorTitle = text("reader_appearance.background_color_title", "背景颜色")
        static let fontWeightPicker = text("reader_appearance.font_weight_picker", "字重")
        static let fontPicker = text("reader_appearance.font_picker", "字体")
        static let fontSelectTitle = text("reader_appearance.font_select_title", "选择字体")
        static let fontDefault = text("reader_appearance.font_default", "默认字体")
        static let fontImport = text("reader_appearance.font_import", "导入字体")
        static let fontSystemPicker = text("reader_appearance.font_system_picker", "系统内置字体样式")
        static let fontSystemDefault = text("reader_appearance.font_system_default", "系统默认字体")
        static let fontSystemSerif = text("reader_appearance.font_system_serif", "系统衬线字体")
        static let fontSystemMonospaced = text("reader_appearance.font_system_monospaced", "系统等宽字体")
        static let fontEmpty = text("reader_appearance.font_empty", "暂无字体")
        static let fontImportFailed = text("reader_appearance.font_import_failed", "字体导入失败")
        static let fontLoadFailed = text("reader_appearance.font_load_failed", "字体加载失败")
        static let indentPicker = text("reader_appearance.indent_picker", "首行缩进")
        static let chinesePicker = text("reader_appearance.chinese_picker", "简繁转换")
        static let fontWeightNormal = text("reader_appearance.font_weight_normal", "常规")
        static let fontWeightBold = text("reader_appearance.font_weight_bold", "加粗")
        static let fontWeightLight = text("reader_appearance.font_weight_light", "细体")
        static let fontSystem = text("reader_appearance.font_system", "系统")
        static let fontSerif = text("reader_appearance.font_serif", "衬线")
        static let fontMonospaced = text("reader_appearance.font_monospaced", "等宽")
        static let chineseNone = text("reader_appearance.chinese_none", "不转换")
        static let chineseSimplified = text("reader_appearance.chinese_simplified", "转简体")
        static let chineseTraditional = text("reader_appearance.chinese_traditional", "转繁体")
        static let titleModeTitle = text("reader_appearance.title_mode_title", "标题模式")
        static let titleModePicker = text("reader_appearance.title_mode_picker", "标题模式")
        static let titleModeDefault = text("reader_appearance.title_mode_default", "默认")
        static let titleModeCenter = text("reader_appearance.title_mode_center", "居中")
        static let titleModeHidden = text("reader_appearance.title_mode_hidden", "隐藏")
        static let titleSizeTitle = text("reader_appearance.title_size_title", "标题字号附加值")
        static let titleTopSpacingTitle = text("reader_appearance.title_top_spacing_title", "标题上间距")
        static let titleBottomSpacingTitle = text("reader_appearance.title_bottom_spacing_title", "标题下间距")
        static let headerModeTitle = text("reader_appearance.header_mode_title", "页眉显示")
        static let headerModePicker = text("reader_appearance.header_mode_picker", "页眉显示")
        static let headerModeAuto = text("reader_appearance.header_mode_auto", "状态栏显示时隐藏")
        static let headerModeShow = text("reader_appearance.header_mode_show", "始终显示")
        static let headerModeHidden = text("reader_appearance.header_mode_hidden", "始终隐藏")
        static let footerModeTitle = text("reader_appearance.footer_mode_title", "页脚显示")
        static let footerModePicker = text("reader_appearance.footer_mode_picker", "页脚显示")
        static let footerModeShow = text("reader_appearance.footer_mode_show", "显示")
        static let footerModeHidden = text("reader_appearance.footer_mode_hidden", "隐藏")
        static let tipSummaryVisible = text("reader_appearance.tip_summary_visible", "显")
        static let tipSummaryHidden = text("reader_appearance.tip_summary_hidden", "藏")
        static let tipHeaderLeft = text("reader_appearance.tip_header_left", "页眉左")
        static let tipHeaderCenter = text("reader_appearance.tip_header_center", "页眉中")
        static let tipHeaderRight = text("reader_appearance.tip_header_right", "页眉右")
        static let tipFooterLeft = text("reader_appearance.tip_footer_left", "页脚左")
        static let tipFooterCenter = text("reader_appearance.tip_footer_center", "页脚中")
        static let tipFooterRight = text("reader_appearance.tip_footer_right", "页脚右")
        static let tipColorTitle = text("reader_appearance.tip_color_title", "提示文字颜色")
        static let tipDividerColorTitle = text("reader_appearance.tip_divider_color_title", "提示分隔线颜色")
        static let customColorButton = text("reader_appearance.custom_color_button", "自定义")
        static let customColorPickerTitle = text("reader_appearance.custom_color_picker_title", "选择颜色")
        static let resetPresetTitle = text("reader_appearance.reset_preset_title", "恢复默认")
        static let resetPresetSection = text("reader_appearance.reset_preset_section", "当前配色")
        static let resetPresetActionSubtitle = text("reader_appearance.reset_preset_action_subtitle", "重置当前配色和样式")
        static let resetPresetMessage = text("reader_appearance.reset_preset_message", "确定将当前配色恢复为预设默认值？")
        static let resetPresetDone = text("reader_appearance.reset_preset_done", "已恢复默认")
        static let renamePresetTitle = text("reader_appearance.rename_preset_title", "重命名配色方案")
        static let renamePresetPlaceholder = text("reader_appearance.rename_preset_placeholder", "请输入新名称")
        static let deletePresetTitle = text("reader_appearance.delete_preset_title", "删除配色方案")
        static func deletePresetMessage(_ name: String) -> String {
            format("reader_appearance.delete_preset_message", "确定删除配色方案「%@」？删除后无法恢复。", name)
        }
        static let deletePresetNotAllowed = text("reader_appearance.delete_preset_not_allowed", "预设配色方案不可删除")
        static let exportPresetTitle = text("reader_appearance.export_preset_title", "导出配色方案")
        static let importPresetTitle = text("reader_appearance.import_preset_title", "导入配色方案")
        static let importPresetFromClipboard = text("reader_appearance.import_preset_from_clipboard", "从剪贴板导入")
        static let importPresetFromFile = text("reader_appearance.import_preset_from_file", "从文件导入")
        static let importPresetSuccess = text("reader_appearance.import_preset_success", "配色方案导入成功")
        static let importPresetInvalidJson = text("reader_appearance.import_preset_invalid_json", "无效的配色方案数据")
        static let importPresetClipboardEmpty = text("reader_appearance.import_preset_clipboard_empty", "剪贴板为空或不包含文本")
        static let tipSlotNone = text("reader_appearance.tip_slot_none", "不显示")
        static let tipSlotChapterTitle = text("reader_appearance.tip_slot_chapter_title", "章节名")
        static let tipSlotTime = text("reader_appearance.tip_slot_time", "时间")
        static let tipSlotBattery = text("reader_appearance.tip_slot_battery", "电量")
        static let tipSlotPage = text("reader_appearance.tip_slot_page", "页码")
        static let tipSlotTotalProgress = text("reader_appearance.tip_slot_total_progress", "总进度")
        static let tipSlotPageAndTotal = text("reader_appearance.tip_slot_page_and_total", "页码/总进度")
        static let tipSlotBookName = text("reader_appearance.tip_slot_book_name", "书名")
        static let tipSlotTimeBattery = text("reader_appearance.tip_slot_time_battery", "时间/电量")
        static let tipSlotTimeBatteryPercentage = text("reader_appearance.tip_slot_time_battery_percentage", "时间/电量百分比")
        static let tipSlotBatteryPercentage = text("reader_appearance.tip_slot_battery_percentage", "电量百分比")
        static let tipSlotTotalProgressAlt = text("reader_appearance.tip_slot_total_progress_alt", "总进度(样式2)")
        static let paddingBodySection = text("reader_appearance.padding_body_section", "正文边距")
        static let paddingHeaderSection = text("reader_appearance.padding_header_section", "页眉边距")
        static let paddingFooterSection = text("reader_appearance.padding_footer_section", "页脚边距")
        static let paddingTop = text("reader_appearance.padding_top", "上")
        static let paddingLeft = text("reader_appearance.padding_left", "左")
        static let paddingBottom = text("reader_appearance.padding_bottom", "下")
        static let paddingRight = text("reader_appearance.padding_right", "右")
        static let showHeaderLine = text("reader_appearance.show_header_line", "显示页眉分隔线")
        static let showFooterLine = text("reader_appearance.show_footer_line", "显示页脚分隔线")
        static let textFullJustify = text("reader_appearance.text_full_justify", "两端对齐")
        static let textBottomJustify = text("reader_appearance.text_bottom_justify", "底部对齐")
        static let hideStatusBar = text("reader_appearance.hide_status_bar", "隐藏状态栏")
        static let hideNavigationBar = text("reader_appearance.hide_navigation_bar", "隐藏导航栏")
        static let backgroundPaper = text("reader_appearance.background_paper", "纸张")
        static let backgroundSepia = text("reader_appearance.background_sepia", "护眼")
        static let backgroundDark = text("reader_appearance.background_dark", "夜间")
        static let presetPicker = text("reader_appearance.preset_picker", "阅读预设")
        static let pageAnimationPicker = text("reader_appearance.page_animation_picker", "翻页动画")
        static let pageAnimationDefault = text("reader_appearance.page_animation_default", "默认")
        static let tapZonePicker = text("reader_appearance.tap_zone_picker", "选择操作")
        static let pageAnimationCover = text("reader_appearance.page_animation_cover", "覆盖")
        static let pageAnimationSlide = text("reader_appearance.page_animation_slide", "滑动")
        static let pageAnimationSimulation = text("reader_appearance.page_animation_simulation", "仿真")
        static let pageAnimationScroll = text("reader_appearance.page_animation_scroll", "滚动")
        static let pageAnimationNone = text("reader_appearance.page_animation_none", "无动画")
        static let tapActionDisabled = text("reader_appearance.tap_action_disabled", "无操作")
        static let tapActionMenu = text("reader_appearance.tap_action_menu", "菜单")
        static let tapActionNextPage = text("reader_appearance.tap_action_next_page", "下一页")
        static let tapActionPreviousPage = text("reader_appearance.tap_action_previous_page", "上一页")
        static let tapActionNextChapter = text("reader_appearance.tap_action_next_chapter", "下一章")
        static let tapActionPreviousChapter = text("reader_appearance.tap_action_previous_chapter", "上一章")
        static let tapActionPreviousParagraph = text("reader_appearance.tap_action_previous_paragraph", "朗读上一段")
        static let tapActionNextParagraph = text("reader_appearance.tap_action_next_paragraph", "朗读下一段")
        static let tapActionAddBookmark = text("reader_appearance.tap_action_add_bookmark", "添加书签")
        static let tapActionEditContent = text("reader_appearance.tap_action_edit_content", "编辑内容")
        static let tapActionReplaceRule = text("reader_appearance.tap_action_replace_rule", "替换(启用/禁用)")
        static let tapActionChapterList = text("reader_appearance.tap_action_chapter_list", "目录")
        static let tapActionSearchContent = text("reader_appearance.tap_action_search_content", "全文搜索")
        static let tapActionSyncProgress = text("reader_appearance.tap_action_sync_progress", "同步阅读进度")
        static let tapActionReadAloud = text("reader_appearance.tap_action_read_aloud", "朗读暂停/继续")
        static let tapZoneTopLeft = text("reader_appearance.tap_zone_top_left", "左上")
        static let tapZoneTopCenter = text("reader_appearance.tap_zone_top_center", "上中")
        static let tapZoneTopRight = text("reader_appearance.tap_zone_top_right", "右上")
        static let tapZoneMiddleLeft = text("reader_appearance.tap_zone_middle_left", "左中")
        static let tapZoneMiddleCenter = text("reader_appearance.tap_zone_middle_center", "中间")
        static let tapZoneMiddleRight = text("reader_appearance.tap_zone_middle_right", "右中")
        static let tapZoneBottomLeft = text("reader_appearance.tap_zone_bottom_left", "左下")
        static let tapZoneBottomCenter = text("reader_appearance.tap_zone_bottom_center", "下中")
        static let tapZoneBottomRight = text("reader_appearance.tap_zone_bottom_right", "右下")

        static func unknownTapAction(_ rawAction: String) -> String {
            format("reader_appearance.unknown_tap_action", "未知动作 %@", rawAction)
        }

        static func fontSizeValue(_ value: Float) -> String {
            format("reader_appearance.font_size_value", "%.0fsp", value)
        }

        static func quickTitle(title: String, value: String) -> String {
            "\(title)\n\(value)"
        }

        static func letterSpacingValue(_ value: Float) -> String {
            format("reader_appearance.letter_spacing_value", "%.2f", value)
        }

        static func lineSpacingValue(_ value: Float) -> String {
            format("reader_appearance.line_spacing_value", "%.2f", value)
        }

        static func paragraphSpacingValue(_ value: Int32) -> String {
            format("reader_appearance.paragraph_spacing_value", "%dpt", value)
        }

        static func paddingValue(_ value: Float) -> String {
            format("reader_appearance.padding_value", "%.0fpt", value)
        }

        static func indentValue(_ value: Int32) -> String {
            format("reader_appearance.indent_value", "%d字", value)
        }

        static func pointValue(_ value: Int32) -> String {
            format("reader_appearance.point_value", "%dpt", value)
        }

        static func floatPointValue(_ value: Float) -> String {
            format("reader_appearance.float_point_value", "%.0fpt", value)
        }

        static func backgroundAlphaValue(_ value: Int32) -> String {
            format("reader_appearance.background_alpha_value", "%d%%", value)
        }

        static func brightnessValue(_ value: Int) -> String {
            format("reader_appearance.brightness_value", "%d%%", value)
        }

        static func autoReadSpeedValue(_ value: Int) -> String {
            format("reader_appearance.auto_read_speed_value", "%d 秒", value)
        }
    }

    enum Reader {
        static let title = text("reader.title", "阅读")
        static let chapterLoading = text("reader.chapter_loading", "加载数据中…")
        static let loadFailureReadingMenu = text("reader.load_failure_reading_menu", "阅读菜单")
        static let searchContentEmpty = text("reader.search_content_empty", "搜索内容为空，请检查净化或简繁设置")
        static let searchContentSourceInvalidated = text("reader.search_content_source_invalidated", "书籍已变化，请重新打开正文搜索")
        static func searchContentResultCount(_ count: Int) -> String {
            format("reader.search_content_result_count", "搜索结果: %d", count)
        }
        static func searchContentErrorSummary(count: Int, error: String) -> String {
            format("reader.search_content_error_summary", "搜索结果: %1$d，%2$@", count, error)
        }
        static func searchContentChapterSummary(count: Int, chapterTitle: String) -> String {
            format("reader.search_content_chapter_summary", "搜索结果: %1$d / 当前章节: %2$@", count, chapterTitle)
        }
        static let sourceMenuLocalBookMessage = text(
            "reader.source_menu_local_book_message", "本地书：可复制文件/书籍路径，书源登录、付费、Cookie、换源等网络源操作不可用。")
        static let sourceMenuNoSourceMessage = text(
            "reader.source_menu_no_source_message", "当前书籍没有关联书源，无法执行登录、付费、清 Cookie 或换源。")
        static let sourceLocalBookUnavailable = text("reader.source_local_book_unavailable", "本地书不关联网络书源")
        static let searchClosePanelFirst = text("reader.search_close_panel_first", "请先关闭当前面板后再搜索正文")
        static let searchContentChanged = text("reader.search_content_changed", "正文已变化，请重新搜索")
        static let downloadChoiceEmpty = text("reader.download.choice.empty", "当前没有可下载的章节")
        static let downloadAlreadyRunning = text("reader.download_already_running", "本书正在缓存，可在书架的缓存/导出中查看或停止")
        static let refreshNoChapters = text("reader.refresh_no_chapters", "当前没有可刷新的章节")
        static let readAloudVoiceConfigUnavailable = text(
            "reader.read_aloud_voice_config_unavailable", "朗读配置尚未加载，无法保存音色")
        static let readAloudNotStarted = text("reader.read_aloud_not_started", "朗读尚未开始")
        static let readAloudFirstParagraph = text("reader.read_aloud_first_paragraph", "已经是本章第一段")
        static let readAloudLastParagraph = text("reader.read_aloud_last_paragraph", "已经是本章最后一段")
        static let readAloudPaginationPending = text("reader.read_aloud_pagination_pending", "当前章节尚未分页完成，稍后再试")
        static let readAloudNoChapterContent = text("reader.read_aloud_no_chapter_content", "当前章节没有正文内容，无法朗读")
        static let readAloudNoPageParagraphs = text("reader.read_aloud_no_page_paragraphs", "当前页没有可朗读的正文段落")
        static let readAloudBackgroundEnabled = text("reader.read_aloud_background_enabled", "已允许朗读后台播放")
        static let readAloudBackgroundDisabled = text("reader.read_aloud_background_disabled", "已关闭朗读后台播放")
        static let readAloudDefaultVoiceSelected = text("reader.read_aloud_default_voice_selected", "已切换为系统默认音色")
        static let readAloudVoiceChanged = text("reader.read_aloud_voice_changed", "朗读音色已切换")
        static let titleBarInfoUnavailable = text("reader.title_bar_info_unavailable", "来源地址待提供")
        static let chapterListTitle = text("reader.chapter_list_title", "目录")
        static let chapterSearchPlaceholder = text("reader.chapter_search_placeholder", "搜索章节")
        static let chapterCount = text("reader.chapter_count", "共 %d 章")
        static let chapterLabel = text("reader.chapter_label", "第 %d 章")
        static let unavailable = text("reader.unavailable", "阅读暂时不可用")
        static let loading = text("reader.loading", "正在准备阅读环境…")
        static let menuToc = text("reader.menu_toc", "目录")
        static let menuBookmark = text("reader.menu_bookmark", "书签")
        static let menuMoreActions = text("reader.menu_more_actions", "更多操作")
        static let menuInterface = text("reader.menu_interface", "界面")
        static let menuSource = text("reader.menu_source", "书源")
        static let menuRefresh = text("reader.menu_refresh", "刷新")
        static let menuDownload = text("reader.menu_download", "下载")
        static let menuMore = text("reader.menu_more", "更多")
        static let menuHelp = text("reader.menu_help", "帮助")
        static let menuSearch = text("reader.menu_search", "搜索")
        static let menuDayTheme = text("reader.menu_day_theme", "日间")
        static let menuNightTheme = text("reader.menu_night_theme", "夜间")
        static let menuAutoPage = text("reader.menu_auto_page", "自动")
        static let menuReadAloud = text("reader.menu_read_aloud", "朗读")
        static let menuSettings = text("reader.menu_settings", "设置")
        static let mainMenuTitle = text("reader.main_menu_title", "主菜单")
        static let menuQuickTitle = text("reader.menu_quick_title", "快捷操作")
        static let menuNavigateTitle = text("reader.menu_navigate_title", "阅读控制")
        static let menuMoreTitle = text("reader.menu_more_title", "更多入口")
        static let searchMenuTitle = text("reader.search_menu_title", "阅读搜索")
        static let chapterSourceInfoUnavailable = text("reader.chapter_source_info_unavailable", "本章没有可展示的来源地址。")
        static let refreshMenuTitle = text("reader.refresh_menu_title", "刷新缓存")
        static let refreshCurrentSuccess = text("reader.refresh_current_success", "已刷新当前章节缓存")
        static let refreshAfterSuccess = text("reader.refresh_after_success", "已刷新后续章节缓存")
        static let refreshAllSuccess = text("reader.refresh_all_success", "已刷新全部章节缓存")
        static let downloadStarted = text("reader.download_started", "已开始下载章节")
        static let downloadComplete = text("reader.download_complete", "章节下载完成")
        static let downloadLocalUnavailable = text("reader.download_local_unavailable", "本地书无需下载章节缓存")
        static let downloadProgressTitle = text("reader.download_progress_title", "章节下载")
        static let downloadProgressWaiting = text("reader.download_progress_waiting", "正在建立缓存任务…")
        static let downloadProgressRunning = text("reader.download_progress_running", "下载中")
        static let downloadProgressFinished = text("reader.download_progress_finished", "下载完成")
        static let downloadProgressFailed = text("reader.download_progress_failed", "下载失败")
        static let downloadProgressCancelling = text("reader.download_progress_cancelling", "正在停止下载…")
        static let downloadProgressCancelled = text("reader.download_progress_cancelled", "下载已停止")
        static let downloadProgressStop = text("reader.download_progress_stop", "停止下载")
        static let syncProgressLocalAhead = text("reader.sync_progress_local_ahead", "本地进度已同步到云端")
        static let syncProgressInSync = text("reader.sync_progress_in_sync", "阅读进度已一致")
        static let syncProgressDisabled = text("reader.sync_progress_disabled", "同步阅读进度未开启")
        static let syncProgressServerAheadTitle = text("reader.sync_progress_server_ahead_title", "云端进度较新")
        static let syncProgressApplyServer = text("reader.sync_progress_apply_server", "应用云端进度")
        static let syncProgressKeepLocal = text("reader.sync_progress_keep_local", "保留本地进度")
        static let syncProgressAppliedServer = text("reader.sync_progress_applied_server", "已跳转到云端进度")
        static let syncProgressKeptLocal = text("reader.sync_progress_kept_local", "已保留并上传本地进度")
        static let syncProgressApplyNoop = text("reader.sync_progress_apply_noop", "云端进度与本地一致")
        static let syncProgressBookMissing = text("reader.sync_progress_book_missing", "未找到当前书籍")
        static func downloadProgressRange(start: Int, end: Int) -> String {
            format("reader.download_progress_range", "本次范围：第 %1$d-%2$d 章", start, end)
        }
        static func downloadProgressCount(cached: Int, total: Int) -> String {
            format("reader.download_progress_count", "已缓存 %1$d / 全书 %2$d 章", cached, total)
        }
        static func syncProgressServerAheadMessage(local: String, server: String) -> String {
            format("reader.sync_progress_server_ahead_message", "本地：%1$@\n云端：%2$@\n是否跳转到云端进度？", local, server)
        }
        static func syncProgressLocation(chapter: Int, title: String, position: Int) -> String {
            format("reader.sync_progress_location", "第 %1$d 章 %2$@ · %3$d", chapter, title, position)
        }
        static let sourceMenuLogin = text("reader.source_menu_login", "登录")
        static let sourceMenuPay = text("reader.source_menu_pay", "章节付费")
        static let sourceMenuEdit = text("reader.source_menu_edit", "编辑书源")
        static let sourceMenuDisable = text("reader.source_menu_disable", "禁用书源")
        static let sourceClearCookieConfirmMessage = text(
            "reader.source_clear_cookie_confirm_message", "清除当前书源 Cookie 后，下一次加载可能需要重新登录。")
        static let sourceCookiesCleared = text("reader.source_cookies_cleared", "书源 Cookie 已清理")
        static let sourceDisableConfirmMessage = text(
            "reader.source_disable_confirm_message", "禁用后该书源不会再参与搜索、换源或章节加载，确认继续吗？")
        static let sourceDisableSuccess = text("reader.source_disable_success", "已禁用该书源")
        static let sourceDisableNextStep = text("reader.source_disable_next_step", "当前阅读仍会停留在本书，可继续换源或进入书源管理。")
        static let copySourceUrl = text("reader.copy_source_url", "复制书源地址")
        static let copyChapterSourceUrl = text("reader.copy_chapter_source_url", "复制章节链接")
        static let openChapterSourceUrl = text("reader.open_chapter_source_url", "打开章节网页")
        static let sourceMenuEmptyTitle = text("reader.source_menu_empty_title", "暂无可用操作")
        static let sourceMenuEmptyMessage = text("reader.source_menu_empty_message", "当前章节或书源没有提供可执行项。")
        static let searchActionFullText = text("reader.search_action_full_text", "全文搜索")
        static let searchActionCurrentChapter = text("reader.search_action_current_chapter", "搜索当前章")
        static let searchCurrentChapterPrompt = text("reader.search_current_chapter_prompt", "在当前章节内搜索并跳转到匹配位置。")
        static let searchCurrentChapterPlaceholder = text("reader.search_current_chapter_placeholder", "输入关键字")
        static let searchInBook = text("reader.search_in_book", "全文搜索")
        static let searchPlaceholder = text("reader.search_placeholder", "输入搜索内容")
        static let searchReadyPrompt = text("reader.search_ready_prompt", "输入关键字后按搜索")
        static let exitSearch = text("reader.exit_search", "退出搜索")
        static let searchPreviousResult = text("reader.search_previous_result", "上个结果")
        static let searchNextResult = text("reader.search_next_result", "下个结果")
        static let searchResultsAction = text("reader.search_results_action", "结果")
        static let searchMainMenuAction = text("reader.search_main_menu_action", "主菜单")
        static let searchExitAction = text("reader.search_exit_action", "退出")
        static let noSearchResults = text("reader.no_search_results", "未找到匹配内容")
        static let searchSearching = text("reader.search_searching", "正在搜索…")
        static let searchStopped = text("reader.search_stopped", "搜索已停止")
        static func searchStoppedWithResults(_ count: Int) -> String {
            format("reader.search_stopped_with_results", "搜索已停止，保留 %d 个结果", count)
        }
        static func searchResultCount(_ count: Int) -> String {
            format("reader.search_result_count", "找到 %d 个结果", count)
        }
        static func searchNavigationInfo(current: Int, total: Int, chapterTitle: String) -> String {
            format("reader.search_result_navigation_info", "搜索结果: %d/%d · 当前章节: %@", current, total, chapterTitle)
        }
        static let imageActionTitle = text("reader.image_action_title", "图片")
        static let imageActionShow = text("reader.image_action_show", "显示")
        static let imageActionRefresh = text("reader.image_action_refresh", "刷新")
        static let imageActionSave = text("reader.image_action_save", "保存")
        static let imageActionMainMenu = text("reader.image_action_main_menu", "主菜单")
        static let imageActionLoading = text("reader.image_action_loading", "正在加载图片…")
        static let imageActionRefreshed = text("reader.image_action_refreshed", "图片已刷新")
        static let imageActionSaved = text("reader.image_action_saved", "图片已保存")
        static let imageActionSaveFailed = text("reader.image_action_save_failed", "图片保存失败")
        static let autoPageStart = text("reader.auto_page_start", "开始自动翻页")
        static let autoPageStop = text("reader.auto_page_stop", "停止自动翻页")
        static let autoPageReachedEnd = text("reader.auto_page_reached_end", "已到末章，自动翻页已停止")
        static let autoPageSettings = text("reader.auto_page_settings", "自动翻页设置")
        static let autoPageRunningTitle = text("reader.auto_page_running_title", "自动翻页进行中")
        static let autoPageIdleTitle = text("reader.auto_page_idle_title", "自动翻页未开启")
        static let readAloudToggle = text("reader.read_aloud_toggle", "朗读暂停/继续")
        static let readAloudStartShort = text("reader.read_aloud_start_short", "朗读")
        static let readAloudPause = text("reader.read_aloud_pause", "暂停朗读")
        static let readAloudPauseShort = text("reader.read_aloud_pause_short", "暂停")
        static let readAloudResume = text("reader.read_aloud_resume", "继续朗读")
        static let readAloudResumeShort = text("reader.read_aloud_resume_short", "继续")
        static let readAloudPrevParagraph = text("reader.read_aloud_prev_paragraph", "朗读上一段")
        static let readAloudPrevParagraphShort = text("reader.read_aloud_prev_paragraph_short", "上一段")
        static let readAloudNextParagraph = text("reader.read_aloud_next_paragraph", "朗读下一段")
        static let readAloudNextParagraphShort = text("reader.read_aloud_next_paragraph_short", "下一段")
        static let readAloudStop = text("reader.read_aloud_stop", "停止朗读")
        static let readAloudStopShort = text("reader.read_aloud_stop_short", "停止")
        static let readAloudBackground = text("reader.read_aloud_background", "后台播放")
        static let readAloudBackgroundPlaying = text("reader.read_aloud_background_playing", "后台播放中")
        static let readAloudToc = text("reader.read_aloud_toc", "朗读目录")
        static let readAloudSettings = text("reader.read_aloud_settings", "朗读设置")
        static let readAloudIgnoreAudioFocusTitle = text("reader.read_aloud_ignore_audio_focus_title", "忽略音频焦点")
        static let readAloudIgnoreAudioFocusSummary = text(
            "reader.read_aloud_ignore_audio_focus_summary", "允许与其他应用同时播放音频")
        static let readAloudPausePhoneCallsTitle = text("reader.read_aloud_pause_phone_calls_title", "来电期间暂停朗读")
        static let readAloudPausePhoneCallsSummary = text(
            "reader.read_aloud_pause_phone_calls_summary", "在通话期间暂停朗读，需要读取手机状态权限")
        static let readAloudStreamAudioTitle = text("reader.read_aloud_stream_audio_title", "流式播放音频")
        static let readAloudStreamAudioSummary = text(
            "reader.read_aloud_stream_audio_summary", "即边下边播，网络不好时播放会断断续续，仅TTS源有效")
        static let readAloudSpeakEngineTitle = text("reader.read_aloud_speak_engine_title", "朗读引擎")
        static let readAloudSystemTts = text("reader.read_aloud_system_tts", "系统 TTS")
        static let readAloudSystemTtsConfigTitle = text("reader.read_aloud_system_tts_config_title", "系统 TTS 设置")
        static let readAloudSystemTtsConfigSummary = text(
            "reader.read_aloud_system_tts_config_summary", "打开系统 TTS 设置界面")
        static let readAloudFollowSystem = text("reader.read_aloud_follow_system", "跟随系统语速")
        static let readAloudVoiceTitle = text("reader.read_aloud_voice_title", "音色")
        static let readAloudVoiceSystemDefault = text("reader.read_aloud_voice_system_default", "系统默认")
        static let readAloudManualRate = text("reader.read_aloud_manual_rate", "手动语速调节")
        static let readAloudTimerDrag = text("reader.read_aloud_timer_drag", "定时器拖动")
        static let readAloudTimerPreset = text("reader.read_aloud_timer_preset", "定时器快捷选择")
        static let readAloudTimerOff = text("reader.read_aloud_timer_off", "关闭定时")
        static let readAloudVoicePickerHint = text("reader.read_aloud_voice_picker_hint", "选择朗读音色")
        static let readAloudFollowSystemHint = text("reader.read_aloud_follow_system_hint", "开启后使用系统朗读语速")
        static let readAloudRateSliderHint = text("reader.read_aloud_rate_slider_hint", "调整朗读语速")
        static let readAloudPitchSliderHint = text("reader.read_aloud_pitch_slider_hint", "调整朗读音调")
        static let readAloudTimerSliderHint = text("reader.read_aloud_timer_slider_hint", "拖动设置定时关闭")
        static let readAloudTimerPresetHint = text("reader.read_aloud_timer_preset_hint", "打开定时关闭快捷选择")
        static let readAloudPreviousChapterHint = text("reader.read_aloud_previous_chapter_hint", "朗读切换到上一章")
        static let readAloudNextChapterHint = text("reader.read_aloud_next_chapter_hint", "朗读切换到下一章")
        static func readAloudTimerMinutes(_ minutes: Int) -> String {
            guard minutes > 0 else { return readAloudTimerOff }
            return format("reader.read_aloud_timer_minutes", "%d 分钟", minutes)
        }
        static let refreshCurrent = text("reader.refresh_current", "刷新当前章节")
        static let refreshAfter = text("reader.refresh_after", "刷新之后章节")
        static let refreshAll = text("reader.refresh_all", "刷新全部章节")
        static let downloadAfter = text("reader.download_after", "下载之后章节")
        static let downloadAll = text("reader.download_all", "下载全部章节")
        static let charsetAutoDetect = text("reader.charset_auto_detect", "自动识别")
        static func readerOperationAlreadySelected(_ value: String) -> String {
            format("reader.operation_already_selected", "当前已是 %@", value)
        }
        static let moreActionTitle = text("reader.more_action_title", "更多操作")
        static let styleMenuTitle = text("reader.style_menu_title", "界面")
        static let styleThemeRow = text("reader.style_theme_row", "背景与翻页")
        static let styleLayoutRow = text("reader.style_layout_row", "排版与文字")
        static let styleBrightnessRow = text("reader.style_brightness_row", "亮度与自动翻页")
        static let styleTapZoneRow = text("reader.style_tap_zone_row", "点击区域")
        static let moreSettingsTitle = text("reader.more_settings_title", "更多设置")
        static let moreSettingsPrimarySection = text("reader.more_settings_primary_section", "阅读设置")
        static let moreSettingsDisplaySection = text("reader.more_settings_display_section", "显示")
        static let moreSettingsLayoutSection = text("reader.more_settings_layout_section", "排版")
        static let moreSettingsBehaviorSection = text("reader.more_settings_behavior_section", "阅读行为")
        static let moreSettingsSummary = text("reader.more_settings_summary", "仅保留阅读域设置，不再跳到全局设置页。")
        static let backAction = text("reader.back_action", "返回")
        static let quickReplaceAction = text("reader.quick_replace_action", "替换")
        static let screenOrientationTitle = text("reader.screen_orientation_title", "屏幕方向")
        static let screenOrientationSystem = text("reader.screen_orientation_system", "跟随系统")
        static let screenOrientationPortrait = text("reader.screen_orientation_portrait", "竖向")
        static let screenOrientationLandscape = text("reader.screen_orientation_landscape", "横向")
        static let screenOrientationAuto = text("reader.screen_orientation_auto", "跟随传感器")
        static let screenOrientationReversePortrait = text("reader.screen_orientation_reverse_portrait", "反向竖屏")
        static let brightnessAutoEnabled = text("reader.brightness_auto_enabled", "自动")
        static let brightnessAutoDisabled = text("reader.brightness_auto_disabled", "手动")
        static let brightnessModeTitle = text("reader.brightness_mode_title", "亮度跟随系统")
        static let brightnessModeAutoSubtitle = text(
            "reader.brightness_mode_auto_subtitle", "进入阅读页时跟随系统亮度，菜单亮度条只做临时调节。")
        static let brightnessModeManualSubtitle = text(
            "reader.brightness_mode_manual_subtitle", "保留阅读页自己的亮度值，适合夜间或固定环境阅读。")
        static let brightnessModeAutoDetail = text("reader.brightness_mode_auto_detail", "跟随系统亮度，打开菜单后仍可临时拖动亮度条")
        static let brightnessModeManualDetail = text(
            "reader.brightness_mode_manual_detail", "使用阅读页独立亮度，切换书籍和章节时保持当前手动值")
        static let brightnessPositionTitle = text("reader.brightness_position_title", "亮度条位置")
        static let brightnessPositionLeft = text("reader.brightness_position_left", "左侧")
        static let brightnessPositionRight = text("reader.brightness_position_right", "右侧")
        static let brightnessPositionLeftSubtitle = text(
            "reader.brightness_position_left_subtitle", "亮度条靠左，右手翻页时不遮挡主要触控区。")
        static let brightnessPositionRightSubtitle = text(
            "reader.brightness_position_right_subtitle", "亮度条靠右，左手持机时更容易调节。")
        static let brightnessPositionLeftDetail = text("reader.brightness_position_left_detail", "亮度条显示在左侧，避开右侧翻页点击区域")
        static let brightnessPositionRightDetail = text(
            "reader.brightness_position_right_detail", "亮度条显示在右侧，适合左手持机或右侧调节习惯")
        static let progressBehaviorTitle = text("reader.progress_behavior_title", "进度条行为")
        static let progressBehaviorPage = text("reader.progress_behavior_page", "调整本章页数")
        static let progressBehaviorChapter = text("reader.progress_behavior_chapter", "调整章节位置")
        static let progressBehaviorPageDetail = text("reader.progress_behavior_page_detail", "底部进度条按当前分页拖动，细粒度定位到页")
        static let progressBehaviorChapterDetail = text(
            "reader.progress_behavior_chapter_detail", "底部进度条按章节跨度拖动，适合快速跨章定位")
        static func progressPreview(page: String, chapter: String) -> String {
            format("reader.progress_preview", "页数 %@ · 章节 %@", page, chapter)
        }
        static let chapterSliderConfirmTitle = text("reader.chapter_slider_confirm_title", "章节跳转确认")
        static let chapterSliderConfirmMessage = text("reader.chapter_slider_confirm_message", "确定要跳转章节吗？")
        static let tapZoneConfigTitle = text("reader.tap_zone_config_title", "点击区域设置")
        static let tapZoneConfigDetail = text("reader.tap_zone_config_detail", "阅读内调整")
        static let tapZoneConfigPrompt = text("reader.tap_zone_config_prompt", "配置九宫格点击区域动作")
        static let screenOrientationSystemDetail = text("reader.screen_orientation_system_detail", "沿用系统方向锁定和设备当前方向")
        static let screenOrientationPortraitDetail = text(
            "reader.screen_orientation_portrait_detail", "阅读页固定竖屏，适合手机单手连续阅读")
        static let screenOrientationLandscapeDetail = text(
            "reader.screen_orientation_landscape_detail", "阅读页固定横屏，适合双页或大屏阅读")
        static let screenOrientationAutoDetail = text("reader.screen_orientation_auto_detail", "允许阅读页跟随重力感应自动旋转")
        static let screenOrientationReversePortraitDetail = text(
            "reader.screen_orientation_reverse_portrait_detail", "阅读页固定反向竖屏，适合充电或支架场景")
        // F124: 滑动翻页阈值
        static let pageTouchSlopTitle = text("reader.page_touch_slop_title", "滑动翻页阈值")
        static let pageTouchSlopDialogTitle = text("reader.page_touch_slop_dialog_title", "滑动翻页阈值（0 = 系统默认值）")
        static let pageTouchSlopSystemDefaultValue = text("reader.page_touch_slop_system_default_value", "0 = 系统默认值")
        static func pageTouchSlopPxValue(_ value: Int) -> String {
            format("reader.page_touch_slop_px_value", "%d px", value)
        }
        static func pageTouchSlopSummary(_ defaultValue: Int) -> String {
            format("reader.page_touch_slop_summary", "滑动多长距离才会触发滑动翻页（系统默认值 %d px）", defaultValue)
        }
        static let pageTouchSlopRangeHint = text("reader.page_touch_slop_range_hint", "范围 0...9999，0 表示使用系统默认值。")
        static let pageTouchSlopInvalidRange = text("reader.page_touch_slop_invalid_range", "请输入 0...9999 的整数")
        static let pageTouchSensitivityTitle = text("reader.page_touch_sensitivity_title", "翻页触控灵敏度")
        static let pageTouchSensitivityDetail = text("reader.page_touch_sensitivity_detail", "调整点击翻页判定区域大小")
        static let pageTouchSensitivityLow = text("reader.page_touch_sensitivity_low", "低")
        static let pageTouchSensitivityMedium = text("reader.page_touch_sensitivity_medium", "中")
        static let pageTouchSensitivityHigh = text("reader.page_touch_sensitivity_high", "高")
        static func touchSensitivityLowDetail(_ movement: Int) -> String {
            format("reader.touch_sensitivity_low_detail", "点击需更稳定，允许约 %dpt 手指移动，减少误翻页", movement)
        }
        static func touchSensitivityMediumDetail(_ movement: Int) -> String {
            format("reader.touch_sensitivity_medium_detail", "默认手感，允许约 %dpt 手指移动，兼顾误触和响应", movement)
        }
        static func touchSensitivityHighDetail(_ movement: Int) -> String {
            format("reader.touch_sensitivity_high_detail", "点击判定更宽松，允许约 %dpt 手指移动，适合单手滑动阅读", movement)
        }
        static let pendingNextIteration = text("reader.pending_next_iteration", "下一轮接通")
        static let operationRefreshDetail = text("reader.operation_refresh_detail", "当前章节 / 之后章节 / 全部章节")
        static let operationDownloadDetail = text("reader.operation_download_detail", "下载之后章节 / 下载全部章节")
        static let operationMoreActionsDetail = text("reader.operation_more_actions_detail", "反转内容 / 分段 / 标签 / 编码 / 图片")
        static let operationRefreshCurrentDetail = text("reader.operation_refresh_current_detail", "重新拉取并渲染当前章节正文")
        static let operationClearCacheDetail = text("reader.operation_clear_cache_detail", "清除本书已缓存章节内容，之后阅读会重新加载")
        static let operationBookDetailDetail = text("reader.operation_book_detail_detail", "查看书籍详情、目录与书籍信息")
        static let operationReadAloudDetail = text("reader.operation_read_aloud_detail", "打开朗读控制、语速、定时和后台朗读设置")
        static let operationRefreshChaptersDetail = text(
            "reader.operation_refresh_chapters_detail", "重新同步目录，并尽量定位到当前章节")
        static let operationBookmarkListDetail = text("reader.operation_bookmark_list_detail", "查看和管理当前书籍书签")
        static let operationSyncProgressDetail = text("reader.operation_sync_progress_detail", "与云端阅读进度对齐")
        static let operationSearchDetail = text("reader.operation_search_detail", "在当前章节或全书正文中搜索")
        static let operationEditContentDetail = text("reader.operation_edit_content_detail", "编辑并保存当前章节正文缓存")
        static let operationReplaceRuleDetail = text("reader.operation_replace_rule_detail", "开启/关闭替换规则，或查看当前生效规则")
        static let operationReverseContentDetail = text("reader.operation_reverse_content_detail", "会改写当前章节正文缓存的段落顺序")
        static let operationReSegmentDetail = text("reader.operation_re_segment_detail", "切换后会刷新当前章节排版")
        static let operationRemoveDuplicateTitleDetail = text(
            "reader.operation_remove_duplicate_title_detail", "过滤正文中重复出现的章节标题")
        static let operationDeleteRubyTagDetail = text("reader.operation_delete_ruby_tag_detail", "过滤 Ruby 注音标签后重新渲染")
        static let operationDeleteHTagDetail = text("reader.operation_delete_h_tag_detail", "过滤 HTML 标题标签后重新渲染")
        static let operationCharsetDetail = text("reader.operation_charset_detail", "重新识别文本编码并刷新目录/正文")
        static let operationImageStyleDetail = text("reader.operation_image_style_detail", "调整正文图片显示方式")
        static let operationAddToBookshelfDetail = text("reader.operation_add_to_bookshelf_detail", "加入书架后可同步进度与管理缓存")
        static let reverseContentConfirmMessage = text(
            "reader.reverse_content_confirm_message", "将反转并保存当前章节正文缓存的段落顺序。需要恢复时可刷新当前章节重新拉取原文。")
        static let clearCacheConfirmReaderMessage = text(
            "reader.clear_cache_confirm_reader_message", "会移除本书已缓存章节内容，当前阅读位置不会删除；后续打开章节时将重新从书源加载。")
        static let readerOperationTitle = text("reader.operation_title", "阅读操作")
        static let hideStatusBarDetail = text("reader.hide_status_bar_detail", "菜单收起后隐藏状态栏")
        static let hideNavigationBarDetail = text("reader.hide_navigation_bar_detail", "阅读时隐藏系统导航栏")
        static let showBrightnessBarTitle = text("reader.show_brightness_bar_title", "显示亮度调节控件")
        static let showBrightnessBarDetail = text("reader.show_brightness_bar_detail", "菜单显示时在侧边展示亮度调节")
        static let paddingDisplayCutoutsTitle = text("reader.padding_display_cutouts_title", "填充刘海区域")
        static let showTitleAdditionTitle = text("reader.show_title_addition_title", "展示顶部工具栏附加区域")
        static let showTitleAdditionDetail = text("reader.show_title_addition_detail", "显示章节名、来源与章节地址")
        static let noAnimScrollPageTitle = text("reader.no_anim_scroll_page_title", "禁用滚动点击动画")
        static let mouseWheelPageTitle = text("reader.mouse_wheel_page_title", "鼠标滚轮翻页")
        static let keyPageTitle = text("reader.key_page_title", "音量键翻页")
        static let customKeyPageTitle = text("reader.custom_key_page_title", "自定义翻页按键")
        static let customKeyPageDetail = text("reader.custom_key_page_detail", "设置上一页 / 下一页触发按键")
        static let customKeyPagePreviousTitle = text("reader.custom_key_page_previous_title", "上一页")
        static let customKeyPageNextTitle = text("reader.custom_key_page_next_title", "下一页")
        static let customKeyPageUnset = text("reader.custom_key_page_unset", "未设置")
        static let customKeyPageReset = text("reader.custom_key_page_reset", "重置")
        static let customKeyPageHelp = text("reader.custom_key_page_help", "将焦点放到输入框按下物理按键会自动录入键值，多个按键会自动用英文逗号隔开。")
        static func customKeyPageCurrentValue(_ value: String) -> String {
            format("reader.custom_key_page_current_value", "当前值：%@", value)
        }
        static let keyPageOnReadAloudTitle = text("reader.key_page_on_read_aloud_title", "朗读时音量键翻页")
        static let keyPageOnLongPressTitle = text("reader.key_page_on_long_press_title", "按键长按翻页")
        static let previewImageByClickTitle = text("reader.preview_image_by_click_title", "点击预览图片")
        static let optimizeRenderTitle = text("reader.optimize_render_title", "启用绘制优化")
        static let disableReturnKeyTitle = text("reader.disable_return_key_title", "禁用返回键")
        static let readBarStyleFollowPageTitle = text("reader.read_bar_style_follow_page_title", "工具栏样式跟随页面")
        static let screenTimeoutTitle = text("reader.screen_timeout_title", "屏幕超时")
        static let screenTimeoutDefault = text("reader.screen_timeout_default", "默认")
        static let screenTimeoutOneMinute = text("reader.screen_timeout_one_minute", "1分钟")
        static let screenTimeoutFiveMinutes = text("reader.screen_timeout_five_minutes", "5分钟")
        static let screenTimeoutTenMinutes = text("reader.screen_timeout_ten_minutes", "10分钟")
        static let screenTimeoutAlways = text("reader.screen_timeout_always", "常亮")
        static let screenTimeoutDefaultDetail = text("reader.screen_timeout_default_detail", "跟随系统屏幕超时")
        static let screenTimeoutOneMinuteDetail = text("reader.screen_timeout_one_minute_detail", "阅读时 1 分钟无操作后允许熄屏")
        static let screenTimeoutFiveMinutesDetail = text(
            "reader.screen_timeout_five_minutes_detail", "阅读时 5 分钟无操作后允许熄屏")
        static let screenTimeoutTenMinutesDetail = text("reader.screen_timeout_ten_minutes_detail", "阅读时 10 分钟无操作后允许熄屏")
        static let screenTimeoutAlwaysDetail = text("reader.screen_timeout_always_detail", "阅读期间保持屏幕常亮")
        static let textSelectableTitle = text("reader.text_selectable_title", "长按选择文本")
        static let textSelectableDetail = text("reader.text_selectable_detail", "允许长按选择文字进行复制、朗读等操作")
        static let expandTextMenuTitle = text("reader.expand_text_menu_title", "展开文本选择菜单")
        static let expandTextMenuDetail = text("reader.expand_text_menu_detail", "选字后一次性显示全部操作项，无需点击\u{201C}更多\u{201D}")
        static let dualPageModeTitle = text("reader.dual_page_mode_title", "双页模式")
        static let dualPageModeDetail = text("reader.dual_page_mode_detail", "左右并排显示两页内容，适合横屏或 iPad 使用")
        static let doublePageHorizontalTitle = text("reader.double_page_horizontal_title", "平板/横屏双页")
        static let doublePageHorizontalSinglePage = text("reader.double_page_horizontal_single_page", "全局单页")
        static let doublePageHorizontalDoublePage = text("reader.double_page_horizontal_double_page", "全局双页")
        static let doublePageHorizontalLandscape = text("reader.double_page_horizontal_landscape", "横屏双页")
        static let doublePageHorizontalTabletOrLandscape = text(
            "reader.double_page_horizontal_tablet_or_landscape", "平板或横屏双页")
        static let doublePageHorizontalSinglePageDetail = text(
            "reader.double_page_horizontal_single_page_detail", "始终按单页分页与显示")
        static let doublePageHorizontalDoublePageDetail = text(
            "reader.double_page_horizontal_double_page_detail", "始终左右并排显示两页")
        static let doublePageHorizontalLandscapeDetail = text(
            "reader.double_page_horizontal_landscape_detail", "仅在横屏阅读时启用双页")
        static let doublePageHorizontalTabletOrLandscapeDetail = text(
            "reader.double_page_horizontal_tablet_or_landscape_detail", "平板设备或横屏阅读时启用双页")
        static let selectionMore = text("reader.selection_more", "更多")
        static let refreshingChapters = text("reader.refreshing_chapters", "正在刷新章节 %1$d/%2$d …")
        static let refreshComplete = text("reader.refresh_complete", "已刷新 %d 个章节")
        static let restorePositionTitle = text("reader.restore_position_title", "恢复原位")
        static let addToShelfPromptTitle = text("reader.add_to_shelf_prompt_title", "加入书架")
        static let addToShelfPromptMessage = text("reader.add_to_shelf_prompt_message", "是否将本书加入书架？")
        static let textFullJustifyDetail = text("reader.text_full_justify_detail", "正文两端对齐")
        static let textBottomJustifyDetail = text("reader.text_bottom_justify_detail", "分页时正文尽量贴底")
        static let progressSheetTitle = text("reader.progress_sheet_title", "阅读进度")
        static let progressSheetMessage = text("reader.progress_sheet_message", "当前位于第 %1$d/%2$d 章，第 %3$d/%4$d 页。")
        static let menuPrevious = text("reader.menu_previous", "上一章")
        static let menuNext = text("reader.menu_next", "下一章")
        static let chapterLoadFailed = text("reader.chapter_load_failed", "章节加载失败")
        static let bookmarkAddedTitle = text("reader.bookmark_added_title", "书签已添加")
        static let bookmarkAddedMessage = text("reader.bookmark_added_message", "当前位置已经保存到 shared 书签库。")
        static let addBookmarkActionDetail = text("reader.add_bookmark_action_detail", "将当前阅读位置保存到书签")
        static let bookmarkListTitle = text("reader.bookmark_list_title", "书签列表")
        static let bookmarkEmptyMessage = text("reader.bookmark_empty_message", "还没有添加书签")
        static let bookmarkDeleteTitle = text("reader.bookmark_delete_title", "删除")
        static let bookmarkDeleteFailed = text("reader.bookmark_delete_failed", "书签删除失败")
        static let bookmarkSaveFailed = text("reader.bookmark_save_failed", "书签保存失败")
        static let bookmarkLoadFailed = text("reader.bookmark_load_failed", "书签加载失败")
        static let bookmarkSearchPlaceholder = text("reader.bookmark_search_placeholder", "搜索书签")
        static let bookmarkExportTitle = text("reader.bookmark_export_title", "导出书签")
        static let zhLayoutTitle = text("reader.zh_layout_title", "使用自定义中文分行")
        static let zhLayoutDetail = text("reader.zh_layout_detail", "启用中文断行策略，减少标点挤压和行尾不自然换行")
        static let readBodyToLhTitle = text("reader.read_body_to_lh_title", "扩展到刘海")
        static let readBodyToLhDetail = text("reader.read_body_to_lh_detail", "正文严格按阅读行高分页和绘制，关闭后更接近系统字体自然行距")
        static let bookmarkExportJson = text("reader.bookmark_export_json", "JSON 格式")
        static let bookmarkExportMarkdown = text("reader.bookmark_export_markdown", "Markdown 格式")
        static let bookmarkExportReady = text("reader.bookmark_export_ready", "导出文件已准备好")
        static let bookmarkOpenUnavailable = text("reader.bookmark_open_unavailable", "当前页面无法打开该书签")
        static let bookmarkStale = text("reader.bookmark_stale", "书签状态已变化，请刷新后重试")
        static let operationBusy = text("reader.operation_busy", "请先完成当前操作")
        static let bookmarkMarkdownTitle = text("reader.bookmark_markdown_title", "书签")
        static let bookmarkViewDetail = text("reader.bookmark_view_detail", "书签详情")
        static let bookmarkSortTitle = text("reader.bookmark_sort_title", "书签排序")
        static let bookmarkSortLatest = text("reader.bookmark_sort_latest", "最新添加优先")
        static let bookmarkSortEarliest = text("reader.bookmark_sort_earliest", "最早添加优先")
        static let bookmarkSortChapterAscending = text("reader.bookmark_sort_chapter_ascending", "章节正序")
        static let bookmarkSortChapterDescending = text("reader.bookmark_sort_chapter_descending", "章节倒序")
        static func bookmarkChapterTitle(_ index: Int) -> String {
            format("reader.bookmark_chapter_title", "第 %d 章", index)
        }
        static func bookmarkMeta(chapterIndex: Int, position: Int) -> String {
            format("reader.bookmark_meta", "第 %d 章 · %d", chapterIndex, position)
        }
        static let reverseOrder = text("reader.reverse_order", "翻转顺序")
        static let scrollToTop = text("reader.scroll_to_top", "到顶部")
        static let scrollToBottom = text("reader.scroll_to_bottom", "到底部")
        static let chapterSearchEmpty = text("reader.chapter_search_empty", "没有匹配的章节")
        static let chapterJumpAction = text("reader.chapter_jump_action", "跳转章节")
        static let chapterCopyTitleAction = text("reader.chapter_copy_title_action", "复制标题")
        static let chapterLocateCurrentAction = text("reader.chapter_locate_current_action", "定位当前章节")
        static let chapterVolumeCannotJump = text("reader.chapter_volume_cannot_jump", "分卷标题不能跳转")
        static let chapterNoRows = text("reader.chapter_no_rows", "当前没有可操作的章节")
        static let chapterCurrentNotFound = text("reader.chapter_current_not_found", "当前章节不在列表中")
        static let chapterBookmarkUnavailable = text("reader.chapter_bookmark_unavailable", "当前无法打开书签列表")
        static let replaceRuleEnabledTitle = text("reader.replace_rule_enabled_title", "替换规则已开启")
        static let replaceRuleDisabledTitle = text("reader.replace_rule_disabled_title", "替换规则已关闭")
        static let replaceRuleMessage = text("reader.replace_rule_message", "当前章节会按 shared 规则重新加载。")
        static let replaceRuleMenuTitle = text("reader.replace_rule_menu_title", "替换规则")
        static let replaceRuleToggleAction = text("reader.replace_rule_toggle_action", "开启/关闭替换规则")
        static let replaceRuleEffectiveAction = text("reader.replace_rule_effective_action", "查看生效规则")
        static let replaceRuleManageAction = text("reader.replace_rule_manage_action", "管理替换规则")
        static let sourceInfoTitle = text("reader.source_info_title", "书源")
        static let brightnessAutoTitle = text("reader.brightness_auto_title", "自动亮度")
        static let chapterStateCurrent = text("reader.chapter_state_current", "当前阅读")
        static let chapterStateCached = text("reader.chapter_state_cached", "已缓存")
        static let chapterStatePendingCache = text("reader.chapter_state_pending_cache", "未缓存")

        static func searchCurrentChapterNoResults(_ query: String) -> String {
            format("reader.search_current_chapter_no_results", "当前章节没有找到\u{201C}%@\u{201D}。", query)
        }

        static func searchCurrentChapterResults(query: String, count: Int) -> String {
            format("reader.search_current_chapter_results", "\u{201C}%@\u{201D} 共匹配到 %d 处。", query, count)
        }

        static func searchFailed(_ reason: String) -> String {
            format("reader.search_failed", "搜索失败：%@", reason)
        }

        static func chapterCountText(_ count: Int) -> String {
            format("reader.chapter_count_text", "共 %d 章", count)
        }

        static func chapterProgressHeader(current: Int, total: Int, title: String) -> String {
            format("reader.chapter_progress_header", "当前第 %d/%d 章：%@", current, total, title)
        }

        static func bookmarkCountText(_ count: Int) -> String {
            format("reader.bookmark_count_text", "共 %d 条书签", count)
        }

        static func chapterText(_ index: Int) -> String {
            format("reader.chapter_text", "第 %d 章", index)
        }

        // F38 反转内容
        static let reverseContentTitle = text("reader.reverse_content_title", "反转内容")
        static let reverseContentMessage = text("reader.reverse_content_message", "当前章节内容已反转。")
        // F46 更新目录
        static let refreshTocTitle = text("reader.refresh_toc_title", "更新目录")
        static let refreshTocLoading = text("reader.refresh_toc_loading", "正在更新目录…")
        static let refreshTocSuccess = text("reader.refresh_toc_success", "目录已更新")
        static let refreshTocFailed = text("reader.refresh_toc_failed", "更新目录失败")
        // F47 生效的替换规则
        static let effectiveReplaceRulesTitle = text("reader.effective_replace_rules_title", "生效的替换规则")
        static let effectiveReplaceRulesEmpty = text("reader.effective_replace_rules_empty", "当前没有生效的替换规则。")
        static func effectiveReplaceRulesSummary(_ count: Int) -> String {
            format("reader.effective_replace_rules_summary", "当前匹配 %d 条规则", count)
        }
        // F31 TXT目录规则
        static let txtTocRuleTitle = text("reader.txt_toc_rule_title", "TXT目录规则")
        // F32 设置编码
        static let setCharsetTitle = text("reader.set_charset_title", "设置编码")
        static let setCharsetMessage = text("reader.set_charset_message", "选择文本编码")
        static let charsetUpdated = text("reader.charset_updated", "编码已更新")
        // F41 移除重复标题
        static let removeDuplicateTitleTitle = text("reader.remove_duplicate_title", "移除重复标题")
        // F43 删除Ruby标签
        static let deleteRubyTagTitle = text("reader.delete_ruby_tag", "删除Ruby标签")
        // F44 删除H标签
        static let deleteHTagTitle = text("reader.delete_h_tag", "删除H标签")
        // F45 图片样式
        static let imageStyleTitle = text("reader.image_style_title", "图片样式")
        static let imageStyleDefault = text("reader.image_style_default", "DEFAULT")
        static let imageStyleFull = text("reader.image_style_full", "FULL")
        static let imageStyleText = text("reader.image_style_text", "TEXT")
        static let imageStyleSingle = text("reader.image_style_single", "SINGLE")
        static let imageStyleUpdated = text("reader.image_style_updated", "图片样式已更新")
        static func readerOperationEnabled(_ title: String) -> String {
            format("reader.operation_enabled", "%@ 已开启", title)
        }
        static func readerOperationDisabled(_ title: String) -> String {
            format("reader.operation_disabled", "%@ 已关闭", title)
        }
        // F159 加入书架提示
        static let addToBookshelfTitle = text("reader.add_to_bookshelf_title", "加入书架")
        static let addToBookshelfSuccess = text("reader.add_to_bookshelf_success", "已加入书架")
        static let addToBookshelfNo = text("reader.add_to_bookshelf_no", "不加入")

        static func addToBookshelfMessage(_ name: String) -> String {
            format("reader.add_to_bookshelf_message", "是否将《%@》加入书架？", name)
        }

        static func refreshTocResult(_ count: Int) -> String {
            format("reader.refresh_toc_result", "目录已更新，共 %d 章", count)
        }

        static func chapterMetaText(index: Int, state: String) -> String {
            format("reader.chapter_meta_text", "第 %d 章 · %@", index, state)
        }

        static func pageTitle(chapterTitle: String, pageIndex: Int, pageCount: Int) -> String {
            format("reader.page_title", "%@ (%d/%d)", chapterTitle, pageIndex, pageCount)
        }

        static func progress(chapterIndex: Int, chapterCount: Int, pageIndex: Int, pageCount: Int) -> String {
            format("reader.progress", "第 %d/%d 章 · 第 %d/%d 页", chapterIndex, chapterCount, pageIndex, pageCount)
        }

        static func chapterProgress(chapterIndex: Int, chapterCount: Int) -> String {
            format("reader.chapter_progress", "第 %d/%d 章", chapterIndex, chapterCount)
        }

        static func debug(chapterIndex: Int, pageIndex: Int, pageCount: Int, offset: Int, pages: Int) -> String {
            format("reader.debug", "章 %d | 页 %d/%d\n偏移 %d | 分页 %d", chapterIndex, pageIndex, pageCount, offset, pages)
        }

        // MARK: - Text Selection (F50-F58)
        static let selectionCopy = text("reader.selection_copy", "复制")
        static let selectionBookmark = text("reader.selection_bookmark", "书签")
        static let selectionReadAloud = text("reader.selection_read_aloud", "朗读")
        static let selectionDictionary = text("reader.selection_dictionary", "字典")
        static let selectionSearch = text("reader.selection_search", "搜索")
        static let selectionBrowser = text("reader.selection_browser", "浏览器")
        static let selectionShare = text("reader.selection_share", "分享")
        static let selectionCopied = text("reader.selection_copied", "已复制到剪贴板")
        static let selectionEmpty = text("reader.selection_empty", "选中的内容为空")
        static let selectionBrowserUnavailable = text("reader.selection_browser_unavailable", "无法打开选中文本")
        static let selectionPageUnavailable = text("reader.selection_page_unavailable", "当前页面还不能选择文本")
        static let selectionNoTextAtPosition = text("reader.selection_no_text_at_position", "当前位置没有可选择的文字")
        static let selectionShareReady = text("reader.selection_share_ready", "已打开分享面板")
        static let selectionDictUnavailable = text("reader.selection_dict_unavailable", "词典不可用")
        static let selectionDictWebSearch = text("reader.selection_dict_web_search", "网页词典")
        static let selectionSearchInBook = text("reader.selection_search_in_book", "书内搜索")
        static func selectionDictNoDefinition(_ term: String) -> String {
            format("reader.selection_dict_no_definition", "系统词典没有找到“%@”。", term)
        }
        static func selectionDictionaryQuery(_ term: String) -> String {
            format("reader.selection_dictionary_query", "%@ 词典", term)
        }
        // F52: 替换(选中文字)
        static let selectionReplace = text("reader.selection_replace", "替换")
        static let selectionReplaceTitle = text("reader.selection_replace_title", "替换结果")
        static let selectionReplaceOriginal = text("reader.selection_replace_original", "原文")
        static let selectionReplaceResult = text("reader.selection_replace_result", "结果")
        static let selectionReplaceNoChange = text("reader.selection_replace_no_change", "替换规则未对选中文本产生变化。")
        static let selectionReplaceNoRules = text("reader.selection_replace_no_rules", "当前没有生效的替换规则。")
        // F39: 自动翻页(更多菜单)
        static let menuAutoPageAction = text("reader.menu_auto_page_action", "自动翻页")
        // F48: 查看日志/会话信息
        static let viewSessionInfoTitle = text("reader.view_session_info_title", "阅读会话信息")
        static let viewSessionInfoMenuItem = text("reader.view_session_info_menu_item", "阅读会话信息")
        // F69: 朗读高级设置
        static let readAloudPitchTitle = text("reader.read_aloud_pitch_title", "音调")
        // F125: 自动换源
        static let autoChangeSourceLoading = text("reader.auto_change_source_loading", "正在自动换源…")
        static let autoChangeSourceSuccess = text("reader.auto_change_source_success", "已自动切换书源")
        static let autoChangeSourceFailed = text("reader.auto_change_source_failed", "自动换源失败，未找到可用书源")
        // F49: 帮助
        static let helpTitle = text("reader.help_title", "阅读帮助")
        static let helpContentTap = text("reader.help_content_tap", "点击翻页：点击屏幕左侧翻到上一页，右侧翻到下一页，中央打开菜单。")
        static let helpContentMenu = text("reader.help_content_menu", "菜单：点击屏幕中央区域打开菜单，可调整亮度、字体、翻页动画等。")
        static let helpContentLongPress = text("reader.help_content_long_press", "长按选字：长按正文可选择文字，进行复制、朗读、替换等操作。")
        static let helpContentBrightness = text("reader.help_content_brightness", "亮度调节：菜单显示时侧边可拖动亮度条，也可切换自动/手动亮度。")
        static let helpContentAutoPage = text("reader.help_content_auto_page", "自动翻页：在菜单中开启自动翻页，可调整翻页速度。")
        static let helpContentReadAloud = text("reader.help_content_read_aloud", "朗读：在菜单中开启朗读，支持调整语速、音调和音色。")
        static let helpContentBookmark = text("reader.help_content_bookmark", "书签：在更多菜单中添加书签，可随时回到标记的位置。")
        static let helpContentProgress = text("reader.help_content_progress", "进度条：底部进度条可按页或按章拖动，快速定位阅读位置。")
        static let helpContentSwipe = text("reader.help_content_swipe", "边缘滑动：从屏幕左边缘向右滑动可返回上一级。")

        // F34: 编辑内容
        static let editContent = text("reader.edit_content", "编辑内容")
        static let editContentUnsavedTitle = text("reader.edit_content_unsaved_title", "保存本次修改？")
        static let saveContent = text("reader.save_content", "保存")
        static let discardContent = text("reader.discard_content", "放弃修改")
        static let editContentSaved = text("reader.edit_content_saved", "内容已保存")
        // F42: 重新分段
        static let reSegment = text("reader.re_segment", "重新分段")
        static let reSegmentEnabled = text("reader.re_segment_enabled", "重新分段已开启")
        static let reSegmentDisabled = text("reader.re_segment_disabled", "重新分段已关闭")

        // F27: 换源
        static let changeSource = text("reader.change_source", "换源")
        static let changeSourceLoading = text("reader.change_source_loading", "正在换源…")
        static let changeSourceSuccess = text("reader.change_source_success", "换源成功")
        static let changeSourceFailed = text("reader.change_source_failed", "换源失败")
        // F28: 章节换源
        static let chapterChangeSource = text("reader.chapter_change_source", "单章换源")
        static let bookChangeSource = text("reader.book_change_source", "整书换源")
        static let chapterChangeSourceLoadToc = text("reader.chapter_change_source_load_toc", "正在读取候选目录…")
        static let chapterChangeSourceSelectChapter = text("reader.chapter_change_source_select_chapter", "选择候选章节")
        static let chapterChangeSourceReplacing = text("reader.chapter_change_source_replacing", "正在替换当前章节…")
        static let chapterChangeSourceEmptyToc = text("reader.chapter_change_source_empty_toc", "候选源目录为空")
        static let chapterChangeSourceCurrentFormat = text(
            "reader.chapter_change_source_current_format", "当前：%d/%d  %@")
        static let chapterChangeSourceSuccess = text("reader.chapter_change_source_success", "章节换源成功")
        // F161: 漫画菜单
        static let comicMenu = text("reader.comic_menu", "漫画设置")
        static let comicStyleScroll = text("reader.comic_style_scroll", "滚动模式")
        static let comicStylePage = text("reader.comic_style_page", "翻页模式")
        // F30: 离线缓存
        static let offlineCache = text("reader.offline_cache", "离线缓存")
        static let cacheNext50 = text("reader.cache_next_50", "缓存后续50章")
        static let cacheNextAll = text("reader.cache_next_all", "缓存后续全部")
        static let cacheAll = text("reader.cache_all", "缓存全部")
        static let cacheStarted = text("reader.cache_started", "缓存任务已开始")
        static let cacheFailed = text("reader.cache_failed", "缓存启动失败")

        // MARK: - Image Interaction (F137-F139)
        static let imageMenuTitle = text("reader.image_menu_title", "图片操作")
        static let imagePreview = text("reader.image_preview", "查看大图")
        static let imageSave = text("reader.image_save", "保存到相册")
        static let imageSaved = text("reader.image_saved", "图片已保存到相册")
        static let imageSaveFailed = text("reader.image_save_failed", "保存失败，请检查相册权限")
        static let imageNotLoaded = text("reader.image_not_loaded", "图片尚未加载完成")
    }
}
