//! Install, remove, and validate Claude Menu Bar entries in Claude Code settings.

use crate::storage::{invalid, load_settings, save_settings, settings_target, unique_stamp, Settings};
use serde_json::{json, Value};
use std::{fs, io::{self, Write}, iter::Peekable, path::{Path, PathBuf}, str::Chars};

const EVENTS: [(&str, &str); 6] = [
    ("UserPromptSubmit", "running"),
    ("PreToolUse", "running"),
    ("PermissionRequest", "waiting"),
    ("Notification", "waiting"),
    ("Stop", "done"),
    ("SessionEnd", "end"),
];

#[derive(Debug, Default)]
pub struct Report {
    pub changes: Vec<String>,
    pub backup: Option<PathBuf>,
}

pub fn quote_posix(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// Quote an executable path for the platform's hook shell.
pub fn quote_helper(path: &Path) -> io::Result<String> {
    let path = path.to_str().ok_or_else(|| invalid("helper path is not UTF-8"))?;
    Ok(if cfg!(windows) {
        format!("\"{}\"", path.replace('\\', "/"))
    } else {
        quote_posix(path)
    })
}

/// Read a single shell word, including the adjacent quoted fragments that
/// POSIX quoting uses for paths containing an apostrophe.
fn word(input: &mut Peekable<Chars<'_>>) -> Option<String> {
    while input.peek().is_some_and(|ch| ch.is_whitespace()) {
        input.next();
    }
    input.peek()?;
    let mut word = String::new();
    while input.peek().is_some_and(|ch| !ch.is_whitespace()) {
        match input.next()? {
            quote @ ('\'' | '"') => loop {
                let ch = input.next()?;
                if ch == quote {
                    break;
                }
                word.push(ch);
            },
            '\\' if input.peek() == Some(&'\'') => {
                input.next();
                word.push('\'');
            }
            ';' | '|' | '&' | '<' | '>' | '`' | '$' | '(' | ')' | '*' | '?' | '[' | ']' => return None,
            ch => word.push(ch),
        }
    }
    Some(word)
}

fn owned_command(command: &str) -> Option<()> {
    let command = command.trim();
    if command.contains(['\r', '\n']) {
        return None;
    }
    let has_env_prefix = command.starts_with("CLAUDE_MENUBAR_DIR=");
    let mut input = command.chars().peekable();
    let mut helper = word(&mut input)?;
    if has_env_prefix {
        if helper.strip_prefix("CLAUDE_MENUBAR_DIR=")?.is_empty() {
            return None;
        }
        helper = word(&mut input)?;
    }
    let basename = helper.rsplit(['/', '\\']).next()?;
    if !matches!(basename, "claude-notify" | "claude-notify.exe") {
        return None;
    }
    // The state is a literal word and no other shell tokens may follow it.
    let remainder: String = input.collect();
    matches!(remainder.trim(), "running" | "waiting" | "done" | "idle" | "end").then_some(())
}

fn is_ours(hook: &Value) -> bool {
    hook.get("type").and_then(Value::as_str) == Some("command")
        && hook.get("command").and_then(Value::as_str).and_then(owned_command).is_some()
}

fn hooks_object(value: &mut Value) -> io::Result<&mut Settings> {
    value.as_object_mut().ok_or_else(|| invalid("hooks must be a JSON object"))
}

fn groups_array(value: &mut Value) -> io::Result<&mut Vec<Value>> {
    value.as_array_mut().ok_or_else(|| invalid("hook event must contain an array of groups"))
}

fn commands(group: &Value) -> impl Iterator<Item = &Value> {
    group.get("hooks").and_then(Value::as_array).into_iter().flatten()
}

/// Validate the settings file as the Python installer's check command does.
pub fn check(settings_path: &Path) -> io::Result<()> {
    load_settings(&settings_target(settings_path)?, true).map(|_| ())
}

/// Append missing hooks. The prefix is already shell-quoted and may include
/// the WSL environment assignment produced by the CLI.
pub fn install(settings_path: &Path, helper_command_prefix: &str, dry_run: bool) -> io::Result<Report> {
    edit(settings_path, dry_run, |settings| {
        let hooks = hooks_object(settings.entry("hooks").or_insert_with(|| json!({})))?;
        let mut changes = Vec::new();
        for (event, state) in EVENTS {
            let groups = groups_array(hooks.entry(event).or_insert_with(|| json!([])))?;
            if groups.iter().flat_map(commands).any(is_ours) {
                continue;
            }
            let command = format!("{helper_command_prefix} {state}");
            groups.push(json!({
                "matcher": "",
                "hooks": [{"type": "command", "command": command}]
            }));
            changes.push(format!("+ {event}: claude-notify {state}"));
        }
        Ok(changes)
    })
}

pub fn uninstall(settings_path: &Path, dry_run: bool) -> io::Result<Report> {
    edit(settings_path, dry_run, |settings| {
        let Some(hooks) = settings.get_mut("hooks") else { return Ok(Vec::new()) };
        let hooks = hooks_object(hooks)?;
        let mut changes = Vec::new();
        let mut empty_events = Vec::new();
        for (event, groups) in hooks.iter_mut() {
            let groups = groups_array(groups)?;
            let mut touched = false;
            groups.retain_mut(|group| {
                let Some(commands) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
                    return true;
                };
                let before = commands.len();
                commands.retain(|command| !is_ours(command));
                if commands.len() == before {
                    return true;
                }
                touched = true;
                changes.push(format!("- {event}: claude-notify"));
                !commands.is_empty()
            });
            if touched && groups.is_empty() {
                empty_events.push(event.clone());
            }
        }
        for event in empty_events {
            hooks.shift_remove(&event);
        }
        if !changes.is_empty() && hooks.is_empty() {
            settings.shift_remove("hooks");
        }
        Ok(changes)
    })
}

fn edit(
    settings_path: &Path,
    dry_run: bool,
    update: impl FnOnce(&mut Settings) -> io::Result<Vec<String>>,
) -> io::Result<Report> {
    let path = settings_target(settings_path)?;
    let (mut settings, original) = load_settings(&path, true)?;
    let changes = update(&mut settings)?;
    let mut report = Report { changes, backup: None };
    if dry_run || report.changes.is_empty() {
        return Ok(report);
    }
    if let Some(bytes) = &original {
        let mut backup = path.as_os_str().to_owned();
        backup.push(format!(".bak-claudemenubar-{}", unique_stamp()));
        let backup = PathBuf::from(backup);
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&backup)?;
        let result = file.write_all(bytes);
        drop(file);
        if let Err(error) = result {
            let _ = fs::remove_file(&backup);
            return Err(error);
        }
        report.backup = Some(backup);
    }
    save_settings(&path, &settings, original.as_deref())?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::TestDir;

    #[test]
    fn install_uninstall_roundtrip() {
        let dir = TestDir::new();
        let path = dir.0.join("settings.json");
        let original = json!({"z":42,"hooks":{"PreToolUse":[
            {"matcher":"Bash","hooks":[{"type":"command","command":"echo claude-notify running"}],"extra":true},
            {"matcher":"Read","extra":7}
        ]},"a":true});
        let bytes = serde_json::to_vec_pretty(&original).unwrap();
        fs::write(&path, &bytes).unwrap();
        let prefix = format!("CLAUDE_MENUBAR_DIR={} {}", quote_posix("/tmp/Mike's sessions"), quote_posix("/home/Mike's bin/claude-notify"));
        check(&path).unwrap();
        assert_eq!(install(&path, &prefix, true).unwrap().changes.len(), 6);
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
        let report = install(&path, &prefix, false).unwrap();
        assert_eq!(report.changes.len(), 6);
        assert_eq!(fs::read(report.backup.unwrap()).unwrap(), bytes);
        assert!(install(&path, &prefix, false).unwrap().changes.is_empty());
        assert_eq!(uninstall(&path, true).unwrap().changes.len(), 6);
        assert_eq!(uninstall(&path, false).unwrap().changes.len(), 6);
        let (result, _) = load_settings(&path, false).unwrap();
        assert_eq!(serde_json::to_vec_pretty(&result).unwrap(), bytes);
        assert!(uninstall(&path, false).unwrap().changes.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn follows_a_symlink_to_missing_settings() {
        use std::os::unix::fs::symlink;

        let dir = TestDir::new();
        let link = dir.0.join("settings.json");
        let target = dir.0.join("config").join("shared.json");
        symlink("config/shared.json", &link).unwrap();
        assert_eq!(install(&link, "claude-notify", false).unwrap().changes.len(), 6);
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert!(target.is_file());
        assert_eq!(uninstall(&link, false).unwrap().changes.len(), 6);
        assert_eq!(fs::read_to_string(target).unwrap(), "{}\n");
    }

    #[test]
    fn ownership_requires_exact_command() {
        for command in ["claude-notify idle", "\"C:/Program Files/claude-notify.exe\" done", "C:\\Apps\\claude-notify.exe end"] {
            assert!(owned_command(command).is_some(), "{command}");
        }
        for command in ["echo claude-notify idle", "other-claude-notify done", "claude-notify end; echo x", "claude-notify idle extra", "helper;claude-notify running"] {
            assert!(owned_command(command).is_none(), "{command}");
        }
    }
}
