use crate::models::VoiceInfo;
use crate::{Result, TtsExt};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{command, AppHandle, Runtime};

/// Speak text using native TTS.
/// - Back-compat: `language` and `rate` remain optional.
/// - New: `voice_id` lets the UI request a specific voice (platform-specific identifier).
#[command]
pub(crate) async fn speak<R: Runtime>(
    app: AppHandle<R>,
    text: String,
    language: Option<String>,
    rate: Option<f32>,        // keep optional for backwards-compat
    voice_id: Option<String>, // NEW: platform-specific voice identifier
) -> Result<()> {
    // Debounce state (static for plugin lifetime)
    static mut LAST_SPEAK_TIME: u128 = 0;
    const DEBOUNCE_MS: u128 = 500; // 500ms debounce window

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards")
        .as_millis();

    println!(
        "[NATIVE_TTS:DEBUG] speak invoked: text='{}', lang={:?}, rate={:?}, voice_id={:?}, time_since_last={}ms",
        text.chars().take(50).collect::<String>(),
        language,
        rate,
        voice_id,
        now.saturating_sub(unsafe { LAST_SPEAK_TIME })
    );

    // Check debounce (using unsafe for static mut; safe in single-threaded context)
    if unsafe { now.saturating_sub(LAST_SPEAK_TIME) < DEBOUNCE_MS } {
        println!("[NATIVE_TTS:DEBUG] speak debounced: too soon after last call");
        return Ok(());
    }
    unsafe { LAST_SPEAK_TIME = now };

    // Prefer the new, voice-aware path if supported by the platform; otherwise fall back.
    if let Err(e) =
        app.tts()
            .speak_with_options(text.clone(), language.clone(), rate, voice_id.clone())
    {
        println!("[NATIVE_TTS:DEBUG] speak_with_options failed ({e:?}); falling back to speak()");
        app.tts().speak(text, language, rate)
    } else {
        Ok(())
    }
}

#[command]
pub(crate) async fn stop<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    println!("[NATIVE_TTS:DEBUG] stop invoked");
    app.tts().stop()
}

/// Open the closest-possible system UI for managing/downloading TTS voices.
#[command]
pub(crate) async fn open_tts_settings<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    println!("[NATIVE_TTS:DEBUG] open_tts_settings invoked");
    app.tts().open_tts_settings()
}

/// Best-effort programmatic voice install (Android only).
/// - Returns `true` if a request was issued to the system/engine.
/// - Returns `false` on platforms that don't support programmatic install or if no activity could be started.
#[command]
pub(crate) async fn install_tts_data_if_supported<R: Runtime>(app: AppHandle<R>) -> Result<bool> {
    println!("[NATIVE_TTS:DEBUG] install_tts_data_if_supported invoked");
    app.tts().install_tts_data_if_supported()
}

/// Enumerate installed/available voices with cross-platform metadata.
#[command]
pub(crate) async fn list_voices<R: Runtime>(app: AppHandle<R>) -> Result<Vec<VoiceInfo>> {
    println!("[NATIVE_TTS:DEBUG] list_voices invoked");
    app.tts().list_voices()
}
