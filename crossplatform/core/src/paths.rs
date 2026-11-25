//! Platform defaults for Claude Code and Claude Menu Bar files.

use std::{env, io, path::PathBuf};

fn env_dir(key: &str) -> io::Result<PathBuf> {
    env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("{key} is unset")))
}

fn home_dir() -> io::Result<PathBuf> {
    env_dir(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
}

pub fn sessions_dir() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("CLAUDE_MENUBAR_DIR").map(PathBuf::from) {
        if path.is_absolute() {
            return Ok(path);
        }
    }
    let base = if cfg!(windows) {
        env_dir("LOCALAPPDATA")?.join("ClaudeMenuBar")
    } else {
        home_dir()?.join(".claude-menubar")
    };
    Ok(base.join("sessions"))
}

pub fn claude_dir() -> io::Result<PathBuf> {
    Ok(home_dir()?.join(".claude"))
}

pub fn settings_path() -> io::Result<PathBuf> {
    Ok(claude_dir()?.join("settings.json"))
}

pub fn history_path() -> io::Result<PathBuf> {
    Ok(claude_dir()?.join("history.jsonl"))
}
