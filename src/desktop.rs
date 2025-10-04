// src/desktop.rs
#![allow(unexpected_cfgs)] // quiet objc macro warnings in this file

use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

use crate::models::{VoiceGender, VoiceInfo, VoiceQuality};

pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<Tts<R>> {
    Ok(Tts(app.clone()))
}

/// Access to the desktop TTS APIs.
pub struct Tts<R: Runtime>(AppHandle<R>);

impl<R: Runtime> Tts<R> {
    /// Back-compat entry point: speak without an explicit voice id
    pub fn speak(
        &self,
        text: String,
        language: Option<String>,
        rate: Option<f32>,
    ) -> crate::Result<()> {
        #[cfg(target_os = "macos")]
        {
            macos_impl::macos_speak_with_options(&text, language.as_deref(), rate, None)?;
            return Ok(());
        }
        #[cfg(not(target_os = "macos"))]
        {
            // Non-macOS desktop is not handled by the native plugin; the app will fall back to Web Speech.
            Ok(())
        }
    }

    /// New entry point: speak with an optional explicit voice id
    pub fn speak_with_options(
        &self,
        text: String,
        language: Option<String>,
        rate: Option<f32>,
        voice_id: Option<String>,
    ) -> crate::Result<()> {
        #[cfg(target_os = "macos")]
        {
            macos_impl::macos_speak_with_options(
                &text,
                language.as_deref(),
                rate,
                voice_id.as_deref(),
            )?;
            return Ok(());
        }
        #[cfg(not(target_os = "macos"))]
        {
            // Non-macOS desktop is not handled by the native plugin; the app will fall back to Web Speech.
            Ok(())
        }
    }

    pub fn stop(&self) -> crate::Result<()> {
        #[cfg(target_os = "macos")]
        {
            macos_impl::macos_stop()?;
            return Ok(());
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(())
        }
    }

    /// Open the closest-possible system UI for managing/downloading TTS voices.
    pub fn open_tts_settings(&self) -> crate::Result<()> {
        #[cfg(target_os = "macos")]
        {
            macos_impl::macos_open_spoken_content()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(())
        }
    }

    /// Best-effort programmatic voice install (Android only on mobile).
    /// On desktop macOS, there is no programmatic install → return false.
    pub fn install_tts_data_if_supported(&self) -> crate::Result<bool> {
        #[cfg(target_os = "macos")]
        {
            Ok(false)
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(false)
        }
    }

    /// Enumerate installed/available voices with cross-platform metadata.
    pub fn list_voices(&self) -> crate::Result<Vec<VoiceInfo>> {
        #[cfg(target_os = "macos")]
        {
            macos_impl::macos_list_voices()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(Vec::new())
        }
    }
}

// -------------------------- macOS (AVFoundation) --------------------------

#[cfg(target_os = "macos")]
mod macos_impl {
    use super::*;
    use cocoa::base::{id, nil};
    use cocoa::foundation::NSString; // bring the trait into scope for `init_str`
    use objc::{class, msg_send, sel, sel_impl};
    use std::ffi::CStr;
    use std::sync::Once;

    // Persistent synthesizer so `stop` can actually stop current speech.
    static mut SYNTH: id = 0 as id;
    static INIT: Once = Once::new();

    fn with_synth<F: FnOnce(id)>(f: F) {
        unsafe {
            INIT.call_once(|| {
                SYNTH = msg_send![class!(AVSpeechSynthesizer), new];
            });
            f(SYNTH);
        }
    }

    #[inline]
    unsafe fn nsstring_to_rust(ns: id) -> String {
        let c: *const std::os::raw::c_char = msg_send![ns, UTF8String];
        if c.is_null() {
            String::new()
        } else {
            CStr::from_ptr(c).to_string_lossy().into_owned()
        }
    }

    // tiny helper for NSString literals; call sites are already in `unsafe` blocks
    #[macro_export]
    macro_rules! ns_string {
        ($s:expr) => {{
            cocoa::foundation::NSString::alloc(cocoa::base::nil).init_str($s)
        }};
    }
    pub(super) use ns_string;

    #[inline]
    fn norm(tag: &str) -> String {
        tag.to_lowercase().replace('_', "-")
    }

    fn normalize_want(want: &str) -> (String, String) {
        let want_lc = norm(want);
        let base = want_lc
            .split_once('-')
            .map(|(b, _)| b.to_string())
            .unwrap_or_else(|| want_lc.clone());
        (want_lc, base)
    }

    /// Rank voices: exact lang > base match; Enhanced > Default; mild heuristic on name/id; stable tiebreaker by name.
    unsafe fn rank_voice(v: id, want_lang: &str, base_lang: &str) -> (i32, i32, i32, String) {
        let lang_ns: id = msg_send![v, language];
        let lang = nsstring_to_rust(lang_ns);
        let lang_lc = norm(&lang);

        // AVSpeechSynthesisVoiceQuality: 0=Default, 1=Enhanced
        let quality: i64 = msg_send![v, quality];

        let name_ns: id = msg_send![v, name];
        let ident_ns: id = msg_send![v, identifier];
        let name = nsstring_to_rust(name_ns);
        let ident = nsstring_to_rust(ident_ns);
        let name_lc = name.to_lowercase();
        let ident_lc = ident.to_lowercase();

        let lang_score = if lang_lc == want_lang {
            2
        } else if lang_lc == base_lang || lang_lc.starts_with(&format!("{}-", base_lang)) {
            1
        } else {
            0
        };

        let heuristic = ["enhanced", "siri", "natural", "neural", "hq"]
            .iter()
            .any(|h| name_lc.contains(h) || ident_lc.contains(h)) as i32;

        // Sort key: (lang_score desc, quality desc, heuristic desc, name asc)
        (lang_score as i32, quality as i32, heuristic, name)
    }

    unsafe fn best_avfoundation_voice(lang: Option<&str>) -> Option<id> {
        let want = lang.unwrap_or_default();
        let (want_norm, base_lang) = normalize_want(want);

        let voices: id = msg_send![class!(AVSpeechSynthesisVoice), speechVoices];
        let count: usize = msg_send![voices, count];
        if count == 0 {
            return None;
        }

        let mut best: Option<(i32, i32, i32, String, id)> = None;
        for i in 0..count {
            let v: id = msg_send![voices, objectAtIndex: i];
            let (ls, q, h, name) = rank_voice(v, &want_norm, &base_lang);
            best = match best {
                None => Some((ls, q, h, name, v)),
                Some((pls, pq, ph, pname, pv)) => {
                    if (ls, q, h, name.clone()) > (pls, pq, ph, pname.clone()) {
                        Some((ls, q, h, name, v))
                    } else {
                        Some((pls, pq, ph, pname, pv))
                    }
                }
            };
        }
        best.map(|t| t.4)
    }

    #[inline]
    fn clamp(v: f32, lo: f32, hi: f32) -> f32 {
        if v < lo {
            lo
        } else if v > hi {
            hi
        } else {
            v
        }
    }

    /// Map a web-style rate (≈0.1–1.5, with 1.0 = "normal") to AV's 0.0–1.0,
    /// keeping 1.0 → 0.5 (AV default), with gentle padding at extremes.
    #[inline]
    fn map_web_rate_to_av(web_rate: f32) -> f32 {
        const W_MIN: f32 = 0.10;
        const W_DEF: f32 = 1.00;
        const W_MAX: f32 = 1.50;

        const AV_MIN: f32 = 0.00;
        const AV_DEF: f32 = 0.50;
        const AV_MAX: f32 = 0.70;

        const PAD: f32 = 0.01;

        let w = clamp(web_rate, W_MIN, W_MAX);

        if w <= W_DEF {
            // Map [W_MIN .. W_DEF] -> [AV_MIN+PAD .. AV_DEF]
            let t = (w - W_MIN) / (W_DEF - W_MIN); // 0..1
            (AV_MIN + PAD) + t * (AV_DEF - (AV_MIN + PAD))
        } else {
            // Map [W_DEF .. W_MAX] -> [AV_DEF .. AV_MAX-PAD]
            let t = (w - W_DEF) / (W_MAX - W_DEF); // 0..1
            AV_DEF + t * ((AV_MAX - PAD) - AV_DEF)
        }
    }

    pub(super) fn macos_speak_with_options(
        text: &str,
        language: Option<&str>,
        rate: Option<f32>,
        voice_id: Option<&str>,
    ) -> crate::Result<()> {
        unsafe {
            let utter: id = msg_send![
                class!(AVSpeechUtterance),
                speechUtteranceWithString: ns_string!(text)
            ];

            if let Some(r) = rate {
                let mapped = map_web_rate_to_av(r);
                let _: () = msg_send![utter, setRate: mapped];
            }

            // Prefer explicit voice by identifier if provided.
            if let Some(req_id) = voice_id {
                let v_by_id: id = msg_send![
                    class!(AVSpeechSynthesisVoice),
                    voiceWithIdentifier: ns_string!(req_id)
                ];
                if !v_by_id.is_null() {
                    let _: () = msg_send![utter, setVoice: v_by_id];
                } else if let Some(lang) = language {
                    let v_lang: id = msg_send![
                        class!(AVSpeechSynthesisVoice),
                        voiceWithLanguage: ns_string!(lang)
                    ];
                    if !v_lang.is_null() {
                        let _: () = msg_send![utter, setVoice: v_lang];
                    } else if let Some(best) = best_avfoundation_voice(Some(lang)) {
                        let _: () = msg_send![utter, setVoice: best];
                    }
                }
            } else if let Some(lang) = language {
                // Language-specific voice or best match.
                let v_lang: id = msg_send![
                    class!(AVSpeechSynthesisVoice),
                    voiceWithLanguage: ns_string!(lang)
                ];
                if !v_lang.is_null() {
                    let _: () = msg_send![utter, setVoice: v_lang];
                } else if let Some(best) = best_avfoundation_voice(Some(lang)) {
                    let _: () = msg_send![utter, setVoice: best];
                }
            }

            with_synth(|synth| {
                let _: () = msg_send![synth, speakUtterance: utter];
            });
        }
        Ok(())
    }

    pub(super) fn macos_stop() -> crate::Result<()> {
        unsafe {
            with_synth(|synth| {
                // 0 == immediate; 1 == word; 2 == sentence (AVSpeechBoundary)
                let _: bool = msg_send![synth, stopSpeakingAtBoundary: 1i64];
            });
        }
        Ok(())
    }

    pub(super) fn macos_open_spoken_content() -> crate::Result<()> {
        // Try most specific pane first, then fall back to Accessibility root
        let candidates = &[
            "x-apple.systempreferences:com.apple.preference.accessibility?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.accessibility",
        ];

        unsafe {
            let ws: id = msg_send![class!(NSWorkspace), sharedWorkspace];
            for s in candidates {
                let url: id = msg_send![class!(NSURL), URLWithString: ns_string!(s)];
                if url != nil {
                    let ok: bool = msg_send![ws, openURL: url];
                    if ok {
                        return Ok(());
                    }
                }
            }
        }
        Ok(())
    }

    pub(super) fn macos_list_voices() -> crate::Result<Vec<VoiceInfo>> {
        let mut out = Vec::new();
        unsafe {
            let voices: id = msg_send![class!(AVSpeechSynthesisVoice), speechVoices];
            let count: usize = msg_send![voices, count];

            for i in 0..count {
                let v: id = msg_send![voices, objectAtIndex: i];

                let ident_ns: id = msg_send![v, identifier];
                let name_ns: id = msg_send![v, name];
                let lang_ns: id = msg_send![v, language];

                let id_str = nsstring_to_rust(ident_ns);
                let name = {
                    let s = nsstring_to_rust(name_ns);
                    if s.is_empty() {
                        None
                    } else {
                        Some(s)
                    }
                };
                let language = nsstring_to_rust(lang_ns);

                // quality: 0=Default, 1=Enhanced
                let q_raw: i64 = msg_send![v, quality];
                let quality = match q_raw {
                    1 => Some(VoiceQuality::Enhanced),
                    0 => Some(VoiceQuality::Default),
                    _ => None,
                };

                // gender (if available)
                let gender = if responds_to_selector(v, sel!(gender)) {
                    let g_raw: i64 = msg_send![v, gender];
                    // 0=unspecified, 1=male, 2=female (Apple docs)
                    match g_raw {
                        1 => Some(VoiceGender::Male),
                        2 => Some(VoiceGender::Female),
                        0 => Some(VoiceGender::Unspecified),
                        _ => None,
                    }
                } else {
                    None
                };

                out.push(VoiceInfo {
                    id: id_str,
                    name,
                    language,
                    gender,
                    quality,
                    engine: None, // AVFoundation doesn't expose an engine/bundle here
                });
            }
        }
        Ok(out)
    }

    #[inline]
    unsafe fn responds_to_selector(obj: id, selector: objc::runtime::Sel) -> bool {
        let yes: bool = msg_send![obj, respondsToSelector: selector];
        yes
    }
}
