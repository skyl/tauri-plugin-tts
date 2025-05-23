use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

use crate::models::*;

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
        Ok(())
    }

    pub fn stop(&self) -> crate::Result<()> {
        Ok(())
    }
}
