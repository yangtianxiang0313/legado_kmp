import Foundation
import shared

@MainActor
final class ChangeSourceRatingStore {
    private struct State {
        var books: [String: Int]
        var sources: [String: Int]
    }

    private static let storageKey = "legado.ios.changeSource.ratings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bookScore(_ candidate: BookSourceChangeCandidate) -> Int {
        guard let key = bookKey(candidate) else { return 0 }
        return validBookScore(readState().books[key])
    }

    func sourceScore(sourceURL: String) -> Int {
        readState().sources[sourceURL] ?? 0
    }

    func setScore(_ score: Int, for candidate: BookSourceChangeCandidate) {
        guard (-1...1).contains(score), let key = bookKey(candidate) else { return }
        // Read at the mutation boundary so separate main-actor stores cannot overwrite stale snapshots.
        var state = readState()
        let previous = validBookScore(state.books[key])
        guard score != previous else { return }
        let sourceURL = candidate.sourceUrl
        let (total, overflow) = (state.sources[sourceURL] ?? 0).addingReportingOverflow(score - previous)
        guard !overflow else { return }
        if score == 0 {
            state.books.removeValue(forKey: key)
        } else {
            state.books[key] = score
        }
        if total == 0 {
            state.sources.removeValue(forKey: sourceURL)
        } else {
            state.sources[sourceURL] = total
        }
        if state.books.isEmpty && state.sources.values.allSatisfy({ $0 == 0 }) {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            // Both levels of scoring are committed by one property-list dictionary write.
            defaults.set(["books": state.books, "sources": state.sources], forKey: Self.storageKey)
        }
    }

    func removeSource(_ sourceURL: String) {
        var state = readState()
        let keys = state.books.keys.filter { key in
            guard let data = Data(base64Encoded: key), let fields = try? JSONDecoder().decode([String].self, from: data)
            else { return false }
            return fields.first == sourceURL
        }
        guard !keys.isEmpty || state.sources[sourceURL] != nil else { return }
        for key in keys { state.books.removeValue(forKey: key) }
        state.sources.removeValue(forKey: sourceURL)
        if state.books.isEmpty && state.sources.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(["books": state.books, "sources": state.sources], forKey: Self.storageKey)
        }
    }

    private func readState() -> State {
        let dictionary = defaults.dictionary(forKey: Self.storageKey)
        return State(
            books: dictionary?["books"] as? [String: Int] ?? [:],
            sources: dictionary?["sources"] as? [String: Int] ?? [:]
        )
    }

    private func validBookScore(_ score: Int?) -> Int {
        guard let score, (-1...1).contains(score) else { return 0 }
        return score
    }

    private func bookKey(_ candidate: BookSourceChangeCandidate) -> String? {
        // A JSON tuple is reversible and does not collide when a field contains a separator.
        let fields = [candidate.sourceUrl, candidate.displayName, candidate.author]
        return (try? JSONEncoder().encode(fields))?.base64EncodedString()
    }
}
