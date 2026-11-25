//! Shared same-directory replacement and settings-file handling.

use serde_json::{Map, Value};
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU32, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

pub(crate) type Settings = Map<String, Value>;

pub(crate) fn invalid(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

fn parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

pub(crate) fn unique_stamp() -> String {
    static SEQUENCE: AtomicU32 = AtomicU32::new(0);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    format!("{nanos}-{}-{}", std::process::id(), SEQUENCE.fetch_add(1, Ordering::Relaxed))
}

pub(crate) fn atomic_replace(
    path: &Path,
    data: &[u8],
    should_replace: impl FnOnce() -> io::Result<bool>,
) -> io::Result<()> {
    let temp = parent(path).join(format!(".claudemenubar-{}.tmp", unique_stamp()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temp)?;
    let written = file.write_all(data);
    drop(file);
    let result = written.and_then(|()| {
        if should_replace()? {
            // std::fs::rename replaces an existing file on Unix and Windows.
            fs::rename(&temp, path)
        } else {
            fs::remove_file(&temp)
        }
    });
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

pub(crate) fn settings_target(path: &Path) -> io::Result<PathBuf> {
    let mut target = path.to_path_buf();
    for _ in 0..40 {
        match fs::canonicalize(&target) {
            Ok(path) => return Ok(path),
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            Err(_) => {}
        }
        match fs::read_link(&target) {
            Ok(link) => target = parent(&target).join(link),
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(target),
            Err(error) => return Err(error),
        }
    }
    Err(invalid("too many settings symlinks"))
}

pub(crate) fn load_settings(path: &Path, allow_blank: bool) -> io::Result<(Settings, Option<Vec<u8>>)> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok((Map::new(), None)),
        Err(error) => return Err(error),
    };
    let blank = allow_blank && std::str::from_utf8(&bytes).is_ok_and(|text| text.trim().is_empty());
    let settings = if blank {
        Map::new()
    } else {
        match serde_json::from_slice(&bytes).map_err(invalid)? {
            Value::Object(settings) => settings,
            _ => return Err(invalid("settings must be a JSON object")),
        }
    };
    Ok((settings, Some(bytes)))
}

pub(crate) fn save_settings(path: &Path, settings: &Settings, original: Option<&[u8]>) -> io::Result<()> {
    fs::create_dir_all(parent(path))?;
    let mut bytes = serde_json::to_vec_pretty(settings).map_err(invalid)?;
    bytes.push(b'\n');
    atomic_replace(path, &bytes, || {
        let current = match fs::read(path) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        if current.as_deref() != original {
            return Err(io::Error::new(io::ErrorKind::WouldBlock, "settings changed during edit"));
        }
        Ok(true)
    })
}

#[cfg(test)]
pub(crate) struct TestDir(pub PathBuf);

#[cfg(test)]
impl TestDir {
    pub fn new() -> Self {
        let path = std::env::temp_dir().join(format!("claudemenubar-test-{}", unique_stamp()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

#[cfg(test)]
impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
