use crate::{Result, TtsExt};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{command, AppHandle, Runtime};

#[command]
pub(crate) async fn speak<R: Runtime>(
    app: AppHandle<R>,
    text: String,
    language: Option<String>,
    rate: Option<f32>, // keep optional for backwards-compat
) -> Result<()> {
    // Debounce state (static for plugin lifetime)
    static mut LAST_SPEAK_TIME: u128 = 0;
    const DEBOUNCE_MS: u128 = 500; // 500ms debounce window

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards")
        .as_millis();

    println!(
        "[NATIVE_TTS:DEBUG] speak invoked: text='{}', lang={:?}, rate={:?}, time_since_last={}ms",
        text.chars().take(50).collect::<String>(),
        language,
        rate,
        now.saturating_sub(unsafe { LAST_SPEAK_TIME })
    );

    // Check debounce (using unsafe for static mut; safe in single-threaded context)
    if unsafe { now.saturating_sub(LAST_SPEAK_TIME) < DEBOUNCE_MS } {
        println!("[NATIVE_TTS:DEBUG] speak debounced: too soon after last call");
        return Ok(());
    }
    unsafe { LAST_SPEAK_TIME = now };

    app.tts().speak(text, language, rate)
}

#[command]
pub(crate) async fn stop<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    println!("[NATIVE_TTS:DEBUG] stop invoked");
    app.tts().stop()
}
