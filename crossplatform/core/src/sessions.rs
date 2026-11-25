//! In-memory session reducer with caller-supplied time, plus file expiry.

use crate::protocol::{read_file, SessionFile, State};
use std::{collections::BTreeMap, fs, io, path::Path};

const DONE_MS: u64 = 30_000;
const IDLE_MS: u64 = 10 * 60_000;
const RUNNING_MS: u64 = 30 * 60_000;
const FILE_MS: u64 = 24 * 60 * 60_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Added { session: SessionFile, silent: bool },
    Changed { old: SessionFile, new: SessionFile },
    Removed { session: SessionFile },
}

#[derive(Debug, Default)]
pub struct SessionStore {
    pub sessions: BTreeMap<String, SessionFile>,
    pub last_ts: BTreeMap<String, u64>,
    last_seen: BTreeMap<String, SessionFile>,
    loaded: bool,
}

impl SessionStore {
    /// Reconcile a complete snapshot. The first snapshot emits silent additions.
    /// Sweep separately to update display ages without producing hook events.
    pub fn sync_from_files(&mut self, files: Vec<SessionFile>, _now: u64) -> Vec<Event> {
        let silent = !self.loaded;
        self.loaded = true;
        let mut snapshot = BTreeMap::<String, SessionFile>::new();
        for file in files {
            if snapshot.get(&file.session_id).is_some_and(|seen| seen.ts > file.ts) {
                continue;
            }
            snapshot.insert(file.session_id.clone(), file);
        }

        let mut events = Vec::new();
        self.sessions.retain(|id, session| {
            if snapshot.contains_key(id) {
                true
            } else {
                events.push(Event::Removed { session: session.clone() });
                false
            }
        });
        for (id, file) in snapshot {
            if self.last_ts.get(&id).is_some_and(|ts| {
                *ts > file.ts || (*ts == file.ts && self.last_seen.get(&id) == Some(&file))
            }) {
                continue;
            }
            self.last_ts.insert(id.clone(), file.ts);
            self.last_seen.insert(id.clone(), file.clone());
            match self.sessions.insert(id, file.clone()) {
                Some(old) => events.push(Event::Changed { old, new: file }),
                None => events.push(Event::Added { session: file, silent }),
            }
        }
        events
    }

    pub fn sweep(&mut self, now: u64) -> bool {
        let mut changed = false;
        self.sessions.retain(|_, session| {
            let age = now.saturating_sub(session.ts);
            if session.state == State::Done && age >= DONE_MS {
                session.state = State::Idle;
                changed = true;
            }
            let drop = match session.state {
                State::Idle => age >= IDLE_MS,
                State::Running => age >= RUNNING_MS,
                State::Done | State::Waiting => false,
            };
            changed |= drop;
            !drop
        });
        changed
    }

    pub fn aggregate_state(&self) -> State {
        self.sessions.values().map(|session| session.state).max().unwrap_or(State::Idle)
    }
}

/// Delete expired v1 files, checking the timestamp again just before removal.
pub fn cleanup_old_files(dir: &Path, now: u64) -> io::Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let expired = |file: SessionFile| now.saturating_sub(file.ts) > FILE_MS;
    for entry in entries {
        let entry = entry?;
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if !file_type.is_file() {
            continue;
        }
        let path = entry.path();
        if read_file(&path).ok().flatten().is_some_and(expired)
            && read_file(&path).ok().flatten().is_some_and(expired)
        {
            match fs::remove_file(&path) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                result => result?,
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(id: &str, state: State, ts: u64) -> SessionFile {
        SessionFile {
            v: 1, session_id: id.into(), state, ts, kind: None, request: None,
            cwd: None, transcript_path: None, event: None,
        }
    }

    #[test]
    fn silent_load_ordering_and_disappearance() {
        let mut store = SessionStore::default();
        let start = file("s", State::Running, 10);
        assert_eq!(store.sync_from_files(vec![start.clone()], 15),
                   vec![Event::Added { session: start.clone(), silent: true }]);
        assert!(store.sync_from_files(vec![file("s", State::Done, 9), start.clone()], 16).is_empty());
        let done = file("s", State::Done, 17);
        assert_eq!(store.sync_from_files(vec![done.clone()], 17),
                   vec![Event::Changed { old: start, new: done.clone() }]);
        assert_eq!(store.sync_from_files(vec![], 18), vec![Event::Removed { session: done }]);
        let waiting = file("s", State::Waiting, 19);
        assert_eq!(store.sync_from_files(vec![waiting.clone()], 19),
                   vec![Event::Added { session: waiting, silent: false }]);
    }

    #[test]
    fn equal_timestamp_applies_changed_file_once() {
        let mut store = SessionStore::default();
        let start = file("s", State::Running, 10);
        let done = file("s", State::Done, 10);
        assert_eq!(store.sync_from_files(vec![start.clone()], 10),
                   vec![Event::Added { session: start.clone(), silent: true }]);
        assert_eq!(store.sync_from_files(vec![done.clone()], 10),
                   vec![Event::Changed { old: start, new: done.clone() }]);
        assert!(store.sync_from_files(vec![done.clone()], 10).is_empty());
        assert!(store.sweep(10 + DONE_MS));
        assert!(store.sync_from_files(vec![done], 10 + DONE_MS).is_empty());
        assert_eq!(store.sessions["s"].state, State::Idle);
    }

    #[test]
    fn ageing_and_aggregate_priority() {
        let ts = 100;
        let files = vec![
            file("done", State::Done, ts),
            file("idle", State::Idle, ts),
            file("running", State::Running, ts),
            file("waiting", State::Waiting, ts),
        ];
        let mut store = SessionStore::default();
        store.sync_from_files(files.clone(), ts);
        assert_eq!(store.aggregate_state(), State::Waiting);
        assert!(!store.sweep(ts - 1));
        assert!(store.sweep(ts + DONE_MS));
        assert_eq!(store.sessions["done"].state, State::Idle);
        assert!(store.sweep(ts + IDLE_MS));
        assert_eq!(store.sessions.len(), 2);
        assert!(store.sweep(ts + RUNNING_MS));
        assert!(store.sync_from_files(files, ts + RUNNING_MS).is_empty());
        assert_eq!(store.sessions.len(), 1);
        store.sync_from_files(vec![], ts + RUNNING_MS);
        assert_eq!(store.aggregate_state(), State::Idle);
    }
}
