use crate::{Result, TtsExt};
use tauri::{command, AppHandle, Runtime};

#[command]
pub(crate) async fn speak<R: Runtime>(
    app: AppHandle<R>,
    text: String,
    language: Option<String>,
    rate: Option<f32>, // keep optional for backwards-compat
) -> Result<()> {
    app.tts().speak(text, language, rate)
}

#[command]
pub(crate) async fn stop<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.tts().stop()
}
