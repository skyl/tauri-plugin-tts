import AVFoundation
import Tauri
// ----------------------------------------------------------------------------
// Logging that appears in `tauri ios dev` console (Unified Logging)
// ----------------------------------------------------------------------------
import os.log

#if canImport(UIKit)
    import UIKit
#endif

private let TTS_SUBSYSTEM = "com.corpora.corpan"
private let TTS_CATEGORY = "TTS"
private let ttsLogObj = OSLog(subsystem: TTS_SUBSYSTEM, category: TTS_CATEGORY)
@inline(__always) private func ttsLog(_ items: Any...) {
    os_log("%{public}@", log: ttsLogObj, type: .info, items.map { "\($0)" }.joined(separator: " "))
}

// ----------------------------------------------------------------------------
// Rate mapping (WEB 0.0..1.5  ->  iOS utter.rate ≈ 0.2..0.8)
// Adjust these three if “normal” feels a hair too fast/slow.
// ----------------------------------------------------------------------------
private let IOS_RATE_MIN: Double = 0.20  // lower bound of utter.rate
private let IOS_RATE_MAX: Double = 0.80  // upper bound of utter.rate
private let IOS_RATE_SKEW: Double = -0.03  // small global nudge; negative = slightly slower

private func mapWebRateToAVRate(_ web: Double) -> Float {
    // Clamp incoming web rate and map linearly, then apply a tiny skew.
    let clamped = max(0.0, min(1.5, web))
    var mapped = IOS_RATE_MIN + (clamped / 1.5) * (IOS_RATE_MAX - IOS_RATE_MIN)
    mapped = max(IOS_RATE_MIN, min(IOS_RATE_MAX, mapped + IOS_RATE_SKEW))
    return Float(mapped)
}

// ----------------------------------------------------------------------------
// Args (all optional except text) — stays compatible with your Rust side
// ----------------------------------------------------------------------------
class SpeakArgs: Decodable {
    let text: String
    let language: String?  // e.g. "fa-IR" or "fa"
    let voiceIdentifier: String?  // force specific voice if known
    let rate: Double?  // web-style 0.0..1.5
    let pitch: Double?  // 0.5..2.0 (1.0 default)
    let volume: Double?  // 0.0..1.0
}

enum SpeakError: Error {
    case speakerNotReady
    case invalidArgs(String)
}

// ----------------------------------------------------------------------------
// Speaker
// ----------------------------------------------------------------------------
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private static let synth = AVSpeechSynthesizer()  // keep alive across calls

    override init() {
        super.init()
        Self.synth.delegate = self
        ttsLog("Speaker init; voices available:", AVSpeechSynthesisVoice.speechVoices().count)
    }

    // Normalize BCP-47 tags: lowercase + underscores -> hyphens
    private func normalizeTag(_ tag: String) -> String {
        return tag.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private func baseLang(_ tag: String) -> String {
        return tag.split(separator: "-").first.map(String.init) ?? tag
    }

    // Prefer "fa-IR" when only "fa" is provided
    private func exactHint(for want: String) -> String? {
        switch want {
        case "fa": return "fa-ir"
        default: return nil
        }
    }

    // Build ordered candidates we will try (strings are already normalized)
    private func candidateTags(for wantRaw: String) -> [String] {
        let want = normalizeTag(wantRaw)  // e.g., "fa-ir"
        let base = baseLang(want)  // e.g., "fa"

        var list: [String] = []
        if base == "fa" { list.append("fa-ir") }  // strong preference

        list.append(want)  // exact
        if base != want { list.append(base) }  // base

        // last-ditch: Arabic reads the script (not Persian phonology)
        list.append(contentsOf: ["ar-001", "ar"])

        // de-dup preserving order
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    // Try to find a concrete installed voice by identifier or language tag(s)
    private func selectInstalledVoice(language: String?, identifier: String?)
        -> AVSpeechSynthesisVoice?
    {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        ttsLog(
            "selectVoice: voices:", voices.count,
            "| want language:", language ?? "nil",
            "| want id:", identifier ?? "nil")

        if let id = identifier, let v = voices.first(where: { $0.identifier == id }) {
            ttsLog("selectVoice: matched by identifier:", v.name, v.language, v.identifier)
            return v
        }

        guard let langRaw = language, !langRaw.isEmpty else {
            ttsLog("selectVoice: no language provided; returning nil")
            return nil
        }

        // Try exact hint (fa -> fa-ir) before general candidates
        if let hint = exactHint(for: normalizeTag(langRaw)),
            let v = voices.first(where: { $0.language.lowercased() == hint })
        {
            ttsLog("selectVoice: matched hint", hint, "->", v.name, v.language)
            return v
        }

        for tag in candidateTags(for: langRaw) {
            // exact tag
            if let v = voices.first(where: { $0.language.lowercased() == tag }) {
                ttsLog("selectVoice: matched", tag, "->", v.name, v.language)
                return v
            }
            // base family (fa matches fa-IR, fa-AF, etc.)
            let base = baseLang(tag)
            if let v = voices.first(where: {
                let l = $0.language.lowercased()
                return l == base || l.hasPrefix(base + "-")
            }) {
                ttsLog("selectVoice: matched base", base, "->", v.name, v.language)
                return v
            }
        }

        ttsLog("selectVoice: no installed voice for", langRaw)
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
                "speak() | lang:", args.language ?? "nil",
                "| id:", args.voiceIdentifier ?? "nil",
                "| rate:", args.rate ?? -1,
                "| pitch:", args.pitch ?? -1,
                "| volume:", args.volume ?? -1)

            self.prepareAudioSessionIfNeeded()

            if Self.synth.isSpeaking {
                ttsLog("Synth already speaking; stopping before new utterance.")
                Self.synth.stopSpeaking(at: .immediate)
            }

            let utter = AVSpeechUtterance(string: args.text)

            // Choose a voice
            var usedTag: String? = nil
            if let v = self.selectInstalledVoice(
                language: args.language, identifier: args.voiceIdentifier)
            {
                utter.voice = v
                usedTag = v.language.lowercased()
                ttsLog("Using installed voice:", v.name, v.language, "[", v.identifier, "]")
            } else if let lang = args.language {
                // Try creating a model voice with our candidate tags
                var bound = false
                for tag in self.candidateTags(for: lang) {
                    if let model = AVSpeechSynthesisVoice(language: tag) {
                        utter.voice = model
                        usedTag = model.language.lowercased()
                        ttsLog(
                            "Using AVSpeechSynthesisVoice(language:)", tag, "->", model.name,
                            model.language)
                        bound = true
                        break
                    }
                }
                if !bound {
                    ttsLog("No AVSpeechSynthesisVoice for", lang, "— using system default")
                }
            } else {
                ttsLog("No language/identifier; system default voice will be used.")
            }

            // Prosody
            if let r = args.rate {
                utter.rate = mapWebRateToAVRate(r)
            } else {
                // If the caller omitted rate, keep Apple's default (usually ≈ 0.5).
                utter.rate = AVSpeechUtteranceDefaultSpeechRate
            }
            if let p = args.pitch { utter.pitchMultiplier = Float(p) }
            if let v = args.volume { utter.volume = Float(v) }
            ttsLog(
                "Prosody -> rate:", utter.rate, "pitch:", utter.pitchMultiplier, "volume:",
                utter.volume)

            // Speak
            Self.synth.speak(utter)
            ttsLog("synth.speak() queued.")

            // Report back immediately with fallback info if Persian wasn't honored.
            var response: [String: Any] = ["ok": true]
            if let wantedRaw = args.language {
                let wantedBase = self.baseLang(self.normalizeTag(wantedRaw))
                let usedBase = usedTag.map(self.baseLang)
                if wantedBase == "fa", usedBase != "fa" {
                    response["fallback"] = [
                        "wanted": "fa",
                        "used": usedTag ?? "system",
                        "recommendInstall": true,
                    ]
                }
            }
            invoke.resolve(response)
        }
    }

    func stop(_ invoke: Invoke) {
        DispatchQueue.main.async {
            ttsLog("stop() called.")
            Self.synth.stopSpeaking(at: .immediate)
            invoke.resolve()
        }
    }

    func isSpeaking(_ invoke: Invoke) {
        let speaking = Self.synth.isSpeaking
        ttsLog("isSpeaking ->", speaking)
        invoke.resolve(speaking)
    }

    // MARK: - AVSpeechSynthesizerDelegate (logging only; no resolving here)
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        ttsLog("delegate didFinish")
    }
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        ttsLog("delegate didCancel")
    }
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        ttsLog("delegate didStart")
    }
}

// ----------------------------------------------------------------------------
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
        invoke.resolve(["voices": vs])  // JsonObject
    }
}

@_cdecl("init_plugin_tts")
func initPlugin() -> Plugin {
    ttsLog("initPlugin()")
    return TTSPlugin()
}
