use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
pub struct SpeakArgs {
    pub text: String,
    pub language: Option<String>,
    pub rate: Option<f32>, // NEW (optional)
}
