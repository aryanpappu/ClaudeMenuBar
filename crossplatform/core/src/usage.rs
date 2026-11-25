//! Incrementally count newline-terminated history records by timestamp.
//! The caller supplies the local midnight and Monday boundaries in Unix ms.

use std::{fs::{File, Metadata}, io::{self, Read, Seek, SeekFrom}, path::{Path, PathBuf}};
#[cfg(not(unix))]
use std::time::SystemTime;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Counts {
    pub today: usize,
    pub week: usize,
}

#[cfg(unix)]
type Identity = (u64, u64);
#[cfg(not(unix))]
type Identity = (Option<SystemTime>, u64, Option<SystemTime>);

#[cfg(unix)]
fn identity(metadata: &Metadata) -> Identity {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(not(unix))]
fn identity(metadata: &Metadata) -> Identity {
    (metadata.created().ok(), metadata.len(), metadata.modified().ok())
}

#[cfg(unix)]
fn replaced(old: Identity, new: Identity) -> bool {
    old != new
}

#[cfg(not(unix))]
fn replaced(old: Identity, new: Identity) -> bool {
    match (old.0, new.0) {
        (Some(before), Some(after)) if before != after => true,
        _ => new.1 < old.1 || (new.1 == old.1 && old.2 != new.2),
    }
}

#[derive(Debug)]
pub struct UsageTracker {
    path: PathBuf,
    offset: u64,
    partial_line: Vec<u8>,
    identity: Option<Identity>,
    timestamps: Vec<f64>,
    retained_since: u64,
}

impl UsageTracker {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            offset: 0,
            partial_line: Vec::new(),
            identity: None,
            timestamps: Vec::new(),
            retained_since: 0,
        }
    }

    fn reset(&mut self) {
        self.offset = 0;
        self.partial_line.clear();
        self.identity = None;
        self.timestamps.clear();
        self.retained_since = 0;
    }

    pub fn poll(&mut self, day_start_ms: u64, week_start_ms: u64) -> io::Result<Counts> {
        let mut file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.reset();
                return Ok(Counts::default());
            }
            Err(error) => return Err(error),
        };
        let metadata = file.metadata()?;
        let current = identity(&metadata);
        if metadata.len() < self.offset
            || self.identity.is_some_and(|old| replaced(old, current))
            || week_start_ms < self.retained_since
        {
            self.reset();
        }

        if metadata.len() > self.offset {
            file.seek(SeekFrom::Start(self.offset))?;
            let mut chunk = Vec::new();
            file.take(metadata.len() - self.offset).read_to_end(&mut chunk)?;
            self.offset += chunk.len() as u64;
            self.partial_line.extend_from_slice(&chunk);
            let mut lines = self.partial_line.split_inclusive(|byte| *byte == b'\n');
            let mut consumed = 0;
            for line in &mut lines {
                if !line.ends_with(b"\n") {
                    break;
                }
                consumed += line.len();
                let Ok(record) = serde_json::from_slice::<serde_json::Value>(line) else {
                    continue;
                };
                if let Some(ts) = record.get("timestamp").and_then(serde_json::Value::as_f64) {
                    if ts >= week_start_ms as f64 {
                        self.timestamps.push(ts);
                    }
                }
            }
            self.partial_line.drain(..consumed);
        }
        self.identity = Some(current);
        self.retained_since = week_start_ms;
        self.timestamps.retain(|ts| *ts >= week_start_ms as f64);
        Ok(self.counts(day_start_ms, week_start_ms))
    }

    /// Recount cached records after midnight without touching the file.
    /// Call poll if the week boundary moves earlier than a previous poll.
    pub fn counts(&self, day_start_ms: u64, week_start_ms: u64) -> Counts {
        let mut counts = Counts::default();
        for &ts in &self.timestamps {
            if ts >= week_start_ms as f64 {
                counts.week += 1;
                counts.today += (ts >= day_start_ms as f64) as usize;
            }
        }
        counts
    }
}

pub fn count_prompts(path: &Path, day_start_ms: u64, week_start_ms: u64) -> io::Result<Counts> {
    UsageTracker::new(path).poll(day_start_ms, week_start_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::TestDir;
    use std::{fs, io::Write};

    #[test]
    fn append_partial_record_then_truncate_and_delete() {
        let dir = TestDir::new();
        let path = dir.0.join("history.jsonl");
        let mut tracker = UsageTracker::new(path.as_path());
        assert_eq!(tracker.poll(20, 10).unwrap(), Counts::default());
        fs::write(&path, b"{\"timestamp\":10}\ninvalid\n{\"timestamp\":2").unwrap();
        assert_eq!(tracker.poll(20, 10).unwrap(), Counts { today: 0, week: 1 });
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(b"0}\n").unwrap();
        drop(file);
        assert_eq!(tracker.poll(20, 10).unwrap(), Counts { today: 1, week: 2 });
        assert_eq!(tracker.counts(21, 10), Counts { today: 0, week: 2 });
        fs::write(&path, b"{\"timestamp\":30}\n").unwrap();
        assert_eq!(tracker.poll(20, 10).unwrap(), Counts { today: 1, week: 1 });
        fs::remove_file(&path).unwrap();
        assert_eq!(tracker.poll(20, 10).unwrap(), Counts::default());
    }
}
