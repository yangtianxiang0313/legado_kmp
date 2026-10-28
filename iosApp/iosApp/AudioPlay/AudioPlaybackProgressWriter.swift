import Foundation

@MainActor
final class AudioPlaybackProgressWriter {
    private var pending: Task<Void, Never>?

    func save(screen: AudioPlayScreenAdapter, bookURL: String, origin: String, chapterURL: String, position: Int32) {
        let prior = pending
        pending = Task {
            await prior?.value
            do {
                try await screen.saveProgress(
                    bookURL: bookURL, origin: origin, chapterURL: chapterURL, position: position)
            } catch {
                SharedRuntime.log("有声阅读进度保存失败")
            }
        }
    }

    func flush() async { await pending?.value }
}
