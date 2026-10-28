import Foundation
import shared

enum SourceEditorSaveDestination: Equatable {
    case back
    case search
    case debug
    case login
    case sourceVariable
}

@MainActor
final class BookSourceEditorPersistence {
    struct SaveResult {
        let source: BookSource
        let savedPayload: [String: Any]
    }

    private let screen: BookSourceEditingProviding
    private var lastPersistedSourceURL: String?
    private var pendingSourceURLDeletions: Set<String> = []

    init(screen: BookSourceEditingProviding) {
        self.screen = screen
    }

    func makeOutput(payload: Data, autoComplete: Bool) throws -> Data {
        guard autoComplete else { return payload }
        let output = try screen.completeEditorSourcePayload(
            payload: String(decoding: payload, as: UTF8.self), enabled: true)
        return Data(output.utf8)
    }

    // Keep one instance per editor and serialize save requests at the caller.
    func save(payload: Data, originalSourceURL: String?) async throws -> SaveResult {
        let object = try JSONSerialization.jsonObject(with: payload, options: [])
        guard var savedPayload = object as? [String: Any] else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourcePayloadInvalid])
        }
        // Validate before import normalization can replace a blank name or drop an invalid entry.
        guard let name = savedPayload["bookSourceName"] as? String,
            let url = savedPayload["bookSourceUrl"] as? String,
            !BookSourceEditorDraft.isBlank(name), !BookSourceEditorDraft.isBlank(url)
        else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: "名称和 URL 不能为空"])
        }
        if savedPayload["enabledCookieJar"] is NSNull { savedPayload["enabledCookieJar"] = false }
        let payloadString = String(
            decoding: try JSONSerialization.data(withJSONObject: savedPayload, options: [.sortedKeys]), as: UTF8.self)
        let parsed = try await screen.parseSourcePayload(payload: payloadString)
        guard parsed.count == 1, let source = parsed.first else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourcePayloadInvalid])
        }
        let savedSource = try await screen.saveSource(source: source)
        let sourceURL = savedSource.bookSourceUrl
        if let previousURL = lastPersistedSourceURL ?? originalSourceURL, previousURL != sourceURL {
            pendingSourceURLDeletions.insert(previousURL)
        }
        lastPersistedSourceURL = sourceURL
        pendingSourceURLDeletions.remove(sourceURL)
        // Retain unfinished cleanup across retries, including another URL edit.
        for obsoleteURL in pendingSourceURLDeletions.sorted() {
            try await screen.deleteSource(sourceUrl: obsoleteURL)
            pendingSourceURLDeletions.remove(obsoleteURL)
        }
        // This dictionary preserves editor-only keys in this session, not in typed database storage.
        savedPayload["bookSourceUrl"] = sourceURL
        savedPayload["bookSourceName"] = savedSource.bookSourceName
        savedPayload["bookSourceGroup"] = savedSource.bookSourceGroup
        return SaveResult(source: savedSource, savedPayload: savedPayload)
    }
}
