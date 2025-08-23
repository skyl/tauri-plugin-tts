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
    pub fn speak(&self, text: String, language: Option<String>) -> crate::Result<()> {
        #[cfg(target_os = "macos")]
        {
            macos_speak(&text, language.as_deref())?;
            return Ok(());
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(())
        }
    }

    pub fn stop(&self) -> crate::Result<()> {
        // Per-call synthesizers mean nothing to stop here; add singleton later if needed.
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
    fn nsstring(s: &str) -> id {
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
        // normalize to lowercase with hyphens (fa_ir → fa-ir)
        tag.to_lowercase().replace('_', "-")
    }

    /// Very small aliasing to help base codes (e.g., "fa" => prefer "fa-IR").
    fn normalize_want(want: &str) -> (String, Option<String>) {
        let want_lc = norm(want);
        match want_lc.as_str() {
            "fa" => (want_lc, Some("fa-ir".to_string())),
            _ => (want_lc, None),
        }
    }

    /// Dump all available voices (identifier | name | locale) for debugging.
    unsafe fn log_all_voices() {
        let voices: id = msg_send![class!(NSSpeechSynthesizer), availableVoices];
        let count: usize = msg_send![voices, count];
        let key_id = nsstring("VoiceIdentifier");
        let key_name = nsstring("VoiceName");
        let key_loc = nsstring("VoiceLocaleIdentifier");

        // println!("[tts:desktop] voices available: {count}");
        for i in 0..count {
            let voice_id: id = msg_send![voices, objectAtIndex: i];
            let attrs: id = msg_send![class!(NSSpeechSynthesizer), attributesForVoice: voice_id];

            let id_ns: id = msg_send![attrs, objectForKey: key_id];
            let name_ns: id = msg_send![attrs, objectForKey: key_name];
            let loc_ns: id = msg_send![attrs, objectForKey: key_loc];

            let id_s = if id_ns == nil {
                "<nil>".into()
            } else {
                nsstring_to_rust(id_ns)
            };
            let name_s = if name_ns == nil {
                "<nil>".into()
            } else {
                nsstring_to_rust(name_ns)
            };
            let loc_s = if loc_ns == nil {
                "<nil>".into()
            } else {
                nsstring_to_rust(loc_ns)
            };

            // println!("  - {i:02}: {id_s} | {name_s} | {loc_s}");
        }
    }

    /// Return a voice identifier (NSString*) whose locale matches `lang` (exact or base),
    /// or `None` to let the system pick.
    unsafe fn pick_voice_by_lang(lang: Option<&str>) -> Option<id> {
        let voices: id = msg_send![class!(NSSpeechSynthesizer), availableVoices];
        let count: usize = msg_send![voices, count];

        let (want_norm, maybe_exact_hint) = match lang {
            Some(w) => normalize_want(w),
            None => (String::new(), None),
        };
        let key_locale = nsstring("VoiceLocaleIdentifier");

        // 1) Try exact-tag match first (if we have an exact hint like "fa-ir")
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
                    // println!("[tts:desktop] pick: exact hint matched -> {locale}");
                    return Some(voice_id);
                }
            }
        }

        if want_norm.is_empty() {
            return None;
        }

        // 2) Try exact locale (e.g., "fa-ir")
        for i in 0..count {
            let voice_id: id = msg_send![voices, objectAtIndex: i];
            let attrs: id = msg_send![class!(NSSpeechSynthesizer), attributesForVoice: voice_id];
            let locale_ns: id = msg_send![attrs, objectForKey: key_locale];
            if locale_ns == nil {
                continue;
            }
            let locale = norm(&nsstring_to_rust(locale_ns));
            if locale == want_norm {
                // println!("[tts:desktop] pick: exact match -> {locale}");
                return Some(voice_id);
            }
        }

        // 3) Base match (e.g., "fa" matches "fa-ir", "fa-af")
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
                // println!("[tts:desktop] pick: base match -> {locale}");
                return Some(voice_id);
            }
        }

        None
    }

    pub(super) fn macos_speak(text: &str, language: Option<&str>) -> crate::Result<()> {
        unsafe {
            println!("[tts:desktop] requested language: {:?}", language);
            log_all_voices();

            // Make a synth per call
            let alloc: id = msg_send![class!(NSSpeechSynthesizer), alloc];
            let synth: id = msg_send![alloc, init];

            if let Some(voice_id) = pick_voice_by_lang(language) {
                let ok: bool = msg_send![synth, setVoice: voice_id];
                if ok {
                    let key_id = nsstring("VoiceIdentifier");
                    let key_name = nsstring("VoiceName");
                    let key_loc = nsstring("VoiceLocaleIdentifier");
                    let attrs: id =
                        msg_send![class!(NSSpeechSynthesizer), attributesForVoice: voice_id];
                    let id_ns: id = msg_send![attrs, objectForKey: key_id];
                    let name_ns: id = msg_send![attrs, objectForKey: key_name];
                    let loc_ns: id = msg_send![attrs, objectForKey: key_loc];
                    let id_s = if id_ns == nil {
                        "<nil>".into()
                    } else {
                        nsstring_to_rust(id_ns)
                    };
                    let name_s = if name_ns == nil {
                        "<nil>".into()
                    } else {
                        nsstring_to_rust(name_ns)
                    };
                    let loc_s_raw = if loc_ns == nil {
                        "<nil>".into()
                    } else {
                        nsstring_to_rust(loc_ns)
                    };
                    let loc_s = norm(&loc_s_raw);
                    // println!("[tts:desktop] setVoice OK -> {id_s} | {name_s} | {loc_s}");
                } else {
                    // println!("[tts:desktop] setVoice returned false; using system default");
                }
            } else {
                // println!("[tts:desktop] no matching voice; using system default");
            }

            let ns_text = nsstring(text);
            let started: bool = msg_send![synth, startSpeakingString: ns_text];
            // println!("[tts:desktop] startSpeakingString -> {started}");
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
use macos_impl::macos_speak;
