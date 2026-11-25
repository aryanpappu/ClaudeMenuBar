//! Read and change Claude Code's optional model override.

use crate::storage::{load_settings, save_settings, settings_target};
use serde_json::Value;
use std::{io, path::Path};

pub fn get_model(settings_path: &Path) -> Option<String> {
    let (mut settings, _) = load_settings(settings_path, false).ok()?;
    match settings.shift_remove("model") {
        Some(Value::String(model)) => Some(model),
        _ => None,
    }
}

pub fn set_model(settings_path: &Path, model: Option<&str>) -> io::Result<()> {
    let path = settings_target(settings_path)?;
    let (mut settings, original) = load_settings(&path, false)?;
    match model {
        Some(model) => {
            settings.insert("model".into(), Value::String(model.into()));
        }
        None => {
            settings.shift_remove("model");
        }
    }
    save_settings(&path, &settings, original.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::TestDir;
    use std::fs;

    #[test]
    fn model_edits_reject_invalid_settings() {
        let dir = TestDir::new();
        let path = dir.0.join("settings.json");
        set_model(&path, Some("sonnet")).unwrap();
        assert_eq!(get_model(&path).as_deref(), Some("sonnet"));
        set_model(&path, None).unwrap();
        assert_eq!(get_model(&path), None);
        for data in ["", "[]", "{invalid}"] {
            fs::write(&path, data).unwrap();
            assert!(set_model(&path, Some("sonnet")).is_err());
            assert_eq!(fs::read_to_string(&path).unwrap(), data);
        }
    }
}
