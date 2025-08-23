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

#[cfg(target_os = "macos")]
mod macos_impl {
    use cocoa::base::{id, nil};
    use cocoa::foundation::NSString;
    use objc::{class, msg_send, sel, sel_impl};
    use std::ffi::CStr;
    use std::os::raw::c_char;

    #[inline]
    pub(super) fn nsstring(s: &str) -> id {
        unsafe { NSString::alloc(nil).init_str(s) }
    }

    #[inline]
    unsafe fn nsstring_to_rust(ns: id) -> String {
        let c: *const c_char = msg_send![ns, UTF8String];
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

    fn normalize_want(want: &str) -> (String, Option<String>) {
        let want_lc = norm(want);
        match want_lc.as_str() {
            "fa" => (want_lc, Some("fa-ir".to_string())),
            _ => (want_lc, None),
        }
    }

    unsafe fn pick_voice_by_lang(lang: Option<&str>) -> Option<id> {
        let voices: id = msg_send![class!(NSSpeechSynthesizer), availableVoices];
        let count: usize = msg_send![voices, count];
        let (want_norm, maybe_exact_hint) = match lang {
            Some(w) => normalize_want(w),
            None => (String::new(), None),
        };
        let key_locale = nsstring("VoiceLocaleIdentifier");

        if let Some(exact) = maybe_exact_hint {
            for i in 0..count {
                let voice_id: id = msg_send![voices, objectAtIndex: i];
                let attrs: id =
                    msg_send![class!(NSSpeechSynthesizer), attributesForVoice: voice_id];
                let locale_ns: id = msg_send![attrs, objectForKey: key_locale];
                if locale_ns == nil {
                    continue;
                }
                let locale = norm(&nsstring_to_rust(locale_ns));
                if locale == exact {
                    return Some(voice_id);
                }
            }
        }
        if want_norm.is_empty() {
            return None;
        }
        for i in 0..count {
            let voice_id: id = msg_send![voices, objectAtIndex: i];
            let attrs: id = msg_send![class!(NSSpeechSynthesizer), attributesForVoice: voice_id];
            let locale_ns: id = msg_send![attrs, objectForKey: key_locale];
            if locale_ns == nil {
                continue;
            }
            let locale = norm(&nsstring_to_rust(locale_ns));
            if locale == want_norm {
                return Some(voice_id);
            }
        }
        let base = want_norm
            .split_once('-')
            .map(|(b, _)| b.to_string())
            .unwrap_or_else(|| want_norm.clone());
        let base_prefix = format!("{base}-");
        for i in 0..count {
            let voice_id: id = msg_send![voices, objectAtIndex: i];
            let attrs: id = msg_send![class!(NSSpeechSynthesizer), attributesForVoice: voice_id];
            let locale_ns: id = msg_send![attrs, objectForKey: key_locale];
            if locale_ns == nil {
                continue;
            }
            let locale = norm(&nsstring_to_rust(locale_ns));
            if locale == base || locale.starts_with(&base_prefix) {
                return Some(voice_id);
            }
        }
        None
    }

    #[inline]
    fn map_web_rate_to_macos_wpm(web_rate: f32) -> f32 {
        // Clamp a Web-style rate (0.1..2.0) into macOS WPM range ~120–360.
        let r = web_rate.clamp(0.1, 2.0);
        120.0 + (r - 0.1) * (240.0 / 1.9)
    }

    pub(super) fn macos_speak(
        text: &str,
        language: Option<&str>,
        rate: Option<f32>,
    ) -> crate::Result<()> {
        unsafe {
            let alloc: id = msg_send![class!(NSSpeechSynthesizer), alloc];
            let synth: id = msg_send![alloc, init];

            if let Some(voice_id) = pick_voice_by_lang(language) {
                let _ok: bool = msg_send![synth, setVoice: voice_id];
            }

            if let Some(r) = rate {
                let wpm = map_web_rate_to_macos_wpm(r);
                let _: () = msg_send![synth, setRate: wpm];
            }

            let ns_text = nsstring(text);
            let _: bool = msg_send![synth, startSpeakingString: ns_text];
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
use macos_impl::macos_speak;
