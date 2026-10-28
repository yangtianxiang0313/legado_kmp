import Foundation
import shared

enum BookSourceGroupManagementText {
    static let title = NSLocalizedString("source.group.manage", value: "分组管理", comment: "Legado group_manage")
    static let add = NSLocalizedString("source.group.add", value: "添加分组", comment: "Legado add_group")
    static let edit = NSLocalizedString("source.group.edit", value: "编辑分组", comment: "Legado group_edit")
    static let name = NSLocalizedString("source.group.name", value: "分组名称", comment: "Legado group_name")
    static let confirm = NSLocalizedString("source.group.confirm", value: "确认", comment: "Legado ok")
    static let emptyName = NSLocalizedString(
        "source.group.empty_name", value: "分组名称不能为空", comment: "Invalid new group")
    static let noUngroupedSources = NSLocalizedString(
        "source.group.no_ungrouped_sources", value: "没有未分组书源，未新增分组", comment: "addGroup returned no sources")
    static let missingGroup = NSLocalizedString(
        "source.group.missing_group", value: "分组已不存在，未修改书源", comment: "Group mutation returned no sources")
}

enum BookSourceGroupManagementGroups {
    // SourceGroups / AppPattern.splitGroupRegex. Kotlin trim excludes U+0085,
    // but includes U+001C...U+001F unlike Foundation's whitespace set.
    static func trim(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let start = scalars.firstIndex { !isWhitespace($0) } ?? scalars.endIndex
        let end = scalars[start...].lastIndex { !isWhitespace($0) }
        guard let end else { return "" }
        return String(scalars[start...end])
    }

    static func split(_ value: String?) -> [String] {
        (value ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map(trim).filter { !$0.isEmpty }
    }

    static func names(in sources: [BookSource]) -> [String] {
        var seen = Set<[UInt16]>()
        let names = sources.flatMap { split($0.bookSourceGroup) }.filter { seen.insert(Array($0.utf16)).inserted }
        let locale = Locale(identifier: "zh_Hans_CN")
        return names.enumerated().sorted { left, right in
            let order = left.element.compare(right.element, options: [], range: nil, locale: locale)
            return order == .orderedSame ? left.offset < right.offset : order == .orderedAscending
        }.map(\.element)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x001C...0x0020, 0x00A0, 0x1680,
            0x2000...0x200A, 0x2028...0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}

enum BookSourceGroupManagementChange {
    case add(String)
    case rename(old: String, new: String)
    case delete(String)

    var emptyResultMessage: String {
        switch self {
        case .add: return BookSourceGroupManagementText.noUngroupedSources
        case .rename, .delete: return BookSourceGroupManagementText.missingGroup
        }
    }

    @MainActor
    func save(using screen: SourceManagementScreenAdapter) async throws -> [BookSource] {
        switch self {
        case .add(let name):
            return try await screen.addGroup(group: name)
        case .rename(let old, let new):
            let name = BookSourceGroupManagementGroups.trim(new)
            return try await screen.renameGroup(oldGroup: old, newGroup: name.isEmpty ? nil : name)
        case .delete(let name):
            return try await screen.deleteGroup(group: name)
        }
    }
}
