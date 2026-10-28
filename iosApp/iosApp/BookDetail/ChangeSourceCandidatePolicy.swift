import Foundation
import SQLite3
import shared

enum ChangeSourceCandidatePolicy {
    private struct RankedCandidate {
        let candidate: BookSourceChangeCandidate
        let inputIndex: Int
        let bookScore: Int
        let sourceScore: Int
        let chapterNumber: Int
        let wordCount: Int
        let sourceOrder: Int
    }

    private static let chapterNumberPattern = try? NSRegularExpression(pattern: #"^\[([0-9]+)]"#)
    private static let authorPattern = #"^\s*作\s*者[:：\s]+|\s+著"#

    @MainActor
    static func ordered(
        _ candidates: [BookSourceChangeCandidate],
        query: String,
        checkAuthor: Bool,
        author: String,
        loadWordCount: Bool,
        ratings: ChangeSourceRatingStore,
        sourceOrders: [String: Int],
        liveMatches: Set<String> = []
    ) -> [BookSourceChangeCandidate] {
        let screenKey = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // ChangeBookSourceViewModel.initData removes AppPattern.authorRegex from the requested author.
        let expectedAuthor = author.replacingOccurrences(
            of: authorPattern, with: "", options: .regularExpression)
        var sourceScores: [String: Int] = [:]
        let ranked: [RankedCandidate] = candidates.enumerated().compactMap { index, candidate in
            // Retained rows follow changeSourceSearch's LIKE; new rows use searchSuccess's separate admission.
            guard
                screenKey.isEmpty || liveMatches.contains(candidate.bookUrl)
                    || matches(candidate.sourceName, query: screenKey)
                    || candidate.latestChapterTitle.map({ matches($0, query: screenKey) }) == true
            else { return nil }
            guard !checkAuthor || matches(candidate.author, query: expectedAuthor) else { return nil }
            let sourceScore: Int
            if let cached = sourceScores[candidate.sourceUrl] {
                sourceScore = cached
            } else {
                sourceScore = ratings.sourceScore(sourceURL: candidate.sourceUrl)
                sourceScores[candidate.sourceUrl] = sourceScore
            }
            return RankedCandidate(
                candidate: candidate,
                inputIndex: index,
                bookScore: ratings.bookScore(candidate),
                sourceScore: sourceScore,
                chapterNumber: loadWordCount ? chapterNumber(candidate.chapterWordCountText) : -1,
                wordCount: loadWordCount ? Int(candidate.chapterWordCount) : -1,
                sourceOrder: sourceOrders[candidate.sourceUrl] ?? 0
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.bookScore != rhs.bookScore { return lhs.bookScore > rhs.bookScore }
            if lhs.sourceScore != rhs.sourceScore { return lhs.sourceScore > rhs.sourceScore }
            if loadWordCount {
                let lhsHasContent = lhs.wordCount > 1000
                let rhsHasContent = rhs.wordCount > 1000
                if lhsHasContent != rhsHasContent { return lhsHasContent }
                if lhs.chapterNumber != rhs.chapterNumber { return lhs.chapterNumber > rhs.chapterNumber }
                if lhs.wordCount != rhs.wordCount { return lhs.wordCount > rhs.wordCount }
            }
            if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
            return lhs.inputIndex < rhs.inputIndex
        }.map(\.candidate)
    }

    private static func chapterNumber(_ text: String?) -> Int {
        guard let text, let pattern = chapterNumberPattern,
            let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text),
            let number = Int32(text[range])
        else { return -1 }
        return Int(number)
    }

    private static func matches(_ value: String, query: String) -> Bool {
        sqlite3_strlike("%" + query + "%", value, 0) == 0
    }
}
