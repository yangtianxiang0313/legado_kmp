import Foundation
import shared

@MainActor
final class SourceImportPreviewState {
    enum PreservedValue: String, CaseIterable {
        case name, group, enabled

        var title: String {
            switch self {
            case .name: return SourceImportPreviewText.keepName
            case .group: return SourceImportPreviewText.keepGroup
            case .enabled: return SourceImportPreviewText.keepEnabled
            }
        }

        var identifier: String { "sourceImport.preview.keep.\(rawValue)" }
        fileprivate var defaultsKey: String { "io.legado.kmp.sourceImport.preview.keep.\(rawValue).v1" }
    }

    private(set) var candidates: [SourceImportCandidate]
    private(set) var selections: [Bool]
    private(set) var duplicateCount: Int
    private(set) var invalidCount: Int
    var groupName: String?
    var appendGroup = false
    private let defaults: UserDefaults
    private var preservedValues: [PreservedValue: Bool]

    init(preview: SourceImportPreview, defaults: UserDefaults = .standard) {
        candidates = preview.candidates
        selections = preview.candidates.map(\.selectedByDefault)
        duplicateCount = Int(preview.duplicateCount)
        invalidCount = Int(preview.invalidCount)
        self.defaults = defaults
        preservedValues = Dictionary(
            uniqueKeysWithValues: PreservedValue.allCases.map {
                ($0, defaults.bool(forKey: $0.defaultsKey))
            })
    }

    var selectedCount: Int { selections.filter { $0 }.count }
    var isAllSelected: Bool { !selections.isEmpty && selections.allSatisfy { $0 } }

    func receivePreparedPreview(_ preview: SourceImportPreview) {
        candidates = preview.candidates
        selections = preview.candidates.map(\.selectedByDefault)
        duplicateCount = Int(preview.duplicateCount)
        invalidCount = Int(preview.invalidCount)
    }

    var selectionTitle: String {
        SourceImportPreviewText.selectionCount(selected: selectedCount, total: candidates.count, all: isAllSelected)
    }

    var selectedSources: [BookSource] {
        candidates.indices.compactMap { selections[$0] ? candidates[$0].source : nil }
    }

    var options: SourceImportOptions {
        let group = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SourceImportOptions(
            keepName: isPreserved(.name),
            keepGroup: isPreserved(.group),
            keepEnabled: isPreserved(.enabled),
            groupName: group?.isEmpty == false ? group : nil,
            appendGroup: appendGroup
        )
    }

    var groupTitle: String {
        guard let group = options.groupName else { return SourceImportPreviewText.customGroup }
        return (appendGroup ? "+" : "") + SourceImportPreviewText.groupTitle(group)
    }

    func isPreserved(_ value: PreservedValue) -> Bool { preservedValues[value] ?? false }

    func togglePreserved(_ value: PreservedValue) {
        let enabled = !isPreserved(value)
        preservedValues[value] = enabled
        defaults.set(enabled, forKey: value.defaultsKey)
    }

    func toggleSelection(at index: Int) {
        guard selections.indices.contains(index) else { return }
        selections[index].toggle()
    }

    func indices(isNew: Bool) -> [Int] {
        candidates.indices.filter { isNew ? candidates[$0].isNew : candidates[$0].isUpdate }
    }

    func areSelected(_ indices: [Int]) -> Bool {
        !indices.isEmpty && indices.allSatisfy { selections.indices.contains($0) && selections[$0] }
    }

    func toggleSelection(in indices: [Int]) {
        let selected = !areSelected(indices)
        for index in indices where selections.indices.contains(index) { selections[index] = selected }
    }

    func replaceCandidate(at index: Int, with candidate: SourceImportCandidate) {
        guard candidates.indices.contains(index) else { return }
        // The parser compared the edited URL with the latest local source; keep the user's check state.
        candidates[index] = candidate
    }
}

enum SourceImportPreviewText {
    static let title = text("title", "导入书源")
    static let more = text("more", "更多")
    static let new = text("new", "新增")
    static let update = text("update", "更新")
    static let existing = text("existing", "已有")
    static let open = text("open", "打开")
    static let selectNew = text("select_new", "选中新增源")
    static let selectUpdate = text("select_update", "选中更新源")
    static let selectAll = text("select_all", "全选")
    static let keepName = text("keep_name", "保留原名")
    static let keepGroup = text("keep_group", "保留分组")
    static let keepEnabled = text("keep_enabled", "保留启用状态")
    static let customGroup = text("custom_group", "自定义源分组")
    static let groupPrompt = text("group_prompt", "输入自定义源分组名称")
    static let groupName = text("group_name", "分组名称")
    static let appendGroup = text("append_group", "添加分组")
    static let empty = text("empty", "没有可导入的书源")
    static let draft = text("draft", "书源 JSON")
    static let draftPayload = text("draft_payload", "书源 JSON 草稿")
    static let singleSourceRequired = text("single_source_required", "草稿必须包含且仅包含一个有效书源。")
    static let saving = text("saving", "正在保存")
    static let parsing = text("parsing", "正在解析")
    static let selected = text("selected", "已选中")
    static let unselected = text("unselected", "未选中")

    static func status(for candidate: SourceImportCandidate) -> String {
        candidate.isNew ? new : (candidate.isUpdate ? update : existing)
    }

    static func selectionCount(selected: Int, total: Int, all: Bool) -> String {
        let format =
            all
            ? text("cancel_selection_count", "取消全选（%d/%d）")
            : text("selection_count", "全选（%d/%d）")
        return String(format: format, locale: Locale.current, selected, total)
    }

    static func groupTitle(_ name: String) -> String {
        String(format: text("group_title", "分组：%@"), locale: Locale.current, name)
    }

    static func ignoredCounts(duplicates: Int, invalid: Int) -> String {
        String(
            format: text("ignored_counts", "原始内容：重复 %d 条，无效 %d 条"),
            locale: Locale.current, duplicates, invalid
        )
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: "source_import.preview.\(key)", value: fallback, table: nil)
    }
}
