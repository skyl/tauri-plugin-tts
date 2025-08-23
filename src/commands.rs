use crate::Result;
use crate::TtsExt;
use tauri::{command, AppHandle, Runtime};

#[command]
pub(crate) async fn speak<R: Runtime>(
    app: AppHandle<R>,
    text: String,
    language: Option<String>,
    rate: Option<f32>, // <-- NEW (optional)
) -> Result<()> {
    #[cfg(desktop)]
    {
        app.tts().speak(text, language, rate) // desktop expects rate
    }
    #[cfg(mobile)]
    {
        app.tts().speak(text, language) // mobile signature unchanged (BC)
    }
}

#[command]
pub(crate) async fn stop<R: Runtime>(app: AppHandle<R>) -> Result<()> {
    app.tts().stop()
}
