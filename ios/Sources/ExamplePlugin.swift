import AVFoundation
import SwiftRs
import Tauri

#if canImport(UIKit)
    import UIKit
#endif

// ──────────────────────────────────────────────────────────────────────────────
// Args
// ──────────────────────────────────────────────────────────────────────────────
class SpeakArgs: Decodable {
    let text: String
    let language: String?  // e.g. "fa-IR" or "fa"
    let voiceIdentifier: String?
    let rate: Double?  // 0.0 ... 1.0+ (AVSpeechUtteranceDefaultSpeechRate ~ 0.5)
    let pitch: Double?  // 0.5 ... 2.0 (1.0 = default)
    let volume: Double?  // 0.0 ... 1.0
}

enum SpeakError: Error {
    case speakerNotReady
    case invalidArgs(String)
}

// ──────────────────────────────────────────────────────────────────────────────
// Speaker
// ─────────────────────────────────────────────────────────────────────────────-
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    // Keep synthesizer alive across calls
    private static let synth = AVSpeechSynthesizer()
    private var currentInvoke: Invoke?

    override init() {
        super.init()
        Self.synth.delegate = self
    }

    // Simple voice selection logic:
    // 1) by identifier, 2) exact language, 3) base language, 4) nil (system default)
    private func selectVoice(language: String?, identifier: String?) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()

        if let id = identifier, let v = voices.first(where: { $0.identifier == id }) {
            return v
        }

        if let lang = language?.lowercased() {
            // exact tag match
            if let v = voices.first(where: { $0.language.lowercased() == lang }) { return v }
            // base language match
            if let dash = lang.firstIndex(of: "-") {
                let base = String(lang[..<dash])
                if let v = voices.first(where: {
                    $0.language.lowercased().hasPrefix(base + "-")
                        || $0.language.lowercased() == base
                }) {
                    return v
                }
            }
        }

        return nil  // let system choose
    }

    // iOS needs an audio session; macOS doesn’t.
    private func prepareAudioSessionIfNeeded() {
        #if canImport(UIKit)
            do {
                let session = AVAudioSession.sharedInstance()
                // .spokenAudio is nice; .playback also works. Duck others so guidance doesn't blast.
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
            } catch {
                print("AVAudioSession setup failed: \(error)")
            }
        #endif
    }

    func speak(_ args: SpeakArgs, invoke: Invoke) {
        DispatchQueue.main.async {
            self.prepareAudioSessionIfNeeded()

            let utter = AVSpeechUtterance(string: args.text)
            if let v = self.selectVoice(language: args.language, identifier: args.voiceIdentifier) {
                utter.voice = v
                print("TTS: using voice \(v.name) [\(v.identifier)] (\(v.language))")
            } else {
                // System default; still helpful to log desired language if provided
                print(
                    "TTS: no matching voice; letting system choose (desired=\(args.language ?? "nil"))"
                )
            }

            // Apply prosody (use sensible defaults if nil)
            if let r = args.rate {
                utter.rate = Float(r)
            } else {
                utter.rate = 0.5
            }
            if let p = args.pitch { utter.pitchMultiplier = Float(p) }
            if let v = args.volume { utter.volume = Float(v) }

            self.currentInvoke = invoke
            Self.synth.speak(utter)
        }
    }

    func stop(_ invoke: Invoke) {
        DispatchQueue.main.async {
            Self.synth.stopSpeaking(at: .immediate)
            invoke.resolve()
        }
    }

    func isSpeaking(_ invoke: Invoke) {
        let speaking = Self.synth.isSpeaking
        invoke.resolve(speaking)
    }

    // MARK: - AVSpeechSynthesizerDelegate
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        print("TTS: finished successfully")
        currentInvoke?.resolve()
        currentInvoke = nil
    }
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        print("TTS: cancelled")
        currentInvoke?.reject("cancelled")
        currentInvoke = nil
    }
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        print("TTS: started")
    }
}

// ──────────────────────────────────────────────────────────────────────────────
class TTSPlugin: Plugin {
    private static var speaker = Speaker()

    // speak({ text, language?, voiceIdentifier?, rate?, pitch?, volume? })
    @objc public func speak(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(SpeakArgs.self)
        Self.speaker.speak(args, invoke: invoke)
    }

    @objc public func stop(_ invoke: Invoke) {
        Self.speaker.stop(invoke)
    }

    @objc public func is_speaking(_ invoke: Invoke) {
        Self.speaker.isSpeaking(invoke)
    }

    // list_voices(): returns array of {name, language, quality, identifier}
    @objc public func list_voices(_ invoke: Invoke) {
        let vs = AVSpeechSynthesisVoice.speechVoices().map { v in
            [
                "name": v.name,
                "language": v.language,
                "identifier": v.identifier,
                "quality": v.quality.rawValue,
            ] as [String: Any]
        }
        invoke.resolve(vs)
    }
}

@_cdecl("init_plugin_tts")
func initPlugin() -> Plugin {
    return TTSPlugin()
}
