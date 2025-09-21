import AVFoundation
import Tauri
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
// ----------------------------------------------------------------------------
private let IOS_RATE_MIN: Double = 0.03
private let IOS_RATE_MAX: Double = 0.73
private let IOS_RATE_SKEW: Double = -0.03

private func mapWebRateToAVRate(_ web: Double) -> Float {
    let clamped = max(0.0, min(1.5, web))
    var mapped = IOS_RATE_MIN + (clamped / 1.5) * (IOS_RATE_MAX - IOS_RATE_MIN)
    mapped = max(IOS_RATE_MIN, min(IOS_RATE_MAX, mapped + IOS_RATE_SKEW))
    return Float(mapped)
}

// ----------------------------------------------------------------------------
// Args (all optional except text)
// ----------------------------------------------------------------------------
class SpeakArgs: Decodable {
    let text: String
    let language: String?  // e.g. "en-US"
    let voiceIdentifier: String?  // accepted but ranking ignores it unless valid
    let rate: Double?
    let pitch: Double?
    let volume: Double?
}

enum SpeakError: Error {
    case speakerNotReady
    case invalidArgs(String)
}

// ----------------------------------------------------------------------------
// Speaker
// ----------------------------------------------------------------------------
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private static let synth = AVSpeechSynthesizer()

    // Novelty/legacy constants
    private static let NOVELTY_TOKENS: [String] = [
        "trinoids", "bubbles", "bad", "zarvox", "boing", "hysterical", "pipe",
        "agnes", "albert", "fred", "junior", "kathy", "princess", "bahh", "cellos", "deranged",
        "bells", "whisper",
    ]
    private static let LEGACY_PREFIX = "com.apple.speech.synthesis.voice."
    private static let MODERN_MARK = ".ttsbundle."

    // Quality tokens (in identifiers/names). Tier: Premium(4) > Enhanced(3) > Siri(2) > Modern(1)
    private static let PREMIUM_TOKENS = ["premium", "neural", "natural", "studio", "hq", "pro"]
    private static let ENHANCED_TOKENS = ["enhanced", "improved", "hd"]
    private static let SIRI_TOKENS = ["siri"]

    override init() {
        super.init()
        Self.synth.delegate = self
        let all = AVSpeechSynthesisVoice.speechVoices()
        ttsLog("TTS init | voices:", all.count)
        ttsLog("TTS catalog |", Self.voicesSummaryLine(all))
        #if targetEnvironment(simulator)
            ttsLog(
                "TTS note | Simulator: legacy/novelty filtered; will widen to base language if needed."
            )
        #endif
    }

    // ---- Tag helpers --------------------------------------------------------
    private func normalizeTag(_ tag: String) -> String {
        tag.lowercased().replacingOccurrences(of: "_", with: "-")
    }
    private func baseLang(_ tag: String) -> String {
        tag.split(separator: "-").first.map(String.init) ?? tag
    }

    // If caller passes bare language, add a gentle region hint
    private func hintForBare(_ base: String) -> String? {
        switch base {
        case "pt": return "pt-br"
        case "zh": return "zh-cn"
        case "fa": return "fa-ir"
        default: return nil
        }
    }

    private func candidateTags(for wantRaw: String) -> [String] {
        let want = normalizeTag(wantRaw)
        let base = baseLang(want)
        var list: [String] = []
        if let h = hintForBare(base) { list.append(h) }
        list.append(want)  // exact
        if base != want { list.append(base) }  // base
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    // ---- Filtering & ranking ------------------------------------------------
    private func isLegacy(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.hasPrefix(Self.LEGACY_PREFIX)
    }
    private func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        let blob = (v.identifier + " " + v.name).lowercased()
        return Self.NOVELTY_TOKENS.contains(where: { blob.contains($0) })
    }
    private func isModern(_ v: AVSpeechSynthesisVoice) -> Bool {
        // Treat as modern unless explicitly legacy; Siri/others may not include .ttsbundle.
        return !isLegacy(v)
    }

    // Premium(4) > Enhanced(3) > Siri(2) > Modern default(1)
    private func qualityTier(_ v: AVSpeechSynthesisVoice) -> Int {
        let id = v.identifier.lowercased()
        let name = v.name.lowercased()
        if Self.PREMIUM_TOKENS.contains(where: { id.contains($0) || name.contains($0) }) {
            return 4
        }
        if v.quality.rawValue >= 2
            || Self.ENHANCED_TOKENS.contains(where: { id.contains($0) || name.contains($0) })
        {
            return 3
        }
        if Self.SIRI_TOKENS.contains(where: { id.contains($0) || name.contains($0) }) { return 2 }
        return isModern(v) ? 1 : 0
    }

    // 3 = exact "en-US" match, 2 = same base "en-*", 0 otherwise
    private func langMatchScore(_ voiceTag: String, wantTag: String) -> Int {
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
        var droppedNovelty = 0
        for v in all {
            if isLegacy(v) {
                droppedLegacy += 1
                continue
            }
            if isNovelty(v) {
                droppedNovelty += 1
                continue
            }
            keep.append(v)
        }
        ttsLog(
            "TTS filter | kept:", keep.count, "| dropped legacy:", droppedLegacy,
            "| dropped novelty:", droppedNovelty)
        return keep
    }

    // Core picker: try exact tag with best tier; if none, widen to base (en-*)
    private func pickVoice(language wantLangRaw: String?) -> AVSpeechSynthesisVoice? {
        let usable = allUsableVoices()
        guard !usable.isEmpty else { return nil }

        guard let wantRaw = wantLangRaw, !wantRaw.isEmpty else {
            // No language given → best overall by tier (premium/enhanced preferred)
            return usable.max { a, b in
                let qa = qualityTier(a)
                let qb = qualityTier(b)
                if qa != qb { return qa < qb }
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue < b.quality.rawValue
                }
                return a.name > b.name
            }
        }

        let want = normalizeTag(wantRaw)
        let base = baseLang(want)

        // 1) Exact tag only (e.g., en-US)
        let exactPool = usable.filter { $0.language.lowercased() == want }
        if let bestExact = rankBest(in: exactPool, want: want) { return bestExact }

        // 2) Same base language (e.g., en-*)
        let basePool = usable.filter {
            let l = $0.language.lowercased()
            return l == base || l.hasPrefix(base + "-")
        }
        if let bestBase = rankBest(in: basePool, want: want) { return bestBase }

        // 3) Nothing for that language family → leave unset (system default is safer than junk)
        ttsLog("TTS select | no usable voices for", want, "or base", base, "— leaving voice unset.")
        return nil
    }

    // Rank within a pool: prefer Premium > Enhanced > Siri > Modern; tiebreak by AV quality then name asc.
    private func rankBest(in pool: [AVSpeechSynthesisVoice], want: String)
        -> AVSpeechSynthesisVoice?
    {
        guard !pool.isEmpty else { return nil }
        return pool.max { a, b in
            let la = langMatchScore(a.language, wantTag: want)
            let lb = langMatchScore(b.language, wantTag: want)
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

    // Compact one-line summary of the entire catalog
    static func voicesSummaryLine(_ list: [AVSpeechSynthesisVoice]) -> String {
        let parts = list.map { v in
            let q = v.quality.rawValue
            // name@lang[q=2]{id}
            return "\(v.name)@\(v.language)[q=\(q)]{\(v.identifier)}"
        }
        return parts.joined(separator: " | ")
    }

    // iOS needs an audio session; macOS doesn’t.
    private func prepareAudioSessionIfNeeded() {
        #if canImport(UIKit)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
                ttsLog("TTS audio | AVAudioSession playback/spokenAudio active")
            } catch {
                ttsLog("TTS audio | setup failed:", error.localizedDescription)
            }
        #endif
    }

    func speak(_ args: SpeakArgs, invoke: Invoke) {
        DispatchQueue.main.async {
            ttsLog(
                "TTS speak | lang:", args.language ?? "nil",
                "| id:", args.voiceIdentifier ?? "nil",
                "| rate:", args.rate ?? -1,
                "| pitch:", args.pitch ?? -1,
                "| volume:", args.volume ?? -1)

            self.prepareAudioSessionIfNeeded()

            if Self.synth.isSpeaking {
                Self.synth.stopSpeaking(at: .immediate)
                ttsLog("TTS synth | stopped previous utterance")
            }

            let utter = AVSpeechUtterance(string: args.text)

            // Optional identifier (guarded)
            if let id = args.voiceIdentifier,
                let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == id }),
                !self.isNovelty(v), !self.isLegacy(v)
            {
                utter.voice = v
                ttsLog("TTS voice | using identifier:", v.name, v.language, v.identifier)
            }

            // Rank by language if not set by identifier
            if utter.voice == nil {
                if let best = self.pickVoice(language: args.language) {
                    utter.voice = best
                    ttsLog(
                        "TTS voice | selected:", best.name, best.language, "tier:",
                        self.qualityTier(best), "avQ:", best.quality.rawValue, best.identifier)
                } else {
                    ttsLog("TTS voice | unset -> system default")
                }
            }

            // Prosody
            utter.rate =
                (args.rate != nil)
                ? mapWebRateToAVRate(args.rate!) : AVSpeechUtteranceDefaultSpeechRate
            if let p = args.pitch { utter.pitchMultiplier = Float(p) }
            if let v = args.volume { utter.volume = Float(v) }
            ttsLog(
                "TTS prosody | rate:", utter.rate, "pitch:", utter.pitchMultiplier, "volume:",
                utter.volume)

            Self.synth.speak(utter)
            ttsLog("TTS synth | queued")
            invoke.resolve()
        }
    }

    func stop(_ invoke: Invoke) {
        DispatchQueue.main.async {
            Self.synth.stopSpeaking(at: .immediate)
            ttsLog("TTS stop | requested")
            invoke.resolve()
        }
    }

    func isSpeaking(_ invoke: Invoke) {
        let speaking = Self.synth.isSpeaking
        ttsLog("TTS state | isSpeaking:", speaking)
        invoke.resolve(speaking)
    }

    // MARK: - AVSpeechSynthesizerDelegate (minimal logging)
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        ttsLog("TTS delegate | didStart")
    }
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        ttsLog("TTS delegate | didFinish")
    }
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        ttsLog("TTS delegate | didCancel")
    }
}

// ----------------------------------------------------------------------------
class TTSPlugin: Plugin {
    private static var speaker = Speaker()

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

    // list_voices(): returns { voices: Array<{name, language, quality, identifier}> }
    @objc public func list_voices(_ invoke: Invoke) {
        let all = AVSpeechSynthesisVoice.speechVoices()
        ttsLog("TTS catalog |", Speaker.voicesSummaryLine(all))  // single line dump
        let vs: [[String: Any?]] = all.map { v in
            [
                "name": v.name, "language": v.language, "identifier": v.identifier,
                "quality": v.quality.rawValue,
            ]
        }
        invoke.resolve(["voices": vs])
    }
}

@_cdecl("init_plugin_tts")
func initPlugin() -> Plugin {
    ttsLog("TTS initPlugin()")
    return TTSPlugin()
}
