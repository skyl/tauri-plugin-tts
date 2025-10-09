import AVFoundation
import Tauri
import os.log

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(UIKit)
    import UIKit
#endif

// -----------------------------------------------------------------------------
// Logging
// -----------------------------------------------------------------------------
private let TTS_SUBSYSTEM = "com.corpora.corpan"
private let TTS_CATEGORY = "TTS"
private let ttsLogObj = OSLog(subsystem: TTS_SUBSYSTEM, category: TTS_CATEGORY)
@inline(__always) private func ttsLog(_ items: Any...) {
    os_log("%{public}@", log: ttsLogObj, type: .info, items.map { "\($0)" }.joined(separator: " "))
}

// -----------------------------------------------------------------------------
// Rate mapping (WEB ~0.1..1.5 → AVSpeech 0.03..0.73 with a slight skew)
// -----------------------------------------------------------------------------
private let IOS_RATE_MIN: Double = 0.03
private let IOS_RATE_MAX: Double = 0.73
private let IOS_RATE_SKEW: Double = -0.03

private func mapWebRateToAVRate(_ web: Double) -> Float {
    let clamped = max(0.1, min(1.5, web))
    var mapped = IOS_RATE_MIN + (clamped / 1.5) * (IOS_RATE_MAX - IOS_RATE_MIN)
    mapped = max(IOS_RATE_MIN, min(IOS_RATE_MAX, mapped + IOS_RATE_SKEW))
    return Float(mapped)
}

// -----------------------------------------------------------------------------
// Args (Decodable). Accept "voice_id" (snake) or "voiceId" (camel).
// -----------------------------------------------------------------------------
final class SpeakArgs: Decodable {
    let text: String
    let language: String?
    let voiceId: String?
    let rate: Double?
    let pitch: Double?
    let volume: Double?

    private enum CodingKeys: String, CodingKey {
        case text, language, rate, pitch, volume
        case voiceId  // <-- expect "voiceId"
    }
}

// -----------------------------------------------------------------------------
// Speaker (voice picking, audio session, speak/stop)
// -----------------------------------------------------------------------------
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private static let synth = AVSpeechSynthesizer()

    // Known “novelty/legacy” markers to avoid for production TTS
    private static let NOVELTY_TOKENS: [String] = [
        "trinoids", "bubbles", "bad", "zarvox", "boing", "hysterical", "pipe",
        "agnes", "albert", "fred", "junior", "kathy", "princess", "bahh", "cellos",
        "deranged", "bells", "whisper",
    ]
    private static let LEGACY_PREFIX = "com.apple.speech.synthesis.voice."  // old AppKit catalog
    private static let ELOQUENCE_PREFIX = "com.apple.eloquence."  // Eloquence catalog
    private static let VOICE_PREFIX = "com.apple.voice."

    // Quality tokens (best → worst): Premium(3) > Enhanced(2) > Default(1)
    // Siri is not a separate AV quality enum; we still allow it.
    private static let PREMIUM_TOKENS = ["premium", "neural", "natural", "studio", "hq", "pro"]
    private static let ENHANCED_TOKENS = ["enhanced", "improved", "hd"]

    override init() {
        super.init()
        Self.synth.delegate = self
        let all = AVSpeechSynthesisVoice.speechVoices()
        ttsLog("TTS init | voices:", all.count)
        // ttsLog("TTS catalog |", Self.voicesSummaryLine(all))
    }

    // Helpers
    private func normalizeTag(_ tag: String) -> String {
        tag.lowercased().replacingOccurrences(of: "_", with: "-")
    }
    private func baseLang(_ tag: String) -> String {
        tag.split(separator: "-").first.map(String.init) ?? tag
    }

    private func isLegacy(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.hasPrefix(Self.LEGACY_PREFIX)
    }
    private func isEloquence(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.hasPrefix(Self.ELOQUENCE_PREFIX)
    }
    private func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        let blob = (v.identifier + " " + v.name).lowercased()
        return Self.NOVELTY_TOKENS.contains { blob.contains($0) }
    }
    private func isModern(_ v: AVSpeechSynthesisVoice) -> Bool {
        !(isLegacy(v) || isEloquence(v))
    }

    private func qualityString(_ v: AVSpeechSynthesisVoice) -> String {
        if #available(iOS 16.0, macOS 13.0, *) {
            switch v.quality {
            case .premium: return "premium"
            case .enhanced: return "enhanced"
            default: return "default"
            }
        } else {
            // Older OSes don't have `.premium`
            return (v.quality == .enhanced) ? "enhanced" : "default"
        }
    }

    // Rank for internal comparisons (premium 3 > enhanced 2 > default 1)
    private func qualityTier(_ v: AVSpeechSynthesisVoice) -> Int {
        if #available(iOS 16.0, macOS 13.0, *) {
            switch v.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        } else {
            return v.quality == .enhanced ? 2 : 1
        }
    }

    private func langMatchScore(voiceTag: String, wantTag: String) -> Int {
        let v = voiceTag.lowercased()
        let w = wantTag.lowercased()
        if v == w { return 3 }
        let base = baseLang(w)
        if v == base || v.hasPrefix(base + "-") { return 2 }
        return 0
    }

    private func allUsableVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var keep: [AVSpeechSynthesisVoice] = []
        var droppedLegacy = 0
        var droppedEloq = 0
        var droppedNovelty = 0
        for v in all {
            if isLegacy(v) {
                droppedLegacy += 1
                continue
            }
            if isEloquence(v) {
                droppedEloq += 1
                continue
            }
            if isNovelty(v) {
                droppedNovelty += 1
                continue
            }
            keep.append(v)
        }
        // ttsLog(
        //     "TTS filter | kept:", keep.count,
        //     "| legacy:", droppedLegacy, "| eloquence:", droppedEloq, "| novelty:", droppedNovelty)
        return keep
    }

    private func pickBest(in pool: [AVSpeechSynthesisVoice], want: String)
        -> AVSpeechSynthesisVoice?
    {
        guard !pool.isEmpty else { return nil }
        return pool.max { a, b in
            let la = langMatchScore(voiceTag: a.language, wantTag: want)
            let lb = langMatchScore(voiceTag: b.language, wantTag: want)
            if la != lb { return la < lb }
            let qa = qualityTier(a)
            let qb = qualityTier(b)
            if qa != qb { return qa < qb }
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue < b.quality.rawValue
            }
            return a.name > b.name
        }
    }

    private func pickVoice(language wantRaw: String?) -> AVSpeechSynthesisVoice? {
        let usable = allUsableVoices()
        guard !usable.isEmpty else { return nil }

        guard let wantRaw, !wantRaw.isEmpty else {
            return pickBest(in: usable, want: "en-US")  // neutral-ish default
        }

        let want = normalizeTag(wantRaw)
        let base = baseLang(want)

        let exactPool = usable.filter { $0.language.lowercased() == want }
        if let bestExact = pickBest(in: exactPool, want: want) { return bestExact }

        let basePool = usable.filter {
            let l = $0.language.lowercased()
            return l == base || l.hasPrefix(base + "-")
        }
        if let bestBase = pickBest(in: basePool, want: want) { return bestBase }

        ttsLog(
            "TTS select | no usable \(want) or base \(base); leave voice unset (system default).")
        return nil
    }

    // One-line summary of all voices (for diagnostics)
    static func voicesSummaryLine(_ list: [AVSpeechSynthesisVoice]) -> String {
        list.map { v in "\(v.name)@\(v.language)[q=\(v.quality.rawValue)]{\(v.identifier)}" }
            .joined(separator: " | ")
    }

    private func prepareAudioSessionIfNeeded() {
        #if canImport(UIKit)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
                // ttsLog("TTS audio | AVAudioSession ready")
            } catch {
                // ttsLog("TTS audio | setup failed:", error.localizedDescription)
            }
        #endif
    }

    func speak(_ args: SpeakArgs, invoke: Invoke) {
        DispatchQueue.main.async {
            ttsLog(
                "TTS speak | lang:", args.language ?? "nil",
                "| id:", args.voiceId ?? "nil",
                "| rate:", args.rate ?? -1,
                "| pitch:", args.pitch ?? -1,
                "| volume:", args.volume ?? -1
            )

            self.prepareAudioSessionIfNeeded()

            // If you want strict single-utterance behavior, uncomment:
            // if Self.synth.isSpeaking {
            //     Self.synth.stopSpeaking(at: .immediate)
            //     ttsLog("TTS synth | stopped previous utterance")
            // }

            let utter = AVSpeechUtterance(string: args.text)

            // Prefer explicit voice by identifier
            if let id = args.voiceId,
                let v = self.allUsableVoices().first(where: { $0.identifier == id })
            {
                utter.voice = v
                ttsLog("TTS voice | using id:", v.name, v.language, v.identifier)
            }

            // Otherwise pick by language ranking
            if utter.voice == nil, let best = self.pickVoice(language: args.language) {
                utter.voice = best
                ttsLog(
                    "TTS voice | picked:", best.name, best.language,
                    "tier:", self.qualityTier(best), "avQ:", best.quality.rawValue)
            }

            // Prosody
            utter.rate =
                (args.rate != nil)
                ? mapWebRateToAVRate(args.rate!) : AVSpeechUtteranceDefaultSpeechRate
            if let p = args.pitch { utter.pitchMultiplier = Float(p) }
            if let v = args.volume { utter.volume = Float(v) }
            // ttsLog(
            //     "TTS prosody | rate:", utter.rate, "pitch:", utter.pitchMultiplier, "volume:",
            //     utter.volume)

            Self.synth.speak(utter)
            // ttsLog("TTS synth | queued")
            invoke.resolve()
        }
    }

    func stop(_ invoke: Invoke) {
        DispatchQueue.main.async {
            Self.synth.stopSpeaking(at: .immediate)
            // ttsLog("TTS stop | requested")
            invoke.resolve()
        }
    }

    func isSpeaking(_ invoke: Invoke) {
        invoke.resolve(Self.synth.isSpeaking)
    }

    // Only expose modern Apple Voices in the list (no eloquence / legacy / novelty).
    private func listableVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let list = all.filter { $0.identifier.hasPrefix(Self.VOICE_PREFIX) }
        // ttsLog("TTS list filter | total:", all.count, "| com.apple.voice:*:", list.count)
        if list.isEmpty {
            ttsLog(
                "TTS list filter | WARNING: no com.apple.voice.* voices present on this device/sim."
            )
        }
        return list
    }

    // Replace your existing listVoices(...) with this version.
    func listVoices(_ invoke: Invoke) {
        let list = listableVoices()
        let payload: [[String: Any?]] = list.map { v in
            let genderStr: String? = {
                if #available(iOS 13.0, macOS 10.15, *) {
                    switch v.gender {
                    case .male: return "male"
                    case .female: return "female"
                    case .unspecified: return "unspecified"
                    @unknown default: return "unspecified"
                    }
                } else {
                    return nil
                }
            }()

            return [
                "id": v.identifier,
                "name": v.name,
                "language": v.language,
                "gender": genderStr as Any?,
                "quality": qualityString(v),  // premium/enhanced/default mapping preserved
                "engine": nil,
            ]
        }
        // ttsLog("TTS catalog(listable) |", Speaker.voicesSummaryLine(list))
        invoke.resolve(["voices": payload])  // Tauri iOS expects an object wrapper
    }

}

// -----------------------------------------------------------------------------
// Tauri Plugin surface (names must match run_mobile_plugin calls from Rust)
// -----------------------------------------------------------------------------
final class TTSPlugin: Plugin {
    private static let speaker = Speaker()

    @objc public func speak(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(SpeakArgs.self)
        Self.speaker.speak(args, invoke: invoke)
    }

    @objc public func stop(_ invoke: Invoke) {
        Self.speaker.stop(invoke)
    }

    // Not currently used by Rust, but handy for debugging.
    @objc public func isSpeaking(_ invoke: Invoke) {
        Self.speaker.isSpeaking(invoke)
    }

    // listVoices → returns { voices: [...] }
    @objc public func listVoices(_ invoke: Invoke) {
        Self.speaker.listVoices(invoke)
    }

    // Open device TTS settings (deepest-first candidates)
    @objc public func openTtsSettings(_ invoke: Invoke) {
        #if canImport(UIKit)
            // iOS: make sure Info.plist has LSApplicationQueriesSchemes = ["App-Prefs", "prefs" (optional)]
            let candidates: [URL] = {
                if #available(iOS 15.0, *) {
                    return [
                        // iOS 15+ Spoken Content → Voices
                        URL(string: "App-Prefs:root=ACCESSIBILITY&path=SPOKEN_CONTENT/VOICES"),
                        URL(string: "App-Prefs:root=ACCESSIBILITY&path=SPOKEN_CONTENT"),

                        // Related toggles (land near Spoken Content)
                        URL(string: "App-Prefs:root=ACCESSIBILITY&path=SPEAK_SCREEN"),
                        URL(string: "App-Prefs:root=ACCESSIBILITY&path=SPEAK_SELECTION"),

                        // Pane-level fallbacks
                        URL(string: "App-Prefs:root=ACCESSIBILITY"),
                        URL(string: "App-Prefs:root=General&path=ACCESSIBILITY"),

                        // Legacy scheme (only if you also add "prefs" to LSApplicationQueriesSchemes)
                        URL(string: "prefs:root=ACCESSIBILITY&path=SPOKEN_CONTENT/VOICES"),
                        URL(string: "prefs:root=ACCESSIBILITY&path=SPOKEN_CONTENT"),
                        URL(string: "prefs:root=ACCESSIBILITY&path=SPEECH"),
                        URL(string: "prefs:root=General&path=ACCESSIBILITY/SPEECH"),
                        URL(string: "prefs:root=ACCESSIBILITY"),
                    ].compactMap { $0 }
                } else {
                    // iOS < 15: fall back to older Speech entries first
                    return [
                        URL(string: "App-Prefs:root=ACCESSIBILITY&path=SPEECH"),
                        URL(string: "App-Prefs:root=General&path=ACCESSIBILITY/SPEECH"),
                        URL(string: "App-Prefs:root=ACCESSIBILITY"),

                        // Legacy "prefs:" variants
                        URL(string: "prefs:root=ACCESSIBILITY&path=SPEECH"),
                        URL(string: "prefs:root=General&path=ACCESSIBILITY/SPEECH"),
                        URL(string: "prefs:root=ACCESSIBILITY"),
                    ].compactMap { $0 }
                }
            }()

            for url in candidates {
                if UIApplication.shared.canOpenURL(url) {
                    // ttsLog("TTS settings | opening:", url.absoluteString)
                    UIApplication.shared.open(url, options: [:]) { _ in invoke.resolve() }
                    return
                }
            }
            // ttsLog("TTS settings | no deep link available (check LSApplicationQueriesSchemes)")
            invoke.resolve()

        #elseif canImport(AppKit)
            let candidates: [URL] = [
                // macOS Ventura+ (System Settings)
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"
                ),
                // Some builds anchor via a group key
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.universalaccess?Hearing_SpokenContent"
                ),
                URL(
                    string: "x-apple.systempreferences:com.apple.preference.universalaccess?Hearing"
                ),
                // Accessibility pane fallback
                URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess"),
                // Older System Preferences → Speech
                URL(string: "x-apple.systempreferences:com.apple.preference.speech?TTS"),
                URL(string: "x-apple.systempreferences:com.apple.preference.speech"),
            ].compactMap { $0 }

            for url in candidates {
                if NSWorkspace.shared.open(url) {
                    // ttsLog("TTS settings | opening:", url.absoluteString)
                    invoke.resolve()
                    return
                }
            }
            // ttsLog("TTS settings | failed to open System Settings on macOS")
            invoke.resolve()

        #else
            // ttsLog("TTS settings | unsupported platform")
            invoke.resolve()
        #endif
    }

    // installTtsDataIfSupported: Not supported on iOS → return false.
    @objc public func installTtsDataIfSupported(_ invoke: Invoke) {
        invoke.resolve(false)
    }
}

@_cdecl("init_plugin_tts")
func init_plugin_tts() -> Plugin {
    ttsLog("TTS init_plugin_tts()")
    return TTSPlugin()
}
