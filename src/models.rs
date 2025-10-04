// src/models.rs
use serde::{Deserialize, Serialize};

/// Arguments for `speak`.
/// - `voice_id` (if provided) selects an exact system voice.
///   * iOS / macOS (AVFoundation): `AVSpeechSynthesisVoice.identifier`
///   * macOS (AppKit NSSpeechSynthesizer): `NSVoiceIdentifier`
///   * Android: `android.speech.tts.Voice.getName()`
/// - `language` remains as a fallback / hint (BCP-47), used when `voice_id` is not provided.
#[derive(Debug, Deserialize, Serialize)]
pub struct SpeakArgs {
    pub text: String,
    pub language: Option<String>,
    pub rate: Option<f32>, // optional; platform-native rate mapping happens per target
    pub voice_id: Option<String>, // NEW (optional)
}

/// Cross-platform normalization of platform voice gender.
/// - iOS: `AVSpeechSynthesisVoice.gender` (iOS 13+)
/// - macOS (AppKit): `NSVoiceGender`
/// - Android: not available → `None` at call site
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoiceGender {
    Male,
    Female,
    Neutral,
    Unspecified,
}

/// Normalized quality tiers that map directly to what platforms actually expose:
/// - iOS / macOS (AVFoundation): `AVSpeechSynthesisVoice.quality` → `Default` or `Enhanced`
/// - Android: `android.speech.tts.Voice.getQuality()` → VeryLow/Low/Normal/High/VeryHigh
/// - macOS (AppKit NSSpeechSynthesizer): no quality concept → `None` at call site
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoiceQuality {
    // AVFoundation
    Default,
    Enhanced,
    // Android
    VeryLow,
    Low,
    Normal,
    High,
    VeryHigh,
}

/// A device voice that Corpán can present in UI and pass back into `speak`.
/// Fields are limited to metadata that each platform **actually** provides.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceInfo {
    /// Stable identifier usable with `speak`.
    /// iOS/macOS (AVFoundation): `AVSpeechSynthesisVoice.identifier`
    /// macOS (AppKit): `NSVoiceIdentifier`
    /// Android: `Voice.getName()`
    pub id: String,

    /// Displayable name, where available.
    /// iOS: `AVSpeechSynthesisVoice.name`
    /// macOS (AppKit): `NSVoiceName`
    /// Android: not exposed separately; typically `None` or mirrors `id`.
    pub name: Option<String>,

    /// BCP-47 language tag (e.g., "en-US", "fa-IR").
    /// iOS: `AVSpeechSynthesisVoice.language`
    /// macOS (AppKit): `NSVoiceLocaleIdentifier` (preferred) or `NSVoiceLanguage`
    /// Android: `Voice.getLocale().toLanguageTag()`
    pub language: String,

    /// Reported gender if the platform exposes it (see `VoiceGender` docs above).
    pub gender: Option<VoiceGender>,

    /// Reported quality tier if available (see `VoiceQuality` docs above).
    pub quality: Option<VoiceQuality>,

    /// Engine/bundle identifier when available (e.g., Android "com.google.android.tts").
    /// iOS/macOS AVFoundation and AppKit generally omit this → `None`.
    pub engine: Option<String>,
}
