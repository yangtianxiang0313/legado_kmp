import Foundation
import shared

/// The reader adapter keeps screen bindings; this client translates speech commands to shared APIs.
final class ReaderReadAloudClient {
    private let runtimeFacade: () -> RuntimeFacade?

    init(runtimeFacade: @escaping () -> RuntimeFacade?) { self.runtimeFacade = runtimeFacade }

    func startReadAloud(
        bookURL: String, chapterIndex: Int, blocks: [ReaderContentBlock], startBlockIndex: Int,
        startTextOffset: Int, preferBackgroundPlayback: Bool, ttsEngine: String?, startPaused: Bool
    ) async throws {
        let request = ReadAloudRequest(
            bookUrl: bookURL, chapterIndex: Int32(chapterIndex),
            blocks: blocks.compactMap { block -> ReadAloudBlock? in
                guard block.type == .heading || block.type == .paragraph else { return nil }
                return ReadAloudBlock(blockIndex: block.blockIndex, text: block.text)
            },
            startBlockIndex: Int32(startBlockIndex), startTextOffset: Int32(startTextOffset),
            preferBackgroundPlayback: preferBackgroundPlayback, ttsEngine: ttsEngine, startPaused: startPaused)
        try await requiredFacade().startReadAloudAsync(request: request)
    }

    func pauseReadAloud() async throws { try await requiredFacade().pauseReadAloudAsync() }
    func resumeReadAloud() async throws { try await requiredFacade().resumeReadAloudAsync() }
    func stopReadAloud() async throws { try await requiredFacade().stopReadAloudAsync() }
    func skipReadAloudToPreviousBlock() async throws { try await requiredFacade().skipReadAloudToPreviousBlockAsync() }
    func skipReadAloudToNextBlock() async throws { try await requiredFacade().skipReadAloudToNextBlockAsync() }

    func updateReadAloudSpeechRate(followSystem: Bool, value: Float) async throws {
        try await requiredFacade().updateReadAloudSpeechRateAsync(
            setting: ReadAloudSpeechRateSetting(followSystem: followSystem, value: value))
    }

    func setReadAloudTimer(minutes: Int) async throws { try await requiredFacade().setReadAloudTimerAsync(minutes: Int32(minutes)) }
    func setReadAloudBackgroundPlayback(enabled: Bool) async throws {
        try await requiredFacade().setReadAloudBackgroundPlaybackAsync(enabled: enabled)
    }
    func advanceReadAloudToNextBlock() async throws { try await requiredFacade().advanceReadAloudToNextBlockAsync() }
    func updateReadAloudCurrentRange(start: Int, end: Int) async throws {
        try await requiredFacade().updateReadAloudCurrentRangeAsync(start: Int32(start), end: Int32(end))
    }
    func updateReadAloudPlaybackState(isInBackground: Bool) async throws {
        try await requiredFacade().updateReadAloudPlaybackStateAsync(isInBackground: isInBackground)
    }
    func failReadAloud(message: String) async throws { try await requiredFacade().failReadAloudAsync(message: message) }

    private func requiredFacade() throws -> RuntimeFacade {
        guard let facade = runtimeFacade() else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        return facade
    }
}
