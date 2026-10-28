import AVFoundation
import WebKit

@MainActor
final class RssArticleSpeechController: NSObject, AVSpeechSynthesizerDelegate {
    var canSpeak: () -> Bool = { false }
    var onChange: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var requestID: UUID?
    private var utterance: AVSpeechUtterance?

    var isPlaying: Bool { requestID != nil || (utterance != nil && !synthesizer.isPaused) }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ webView: WKWebView) {
        guard canSpeak() else { return }
        if requestID != nil {
            stop()
        } else if utterance != nil || synthesizer.isSpeaking || synthesizer.isPaused {
            if synthesizer.isPaused { synthesizer.continueSpeaking() } else { synthesizer.pauseSpeaking(at: .word) }
            onChange?()
        } else {
            let token = UUID()
            requestID = token
            onChange?()
            webView.evaluateJavaScript("document.body.innerText || document.body.textContent || ''") { [weak self] result, _ in
                guard let self, self.requestID == token, self.canSpeak() else { return }
                self.requestID = nil
                guard let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.onChange?()
                    return
                }
                let next = AVSpeechUtterance(string: text)
                next.rate = AVSpeechUtteranceDefaultSpeechRate
                next.voice = AVSpeechSynthesisVoice(language: "zh-CN")
                self.utterance = next
                self.synthesizer.speak(next)
                self.onChange?()
            }
        }
    }

    func stop() {
        requestID = nil
        utterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        onChange?()
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish current: AVSpeechUtterance) {
        guard utterance === current else { return }
        utterance = nil
        onChange?()
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel current: AVSpeechUtterance) {
        guard utterance === current else { return }
        utterance = nil
        onChange?()
    }
}
