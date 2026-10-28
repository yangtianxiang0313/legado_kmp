import Foundation
import shared

@MainActor
protocol BookSourceDebugProviding: AnyObject {
    func loadCheckKeyword() async throws -> String
    func loadKinds(refresh: Bool) async throws -> [ExploreKind]
    func run(query: String, onLog: @escaping @Sendable (BookSourceDebugLogLine) -> Void) async throws -> BookSourceDebugReport
}

@MainActor
final class BookSourceDebugScreenAdapter: BookSourceDebugProviding {
    private let sourceURL: String
    private let sourceEditor: BookSourceEditingProviding

    init(sourceURL: String, sourceEditor: BookSourceEditingProviding) {
        self.sourceURL = sourceURL
        self.sourceEditor = sourceEditor
    }

    func loadCheckKeyword() async throws -> String {
        let payload = try await sourceEditor.exportSource(sourceUrl: sourceURL)
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw NSError(domain: "BookSourceDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: "书源数据错误"])
        }
        let rule = root["ruleSearch"] as? [String: Any]
        let word = rule?["checkKeyWord"] as? String ?? ""
        return word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的" : word
    }

    func loadKinds(refresh: Bool) async throws -> [ExploreKind] {
        let facade = try SharedRuntime.discoveryFacade().get()
        let kinds = try await facade.loadExploreKindsAsync(sourceUrl: sourceURL, forceRefresh: refresh)
        try Task.checkCancellation()
        return kinds
    }

    func run(
        query: String, onLog: @escaping @Sendable (BookSourceDebugLogLine) -> Void
    ) async throws -> BookSourceDebugReport {
        let facade = try SharedRuntime.bookSourceDebugFacade().get()
        return try await SharedCancellableAsync.value { completion in
            facade.debugSourceRequest(sourceUrl: sourceURL, keyword: query, onLog: onLog) { report, error in
                if let error {
                    completion(
                        nil,
                        NSError(
                            domain: "BookSourceDebug", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: error.message]))
                } else if let report {
                    completion(report, nil)
                } else {
                    completion(nil, CancellationError())
                }
            }
        }
    }

    // Fixed debugHelp.md content, independent of the editable query and raw response.
    static let helpSections: [(title: String, example: String)] = [
        ("调试搜索>>输入关键字，如：", "系统"),
        ("调试发现>>输入发现URL，如：", "月票榜::https://www.qidian.com/rank/yuepiao?page={{page}}"),
        ("调试详情页>>输入详情页URL，如：", "https://m.qidian.com/book/1015609210"),
        ("调试目录页>>输入目录页URL，如：", "++https://www.zhaishuyuan.com/read/30394"),
        ("调试正文页>>输入正文页URL，如：", "--https://www.zhaishuyuan.com/chapter/30394/20940996"),
    ]

    static var helpText: String {
        "书源调试\n\n" + helpSections.map { $0.title + "\n" + $0.example }.joined(separator: "\n\n")
    }
}
