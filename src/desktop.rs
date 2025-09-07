#![allow(unexpected_cfgs)] // quiet objc macro warnings in this file

use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<Tts<R>> {
    Ok(Tts(app.clone()))
}

/// Access to the tts APIs.
pub struct Tts<R: Runtime>(AppHandle<R>);

impl<R: Runtime> Tts<R> {
    pub fn speak(
        &self,
        text: String,
        language: Option<String>,
        rate: Option<f32>,
    ) -> crate::Result<()> {
        #[cfg(target_os = "macos")]
        {
            macos_speak(&text, language.as_deref(), rate)?;
            return Ok(());
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(())
        }
    }

    pub fn stop(&self) -> crate::Result<()> {
        Ok(())
    }
}

// macOS implementation using AVFoundation with quality ranking
#[cfg(target_os = "macos")]
mod macos_impl {
    use cocoa::base::id;
    use objc::{class, msg_send, sel, sel_impl};
    use std::ffi::CStr;

    #[inline]
    unsafe fn nsstring_to_rust(ns: id) -> String {
        let c: *const std::os::raw::c_char = msg_send![ns, UTF8String];
        if c.is_null() {
            String::new()
        } else {
            CStr::from_ptr(c).to_string_lossy().into_owned()
        }
    }

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

    /// Rank voices: Enhanced > Default; then heuristics on name/identifier; stable tiebreaker by name.
    unsafe fn rank_voice(v: id, want_lang: &str, base_lang: &str) -> (i32, i32, i32, String) {
        let lang_ns: id = msg_send![v, language];
        let lang = nsstring_to_rust(lang_ns);
        let lang_lc = norm(&lang);

        // 1 = default, 2 = enhanced (AVSpeechSynthesisVoiceQuality)
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

        let heuristic = ["enhanced", "premium", "siri", "natural", "neural", "hq"]
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
        // Web semantics (your app):
        //  - ~0.1 very slow
        //  - 1.0 normal
        //  - ~1.5 very fast (almost too fast)
        const W_MIN: f32 = 0.10;
        const W_DEF: f32 = 1.00;
        const W_MAX: f32 = 1.50;

        // AVFoundation semantics:
        //  - min ≈ 0.0
        //  - default = 0.5
        //  - max ≈ 1.0
        const AV_MIN: f32 = 0.00;
        const AV_DEF: f32 = 0.50;
        const AV_MAX: f32 = 0.70;

        // keep a little headroom off the hard endpoints to avoid engine quirks
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

    pub(super) fn macos_speak(
        text: &str,
        language: Option<&str>,
        rate: Option<f32>,
    ) -> crate::Result<()> {
        unsafe {
            let utter: id = msg_send![
                class!(AVSpeechUtterance),
                speechUtteranceWithString: crate::ns_string!(text)
            ];

            if let Some(r) = rate {
                let mapped = map_web_rate_to_av(r);
                let _: () = msg_send![utter, setRate: mapped];
            }

            if let Some(voice_id) = best_avfoundation_voice(language) {
                let _: () = msg_send![utter, setVoice: voice_id];
            } else if let Some(lang) = language {
                let voice_for_lang: id = msg_send![
                    class!(AVSpeechSynthesisVoice),
                    voiceWithLanguage: crate::ns_string!(lang)
                ];
                if !voice_for_lang.is_null() {
                    let _: () = msg_send![utter, setVoice: voice_for_lang];
                }
            }

            let synth: id = msg_send![class!(AVSpeechSynthesizer), new];
            let _: () = msg_send![synth, speakUtterance: utter];
        }
        Ok(())
    }

    // tiny helper for NSString literals
    #[macro_export]
    macro_rules! ns_string {
        ($s:expr) => {{
            use cocoa::base::nil;
            use cocoa::foundation::NSString;
            unsafe { NSString::alloc(nil).init_str($s) }
        }};
    }
}

#[cfg(target_os = "macos")]
use macos_impl::macos_speak;
