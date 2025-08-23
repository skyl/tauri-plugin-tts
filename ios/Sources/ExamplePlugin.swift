import AVFoundation
import Tauri
import os

#if canImport(UIKit)
    import UIKit
#endif

// ──────────────────────────────────────────────────────────────────────────────
// Logging: goes to unified logging with subsystem captured by `tauri ios dev`
// ──────────────────────────────────────────────────────────────────────────────
private let DEBUG_TTS = true
private let osLogger = Logger(subsystem: "com.corpora.corpan", category: "TTS")

@inline(__always) private func ttsLog(_ items: Any...) {
    let msg = items.map { "\($0)" }.joined(separator: " ")
    osLogger.info("\(msg, privacy: .public)")
    if DEBUG_TTS { print("[TTS:iOS]", msg) }
}

// ──────────────────────────────────────────────────────────────────────────────
// Args (all optional except text) — stays compatible with Rust side
// ──────────────────────────────────────────────────────────────────────────────
class SpeakArgs: Decodable {
    let text: String
    let language: String?  // e.g. "fa-IR" or "fa"
    let voiceIdentifier: String?  // force a specific voice if you know it
    let rate: Double?  // AVSpeechUtterance rate (0.0..1.0+, default ~0.5)
    let pitch: Double?  // 0.5..2.0 (1.0 default)
    let volume: Double?  // 0.0..1.0
}

enum SpeakError: Error {
    case speakerNotReady
    case invalidArgs(String)
}

// ──────────────────────────────────────────────────────────────────────────────
// Speaker
// ──────────────────────────────────────────────────────────────────────────────
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    // Keep synthesizer alive across calls
    private static let synth = AVSpeechSynthesizer()
    private var currentInvoke: Invoke?

    override init() {
        super.init()
        Self.synth.delegate = self
        ttsLog("Speaker init; voices available:", AVSpeechSynthesisVoice.speechVoices().count)
    }

    // Normalize BCP-47 tags: lowercase + underscores -> hyphens
    private func normalizeTag(_ tag: String) -> String {
        return tag.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    // Prefer "fa-IR" when only "fa" is provided
    private func exactHint(for want: String) -> String? {
        switch want {
        case "fa": return "fa-ir"
        default: return nil
        }
    }

    // Voice selection logic:
    // 1) by identifier
    // 2) exact language (normalized)
    // 3) base language match (normalized, prefix or exact)
    // 4) nil (system default; we’ll still try AVSpeechSynthesisVoice(language:))
    private func selectVoice(language: String?, identifier: String?) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        ttsLog(
            "selectVoice: voices:", voices.count,
            "| want language:", language ?? "nil",
            "| want id:", identifier ?? "nil"
        )

        if let id = identifier, let v = voices.first(where: { $0.identifier == id }) {
            ttsLog("selectVoice: matched by identifier:", v.name, v.language, v.identifier)
            return v
        }

        guard let langRaw = language, !langRaw.isEmpty else {
            ttsLog("selectVoice: no language provided; returning nil (system default)")
            return nil
        }

        let want = normalizeTag(langRaw)

        // exact hint first (e.g. fa -> fa-ir)
        if let hint = exactHint(for: want),
            let v = voices.first(where: { $0.language.lowercased() == hint })
        {
            ttsLog("selectVoice: matched hint", hint, "->", v.name, v.language)
            return v
        }

        // exact language
        if let v = voices.first(where: { $0.language.lowercased() == want }) {
            ttsLog("selectVoice: matched exact language:", want, "->", v.name, v.language)
            return v
        }

        // base language
        let base = want.split(separator: "-").first.map(String.init) ?? want
        if let v = voices.first(where: {
            let l = $0.language.lowercased()
            return l == base || l.hasPrefix(base + "-")
        }) {
            ttsLog("selectVoice: matched base language:", base, "->", v.name, v.language)
            return v
        }

        ttsLog("selectVoice: no voice matched for", want)
        return nil
    }

    // iOS needs an audio session; macOS doesn’t.
    private func prepareAudioSessionIfNeeded() {
        #if canImport(UIKit)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
                ttsLog("AudioSession set to playback/spokenAudio; active=true")
            } catch {
                ttsLog("AVAudioSession setup failed:", error.localizedDescription)
            }
        #endif
    }

    func speak(_ args: SpeakArgs, invoke: Invoke) {
        DispatchQueue.main.async {
            ttsLog(
                "speak()",
                "| lang:", args.language ?? "nil",
                "| id:", args.voiceIdentifier ?? "nil",
                "| rate:", args.rate ?? -1,
                "| pitch:", args.pitch ?? -1,
                "| volume:", args.volume ?? -1
            )

            self.prepareAudioSessionIfNeeded()

            // Interrupt any current speech
            if Self.synth.isSpeaking {
                ttsLog("Synth currently speaking; stopping immediately.")
                Self.synth.stopSpeaking(at: .immediate)
            }

            let utter = AVSpeechUtterance(string: args.text)

            // 1) Try explicit installed voice
            if let v = self.selectVoice(language: args.language, identifier: args.voiceIdentifier) {
                utter.voice = v
                ttsLog("Using installed voice:", v.name, v.language, "[", v.identifier, "]")
            }
            // 2) Else attempt model by language tag (helps when not enumerated)
            else if let lang = args.language {
                let normalized = self.normalizeTag(lang)
                if let model = AVSpeechSynthesisVoice(language: normalized) {
                    utter.voice = model
                    ttsLog(
                        "Using AVSpeechSynthesisVoice(language:)", normalized, "->", model.name,
                        model.language)
                } else {
                    ttsLog("No AVSpeechSynthesisVoice for", normalized, "— using system default")
                }
            } else {
                ttsLog("No language/identifier; system default voice will be used.")
            }

            // Prosody
            if let r = args.rate {
                utter.rate = Float(r)
            } else {
                utter.rate = AVSpeechUtteranceDefaultSpeechRate
            }
            if let p = args.pitch { utter.pitchMultiplier = Float(p) }
            if let v = args.volume { utter.volume = Float(v) }

            ttsLog(
                "Prosody -> rate:", utter.rate, "pitch:", utter.pitchMultiplier, "volume:",
                utter.volume)

            self.currentInvoke = invoke
            Self.synth.speak(utter)
            ttsLog("synth.speak() queued.")

            // Fire-and-forget; resolve now (delegate will also resolve on finish).
            invoke.resolve()
        }
    }

    func stop(_ invoke: Invoke) {
        DispatchQueue.main.async {
            ttsLog("stop()")
            Self.synth.stopSpeaking(at: .immediate)
            invoke.resolve()
        }
    }

    func isSpeaking(_ invoke: Invoke) {
        let speaking = Self.synth.isSpeaking
        ttsLog("isSpeaking ->", speaking)
        invoke.resolve(speaking)
    }

    // MARK: - AVSpeechSynthesizerDelegate
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        ttsLog("delegate didStart")
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        ttsLog("delegate didFinish")
        currentInvoke?.resolve()
        currentInvoke = nil
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        ttsLog("delegate didCancel")
        currentInvoke?.reject("cancelled")
        currentInvoke = nil
    }
}

// ──────────────────────────────────────────────────────────────────────────────
class TTSPlugin: Plugin {
    private static var speaker = Speaker()

    // speak({ text, language?, voiceIdentifier?, rate?, pitch?, volume? })
    @objc public func speak(_ invoke: Invoke) throws {
        ttsLog("invoke:speak")
        let args = try invoke.parseArgs(SpeakArgs.self)
        Self.speaker.speak(args, invoke: invoke)
    }

    @objc public func stop(_ invoke: Invoke) {
        ttsLog("invoke:stop")
        Self.speaker.stop(invoke)
    }

    @objc public func is_speaking(_ invoke: Invoke) {
        ttsLog("invoke:is_speaking")
        Self.speaker.isSpeaking(invoke)
    }

    // list_voices(): returns { voices: Array<{name, language, quality, identifier}> }
    @objc public func list_voices(_ invoke: Invoke) {
        let all = AVSpeechSynthesisVoice.speechVoices()
        ttsLog("invoke:list_voices count:", all.count)

        let vs: [[String: Any?]] = all.map { v in
            [
                "name": v.name,
                "language": v.language,
                "identifier": v.identifier,
                "quality": v.quality.rawValue,
            ]
        }
        // Wrap in a dictionary so it matches Invoke.resolve(JsonObject)
        invoke.resolve(["voices": vs])
    }
}

@_cdecl("init_plugin_tts")
func initPlugin() -> Plugin {
    ttsLog("initPlugin()")
    return TTSPlugin()
}
