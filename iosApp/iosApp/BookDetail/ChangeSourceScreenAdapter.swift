import Foundation
import shared

enum ChangeSourceOption: String, CaseIterable {
    case checkAuthor, loadWordCount, loadInfo, loadToc

    var title: String {
        switch self {
        case .checkAuthor: return SourceChangeText.checkAuthor.value
        case .loadWordCount: return SourceChangeText.loadWordCount.value
        case .loadInfo: return SourceChangeText.loadInfo.value
        case .loadToc: return SourceChangeText.loadToc.value
        }
    }

    func value(in config: AppRuntimeConfig) -> Bool {
        switch self {
        case .checkAuthor: return config.changeSourceCheckAuthor
        case .loadWordCount: return config.changeSourceLoadWordCount
        case .loadInfo: return config.changeSourceLoadInfo
        case .loadToc: return config.changeSourceLoadToc
        }
    }
}

struct ChangeSourceScreenState {
    let config: AppRuntimeConfig
    let sources: [BookSource]

    var groups: [String] {
        var seen = Set<String>()
        return sources.filter(\.enabled).flatMap {
            ($0.bookSourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    var sourceOrders: [String: Int] {
        Dictionary(sources.map { ($0.bookSourceUrl, Int($0.customOrder)) }, uniquingKeysWith: { _, last in last })
    }

    func includes(_ candidate: BookSourceChangeCandidate) -> Bool {
        guard let source = sources.first(where: { $0.bookSourceUrl == candidate.sourceUrl }), source.enabled else {
            return false
        }
        guard !config.searchGroup.isEmpty else { return true }
        return (source.bookSourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.contains(config.searchGroup)
    }
}

@MainActor
final class ChangeSourceScreenAdapter {
    private let bindings = FlowSubscriptionStore()
    private var settings: SettingsFacade?
    private var sourcesFacade: SourceManagementFacade?
    private var config: AppRuntimeConfig?
    private var sources: [BookSource]?
    private var generation = UUID()
    var onState: ((ChangeSourceScreenState) -> Void)?

    func bind() throws {
        unbind()
        let settings = try SharedRuntime.settingsFacade().get()
        let sourcesFacade = try SharedRuntime.sourceManagementFacade().get()
        self.settings = settings
        self.sourcesFacade = sourcesFacade
        let id = generation
        bindings.store(
            settings.watchRuntimeConfig { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.config = value
                    self.emit()
                }
            })
        bindings.store(
            sourcesFacade.watchSources { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.sources = value
                    self.emit()
                }
            })
    }

    func unbind() {
        generation = UUID()
        bindings.cancelAll()
        config = nil
        sources = nil
    }

    func set(_ option: ChangeSourceOption, enabled: Bool) async throws {
        let facade = try settings ?? SharedRuntime.settingsFacade().get()
        try await SharedAsync.void { completion in
            switch option {
            case .checkAuthor: facade.setChangeSourceCheckAuthor(enabled: enabled, completionHandler: completion)
            case .loadWordCount: facade.setChangeSourceLoadWordCount(enabled: enabled, completionHandler: completion)
            case .loadInfo: facade.setChangeSourceLoadInfo(enabled: enabled, completionHandler: completion)
            case .loadToc: facade.setChangeSourceLoadToc(enabled: enabled, completionHandler: completion)
            }
        }
    }

    func setGroup(_ group: String) async throws {
        try await SearchScopePreferencesClient().save(group.isEmpty ? .allEnabled : .group(group))
    }

    func move(_ candidate: BookSourceChangeCandidate, toTop: Bool) async throws {
        let facade = try sourcesFacade ?? SharedRuntime.sourceManagementFacade().get()
        let sources = try await facade.getAllSourcesAsync()
        guard sources.contains(where: { $0.bookSourceUrl == candidate.sourceUrl }) else { throw missingSource() }
        let edge = toTop ? sources.map(\.customOrder).min() : sources.map(\.customOrder).max()
        let (order, overflow) = (edge ?? 0).addingReportingOverflow(toTop ? -1 : 1)
        guard !overflow else {
            throw NSError(
                domain: "io.legado.sourceChange", code: 2,
                userInfo: [NSLocalizedDescriptionKey: SourceChangeText.orderBoundary.value])
        }
        try await facade.updateSourceOrderAsync(sourceUrl: candidate.sourceUrl, order: order)
    }

    func disable(_ candidate: BookSourceChangeCandidate) async throws {
        let facade = try sourcesFacade ?? SharedRuntime.sourceManagementFacade().get()
        try await facade.setEnabledAsync(sourceUrl: candidate.sourceUrl, enabled: false)
    }

    func delete(_ candidate: BookSourceChangeCandidate) async throws {
        let facade = try sourcesFacade ?? SharedRuntime.sourceManagementFacade().get()
        guard try await facade.getSourceAsync(sourceUrl: candidate.sourceUrl) != nil else { throw missingSource() }
        try await facade.deleteSourceAsync(sourceUrl: candidate.sourceUrl)
    }

    private func emit() {
        guard let config, let sources else { return }
        onState?(.init(config: config, sources: sources))
    }

    private func missingSource() -> NSError {
        NSError(
            domain: "io.legado.sourceChange", code: 1,
            userInfo: [NSLocalizedDescriptionKey: SourceChangeText.missingSource.value])
    }
}

/// Consumer-only strings; source metadata and upstream error messages are never lookup keys.
enum SourceChangeText: String {
    case checkAuthor = "source_change.check_author"
    case loadWordCount = "source_change.load_word_count"
    case loadInfo = "source_change.load_info"
    case loadToc = "source_change.load_toc"
    case orderBoundary = "source_change.order_boundary"
    case missingSource = "source_change.missing_source"
    case emptyGroupTitle = "source_change.empty_group_title"
    case emptyGroupMessage = "source_change.empty_group_message"
    case refreshList = "source_change.refresh_list"
    case selectedGroup = "source_change.selected_group"
    case allSources = "source_change.all_sources"
    case close = "source_change.close"
    case editSource = "source_change.edit_source"
    case disableSource = "source_change.disable_source"
    case deleteMessage = "source_change.delete_message"
    case filter = "source_change.filter"
    case clearFilter = "source_change.clear_filter"
    case closeFilter = "source_change.close_filter"
    case moreOptions = "source_change.more_options"
    case currentSource = "source_change.current_source"
    case otherSource = "source_change.other_source"
    case namedCurrentSource = "source_change.named_current_source"
    case locateCurrentSource = "source_change.locate_current_source"
    case searching = "source_change.searching"
    case searchProgress = "source_change.search_progress"
    case progress = "source_change.progress"
    case progressValue = "source_change.progress_value"
    case resultList = "source_change.result_list"
    case resultCount = "source_change.result_count"
    case responseTime = "source_change.response_time"
    case source = "source_change.source"
    case author = "source_change.author"
    case bookName = "source_change.book_name"
    case wordCount = "source_change.word_count"
    case sourceAddress = "source_change.source_address"
    case bookAddress = "source_change.book_address"
    case like = "source_change.like"
    case dislike = "source_change.dislike"
    case namedLike = "source_change.named_like"
    case namedDislike = "source_change.named_dislike"
    case liked = "source_change.liked"
    case notLiked = "source_change.not_liked"
    case disliked = "source_change.disliked"
    case notDisliked = "source_change.not_disliked"
    case unrated = "source_change.unrated"
    case likeHint = "source_change.like_hint"
    case unlikeHint = "source_change.unlike_hint"
    case dislikeHint = "source_change.dislike_hint"
    case undislikeHint = "source_change.undislike_hint"
    case ratingUnavailable = "source_change.rating_unavailable"
    case typeTitle = "source_change.type_title"
    case typeMessage = "source_change.type_message"
    case loadingToc = "source_change.loading_toc"
    case loadingContent = "source_change.loading_content"
    case replacingContent = "source_change.replacing_content"
    case cannotCancel = "source_change.cannot_cancel"
    case cancelLoading = "source_change.cancel_loading"
    case closeToc = "source_change.close_toc"
    case chapterList = "source_change.chapter_list"
    case suggestedChapter = "source_change.suggested_chapter"
    case replaceChapterHint = "source_change.replace_chapter_hint"
    case separator = "source_change.separator"

    var value: String {
        let language = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        let fallback = language.hasPrefix("zh") ? translations.zh : translations.en
        return Bundle.main.localizedString(forKey: rawValue, value: fallback, table: nil)
    }

    func format(_ arguments: CVarArg...) -> String {
        String(format: value, locale: Locale.current, arguments: arguments)
    }

    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: separator.value)
    }

    private var translations: (en: String, zh: String) {
        switch self {
        case .checkAuthor: return ("Check by author", "校验作者")
        case .loadWordCount: return ("Load word count", "加载字数")
        case .loadInfo: return ("Load book detail", "加载详情页")
        case .loadToc: return ("Load chapters", "加载目录")
        case .orderBoundary: return ("Source order has reached its limit", "书源排序已到边界")
        case .missingSource: return ("Source not found", "书源不存在")
        case .emptyGroupTitle: return ("No search results", "搜索结果为空")
        case .emptyGroupMessage: return ("No results in group \"%@\". Switch to all groups?", "%@分组搜索结果为空,是否切换到全部分组")
        case .refreshList: return ("Refresh list", "刷新列表")
        case .selectedGroup: return ("Group (%@)", "分组(%@)")
        case .allSources: return ("All Sources", "全部书源")
        case .close: return ("Close", "关闭")
        case .editSource: return ("Edit source", "编辑源")
        case .disableSource: return ("Disable source", "禁用源")
        case .deleteMessage: return ("Are you sure you want to delete this source?\n%@", "是否确认删除？\n%@")
        case .filter: return ("Filter", "筛选")
        case .clearFilter: return ("Clear filter", "清空筛选")
        case .closeFilter: return ("Close filter", "关闭筛选")
        case .moreOptions: return ("More options", "更多选项")
        case .currentSource: return ("Current source", "当前书源")
        case .otherSource: return ("Not the current source", "非当前书源")
        case .namedCurrentSource: return ("Current source: %@", "当前书源：%@")
        case .locateCurrentSource: return ("Locate current source", "定位当前书源")
        case .searching: return ("Searching sources", "正在搜索书源")
        case .searchProgress: return ("Source search progress", "书源搜索进度")
        case .progress: return ("Result %1$d, Progress %2$d / %3$d: %4$@", "结果 %1$d, 当前进度 %2$d / %3$d: %4$@")
        case .progressValue: return ("Searched %1$d of %2$d sources, %3$d results", "已搜索 %1$d / %2$d，结果 %3$d")
        case .resultList: return ("Source search results", "换源搜索结果")
        case .resultCount: return ("%d results", "%d 个结果")
        case .responseTime: return ("Response time: %lld ms", "响应时间：%lld ms")
        case .source: return ("Source: %@", "书源：%@")
        case .author: return ("Author: %@", "作者：%@")
        case .bookName: return ("Book: %@", "书名：%@")
        case .wordCount: return ("Chapter word count: %@", "章节字数：%@")
        case .sourceAddress: return ("Source address: %@", "书源地址：%@")
        case .bookAddress: return ("Book address: %@", "书籍地址：%@")
        case .like: return ("Like source", "赞")
        case .dislike: return ("Dislike source", "踩")
        case .namedLike: return ("Like source: %@", "赞：%@")
        case .namedDislike: return ("Dislike source: %@", "踩：%@")
        case .liked: return ("Liked", "已赞")
        case .notLiked: return ("Not liked", "未赞")
        case .disliked: return ("Disliked", "已踩")
        case .notDisliked: return ("Not disliked", "未踩")
        case .unrated: return ("Not rated", "未评分")
        case .likeHint: return ("Like this source", "为此书源点赞")
        case .unlikeHint: return ("Remove like", "点按取消赞")
        case .dislikeHint: return ("Dislike this source", "为此书源点踩")
        case .undislikeHint: return ("Remove dislike", "点按取消踩")
        case .ratingUnavailable: return ("Rating unavailable", "评分不可用")
        case .typeTitle: return ("Different types of books", "书籍类型不一样")
        case .typeMessage: return ("Confirm source change?", "是否确认换源")
        case .loadingToc: return ("Loading chapters", "正在加载目录")
        case .loadingContent: return ("Loading chapter content", "正在加载正文")
        case .replacingContent: return ("Replacing chapter content", "正在替换正文")
        case .cannotCancel: return ("Cannot cancel while saving", "正在保存，暂不可取消")
        case .cancelLoading: return ("Cancel loading", "取消加载")
        case .closeToc: return ("Close chapter list", "关闭目录")
        case .chapterList: return ("Chapters from selected source", "所选书源目录")
        case .suggestedChapter: return ("Suggested chapter", "当前建议章节")
        case .replaceChapterHint: return ("Replace the current chapter with this chapter", "使用此章节替换当前正文")
        case .separator: return (", ", "，")
        }
    }
}
