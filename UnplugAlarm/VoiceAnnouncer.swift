//
//  VoiceAnnouncer.swift
//  Unplug Alarm
//
//  Speaks the alarm warning with AVSpeechSynthesizer.
//

import AVFoundation

// Only used from the main thread.
final class VoiceAnnouncer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private var currentUtterance: AVSpeechUtterance?
    private var fallbackTimer: Timer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speaks `text`; `completion` runs on the main queue when finished or stopped.
    /// A fallback timer guarantees the completion runs even if the delegate
    /// callback never arrives (e.g. speech fails silently).
    func speak(_ text: String, language: AlarmLanguage, completion: @escaping () -> Void) {
        stop()
        self.completion = completion

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.voiceLanguageCode)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.volume = 1.0
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        currentUtterance = utterance
        synthesizer.speak(utterance)

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.synthesizer.stopSpeaking(at: .immediate)
            self?.finish()
        }
    }

    /// Stops speaking without running the completion.
    func stop() {
        completion = nil
        currentUtterance = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func finish() {
        currentUtterance = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        let done = completion
        completion = nil
        done?()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded(utterance) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded(utterance) }
    }

    /// Ignores callbacks for utterances that were already replaced or stopped.
    private func utteranceEnded(_ utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        finish()
    }
}
