//! Classifies Claude Code hook payloads and reads or writes v1 session files.

use crate::storage::{atomic_replace, invalid};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{fs, io, path::Path};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Done,
    Running,
    Waiting,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Approval,
    Question,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionFile {
    pub v: u32,
    pub session_id: String,
    pub state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<Kind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    pub ts: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Write(SessionFile),
    Delete(String),
    Nothing,
}

pub fn is_safe_id(id: &str) -> bool {
    (1..=100).contains(&id.len())
        && id.bytes().all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, b'_' | b'-'))
}

fn request(text: &str) -> Option<String> {
    (!text.is_empty()).then(|| text.chars().take(40).collect())
}

fn tool_from_message(message: &str) -> Option<String> {
    let (_, tool) = message.split_once("to use ")?;
    request(tool.trim_matches(|ch: char| ch.is_whitespace() || matches!(ch, '.' | ',' | ':' | ';')))
}

/// Pass `None` only for terminal input. An empty pipe is an invalid payload.
pub fn classify(command: &str, stdin: Option<&[u8]>, now_ms: u64) -> Action {
    let payload = match stdin {
        None => None,
        Some(bytes) => match serde_json::from_slice::<Value>(bytes) {
            Ok(Value::Object(object)) => Some(object),
            _ => return Action::Nothing,
        },
    };
    let get = |key: &str| payload.as_ref()?.get(key)?.as_str();
    let id = match payload {
        None => "manual",
        Some(_) => match get("session_id") {
            Some(id) if is_safe_id(id) => id,
            _ => return Action::Nothing,
        },
    };
    let state = match command {
        "end" => return Action::Delete(id.to_owned()),
        "running" => State::Running,
        "waiting" => State::Waiting,
        "done" => State::Done,
        "idle" => State::Idle,
        _ => return Action::Nothing,
    };
    let event = get("hook_event_name");
    let message = get("message").unwrap_or_default();
    let (kind, request) = if state == State::Waiting && payload.is_some() {
        if event == Some("PermissionRequest") {
            (Some(Kind::Approval), get("tool_name").and_then(request))
        } else {
            match payload.as_ref().and_then(|object| object.get("notification_type")) {
                Some(Value::String(kind)) if kind == "permission_prompt" => {
                    (Some(Kind::Approval), tool_from_message(message))
                }
                Some(Value::String(kind)) if matches!(kind.as_str(), "elicitation_dialog" | "agent_needs_input") => {
                    (Some(Kind::Question), None)
                }
                None if message.to_ascii_lowercase().contains("permission") => {
                    (Some(Kind::Approval), tool_from_message(message))
                }
                _ => return Action::Nothing,
            }
        }
    } else {
        (None, None)
    };
    let path_field = |key| {
        get(key)
            .filter(|text| !text.is_empty() && text.chars().take(1025).count() <= 1024)
            .map(str::to_owned)
    };
    Action::Write(SessionFile {
        v: 1,
        session_id: id.to_owned(),
        state,
        kind,
        request,
        cwd: path_field("cwd"),
        transcript_path: path_field("transcript_path"),
        event: event.map(|text| text.chars().take(40).collect()),
        ts: now_ms,
    })
}

fn file_name(id: &str) -> String {
    format!("{id}.json")
}

pub(crate) fn read_file(path: &Path) -> Option<SessionFile> {
    let name = path.file_name()?.to_str()?;
    if name.starts_with('.') || !name.ends_with(".json") {
        return None;
    }
    let session: SessionFile = serde_json::from_slice(&fs::read(path).ok()?).ok()?;
    (session.v == 1 && is_safe_id(&session.session_id) && name == file_name(&session.session_id))
        .then_some(session)
}

pub fn write_atomic(dir: &Path, session: &SessionFile) -> io::Result<()> {
    if !is_safe_id(&session.session_id) || session.v != 1 {
        return Err(invalid("invalid v1 session file"));
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(dir)?;
    let path = dir.join(file_name(&session.session_id));
    let data = serde_json::to_vec(session).map_err(invalid)?;
    atomic_replace(&path, &data, || {
        let existing = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Value>(&bytes).ok(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        let ts = existing.as_ref().and_then(|value| value.get("ts")).and_then(Value::as_u64);
        Ok(!ts.is_some_and(|ts| ts > session.ts))
    })
}

pub fn delete(dir: &Path, id: &str) -> io::Result<()> {
    if !is_safe_id(id) {
        return Err(invalid("unsafe session id"));
    }
    match fs::remove_file(dir.join(file_name(id))) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

pub fn read_all(dir: &Path) -> Vec<SessionFile> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    entries.filter_map(Result::ok).filter_map(|entry| {
        // Skip directories, symlinks, and special files such as named pipes.
        if !entry.file_type().ok()?.is_file() {
            return None;
        }
        read_file(&entry.path())
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::TestDir;

    #[test]
    fn shared_vectors() {
        let vectors: Vec<Value> = serde_json::from_str(include_str!("../../../protocol/vectors.json")).unwrap();
        for case in vectors {
            let dir = TestDir::new();
            let path = dir.0.join("s1.json");
            let existing = case.get("existing");
            if let Some(file) = existing {
                fs::write(&path, serde_json::to_vec(file).unwrap()).unwrap();
            }
            let mut payload = case["stdin"].clone();
            if payload["cwd"] == "LONG1100" {
                payload["cwd"] = Value::String(format!("/{}", "a".repeat(1100)));
            }
            let bytes = match case["stdin_raw"].as_str() {
                Some(raw) => raw.as_bytes().to_vec(),
                None => serde_json::to_vec(&payload).unwrap(),
            };
            let cmd = case["args"][0].as_str().unwrap();
            let action = classify(cmd, Some(&bytes), 10);
            match &action {
                Action::Write(file) => write_atomic(&dir.0, file).unwrap(),
                Action::Delete(id) => delete(&dir.0, id).unwrap(),
                Action::Nothing => {}
            }
            let expected = &case["expect"];
            let name = &case["name"];
            match expected.as_str() {
                Some("none") | Some("deleted") => {
                    assert!(!path.exists(), "{name}");
                    if cmd == "end" {
                        assert_eq!(action, Action::Delete("s1".into()), "{name}");
                    } else {
                        assert_eq!(action, Action::Nothing, "{name}");
                    }
                }
                _ => {
                    assert!(matches!(action, Action::Write(_)), "{name}");
                    let got: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
                    assert_eq!(got["v"], 1, "{name}");
                    assert_eq!(got["session_id"], "s1", "{name}");
                    for (key, value) in expected.as_object().unwrap() {
                        assert_eq!(&got[key], value, "{name}: {key}");
                        if value.is_null() {
                            assert!(got.get(key).is_none(), "{name}: {key}");
                        }
                    }
                    assert_eq!(got["ts"].as_u64(), Some(expected["ts"].as_u64().unwrap_or(10)), "{name}");
                    assert_eq!(read_all(&dir.0).len(), 1, "{name}");
                }
            }
            assert_eq!(fs::read_dir(&dir.0).unwrap().count(), path.exists() as usize, "{name}");
        }
    }

    #[test]
    fn terminal_and_character_limits() {
        let Action::Write(file) = classify("waiting", None, 42) else { panic!("expected manual session") };
        assert_eq!(file.session_id, "manual");
        assert_eq!(file.kind, None);
        assert_eq!(classify("running", Some(b""), 42), Action::Nothing);
        let payload = serde_json::json!({
            "session_id": "unicode",
            "hook_event_name": "PermissionRequest",
            "tool_name": "界".repeat(41),
            "cwd": "界".repeat(1024)
        });
        let Action::Write(file) = classify("waiting", Some(&serde_json::to_vec(&payload).unwrap()), 42)
            else { panic!("expected Unicode session") };
        assert_eq!(file.request, Some("界".repeat(40)));
        assert_eq!(file.cwd, Some("界".repeat(1024)));
    }
}
