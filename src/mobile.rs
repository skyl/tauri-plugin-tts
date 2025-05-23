use crate::models::*;
use serde::de::DeserializeOwned;
use tauri::{
    plugin::{PluginApi, PluginHandle},
    AppHandle, Runtime,
};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_tts);

// This struct must match your mobile plugin argument structure!
#[derive(serde::Serialize)]
pub struct SpeakArgs {
    pub text: String,
    pub language: Option<String>,
}

pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<Tts<R>> {
    #[cfg(target_os = "android")]
    let handle =
        api.register_android_plugin("space.httpjames.tauri_plugin_tts", "ExamplePlugin")?;
    #[cfg(target_os = "ios")]
    let handle = api.register_ios_plugin(init_plugin_tts)?;
    Ok(Tts(handle))
}

/// Access to the tts APIs.
pub struct Tts<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> Tts<R> {
    pub fn speak(&self, text: String, language: Option<String>) -> crate::Result<()> {
        println!(
            "Starting speak operation with text: {}, language: {:?}",
            text, language
        );
        let args = SpeakArgs { text, language };
        self.0.run_mobile_plugin("speak", Some(args)).map_err(|e| {
            println!("Speech error: {:?}", e); // Debug log
            e.into()
        })
    }

    pub fn stop(&self) -> crate::Result<()> {
        self.0.run_mobile_plugin("stop", Some(())).map_err(|e| {
            println!("Stop speech error: {:?}", e); // Debug log
            e.into()
        })
    }
}
