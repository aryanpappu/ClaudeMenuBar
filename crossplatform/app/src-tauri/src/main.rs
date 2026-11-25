//! Claude Menu Bar for Windows and Linux: a tray icon plus a small always-on-top
//! panel showing every Claude Code session (working / waiting / done).
//!
//! Data flow (docs/PROTOCOL.md): Claude Code hooks → `claude-notify` → one JSON
//! file per session in the sessions folder → this app polls the folder once a
//! second → `SessionStore` (shared reducer in claude_menubar_core) → tray icon,
//! banners and the "snapshot" event rendered by ui/app.js.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod focus;

use claude_menubar_core::{
    model, paths,
    protocol::{self, Kind, SessionFile, State},
    sessions::{self, Event, SessionStore},
    usage::UsageTracker,
};
use chrono::{Datelike, Duration as ChronoDuration, Local, TimeZone};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{
    image::Image,
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, PhysicalPosition, RunEvent, WindowEvent, Wry,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};
use tauri_plugin_notification::NotificationExt;

const PANEL: &str = "panel";
const TRAY: &str = "main";
const MODELS: [&str; 3] = ["haiku", "sonnet", "opus"];
const TRANSCRIPT_TAIL: u64 = 64 * 1024;

// MARK: State

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
struct Prefs {
    muted: bool,
    rain_muted: bool,
    notifications: bool,
    show_panel: bool,
    sections: BTreeMap<String, bool>,
}

impl Default for Prefs {
    fn default() -> Self {
        let sections = ["sessions", "model", "activity"].iter().map(|s| (s.to_string(), true)).collect();
        Prefs { muted: false, rain_muted: false, notifications: true, show_panel: true, sections }
    }
}

/// Git branch and title for a session row, read from its transcript.
#[derive(Clone, Default)]
struct Extra {
    branch: Option<String>,
    title: Option<String>,
}

struct Inner {
    store: SessionStore,
    extra: HashMap<String, Extra>,
    usage: Option<UsageTracker>,
    today: usize,
    week: usize,
    model: Option<String>,
    prefs: Prefs,
    prefs_path: Option<PathBuf>,
    sessions_dir: Option<PathBuf>,
    settings_path: Option<PathBuf>,
    projects_root: Option<PathBuf>,
    tray_state: Option<State>,
}

struct AppData(Mutex<Inner>);

impl AppData {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

struct TrayItems {
    notifications: CheckMenuItem<Wry>,
}

// MARK: Snapshot sent to the UI

#[derive(Serialize, Clone)]
struct SessionView {
    id: String,
    name: String,
    cwd: Option<String>,
    state: State,
    kind: Option<Kind>,
    request: Option<String>,
    branch: Option<String>,
    title: Option<String>,
    last_activity_ms: u64,
}

#[derive(Serialize, Clone)]
struct Snapshot {
    state: State,
    sessions: Vec<SessionView>,
    today: usize,
    week: usize,
    model: Option<String>,
    prefs: Prefs,
    can_open: bool,
}

fn project_name(session: &SessionFile) -> String {
    session
        .cwd
        .as_deref()
        .and_then(|cwd| Path::new(cwd).file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| session.session_id.chars().take(8).collect())
}

fn snapshot(inner: &Inner) -> Snapshot {
    let mut sessions: Vec<SessionView> = inner
        .store
        .sessions
        .values()
        .map(|s| {
            let extra = inner.extra.get(&s.session_id).cloned().unwrap_or_default();
            SessionView {
                id: s.session_id.clone(),
                name: project_name(s),
                cwd: s.cwd.clone(),
                state: s.state,
                kind: s.kind,
                request: s.request.clone(),
                branch: extra.branch,
                title: extra.title,
                last_activity_ms: s.ts,
            }
        })
        .collect();
    // Waiting first, then working, done, idle; newest first within a state.
    sessions.sort_by(|a, b| b.state.cmp(&a.state).then(b.last_activity_ms.cmp(&a.last_activity_ms)));
    Snapshot {
        state: inner.store.aggregate_state(),
        sessions,
        today: inner.today,
        week: inner.week,
        model: inner.model.clone(),
        prefs: inner.prefs.clone(),
        can_open: can_focus_windows(),
    }
}

fn can_focus_windows() -> bool {
    if cfg!(windows) {
        return true;
    }
    std::env::var_os("DISPLAY").is_some()
}

// MARK: Helpers

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Local midnight today and local Monday 00:00 this week, in Unix ms.
fn day_and_week_start() -> (u64, u64) {
    let now = Local::now();
    let midnight = now.date_naive().and_hms_opt(0, 0, 0).unwrap_or_default();
    let day = Local.from_local_datetime(&midnight).earliest().map_or(0, |d| d.timestamp_millis());
    let monday = midnight - ChronoDuration::days(i64::from(now.weekday().num_days_from_monday()));
    let week = Local.from_local_datetime(&monday).earliest().map_or(0, |d| d.timestamp_millis());
    (day.max(0) as u64, week.max(0) as u64)
}

fn save_prefs(inner: &Inner) {
    let Some(path) = &inner.prefs_path else { return };
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_vec_pretty(&inner.prefs) {
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, json).is_ok() {
            let _ = fs::rename(&tmp, path);
        }
    }
}

/// Reads branch + title from the last 64 KB of a transcript. Only files under
/// ~/.claude/projects ending in .jsonl are read (file contents are untrusted).
fn read_extra(projects_root: Option<&Path>, transcript: Option<&str>) -> Extra {
    let (Some(root), Some(path)) = (projects_root, transcript) else { return Extra::default() };
    let Ok(resolved) = fs::canonicalize(path) else { return Extra::default() };
    if !resolved.starts_with(root) || resolved.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Extra::default();
    }
    let Ok(mut file) = fs::File::open(&resolved) else { return Extra::default() };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    if file.seek(SeekFrom::Start(len.saturating_sub(TRANSCRIPT_TAIL))).is_err() {
        return Extra::default();
    }
    let mut bytes = Vec::new();
    if file.take(TRANSCRIPT_TAIL).read_to_end(&mut bytes).is_err() {
        return Extra::default();
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut extra = Extra::default();
    for line in text.lines().rev() {
        let Ok(serde_json::Value::Object(obj)) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let text_of = |key: &str| obj.get(key).and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(str::to_string);
        if extra.branch.is_none() {
            extra.branch = text_of("gitBranch").map(|b| b.chars().take(60).collect());
        }
        if extra.title.is_none() {
            extra.title = text_of("aiTitle").or_else(|| text_of("lastPrompt")).map(|t| t.chars().take(60).collect());
        }
        if extra.branch.is_some() && extra.title.is_some() {
            break;
        }
    }
    extra
}

/// Banner text when a session enters waiting or done (None = no banner).
fn banner(session: &SessionFile) -> Option<(String, String)> {
    let name = project_name(session);
    match session.state {
        State::Waiting => Some(match (session.kind, &session.request) {
            (Some(Kind::Question), _) => (format!("{name} has a question"), "Claude needs your answer".into()),
            (_, Some(tool)) => (format!("{name}: approval needed"), format!("Wants to use {tool}")),
            _ => (format!("{name}: approval needed"), "Claude needs your permission".into()),
        }),
        State::Done => Some((name, "Task finished".into())),
        _ => None,
    }
}

// MARK: Background loop

fn tick(app: &AppHandle, n: u64) {
    let data = app.state::<AppData>();
    let mut banners = Vec::new();
    let mut emit = None;
    let mut tray = None;
    {
        let mut inner = data.lock();
        let now = now_ms();
        let mut changed = n == 0;

        if let Some(dir) = inner.sessions_dir.clone() {
            let events = inner.store.sync_from_files(protocol::read_all(&dir), now);
            for event in events {
                changed = true;
                match event {
                    Event::Added { session, silent } => {
                        if !silent {
                            banners.extend(banner(&session));
                        }
                        let extra = read_extra(inner.projects_root.as_deref(), session.transcript_path.as_deref());
                        inner.extra.insert(session.session_id.clone(), extra);
                    }
                    Event::Changed { old, new } => {
                        if old.state != new.state {
                            banners.extend(banner(&new));
                        }
                        let extra = read_extra(inner.projects_root.as_deref(), new.transcript_path.as_deref());
                        inner.extra.insert(new.session_id.clone(), extra);
                    }
                    Event::Removed { session } => {
                        inner.extra.remove(&session.session_id);
                    }
                }
            }
            if n % 3600 == 0 {
                let _ = sessions::cleanup_old_files(&dir, now);
            }
        }

        if n % 5 == 0 {
            if inner.store.sweep(now) {
                changed = true;
                let alive: Vec<String> = inner.store.sessions.keys().cloned().collect();
                inner.extra.retain(|id, _| alive.contains(id));
            }
            let (day, week) = day_and_week_start();
            if let Some(Ok(counts)) = inner.usage.as_mut().map(|u| u.poll(day, week)) {
                if (counts.today, counts.week) != (inner.today, inner.week) {
                    (inner.today, inner.week) = (counts.today, counts.week);
                    changed = true;
                }
            }
            let current = inner.settings_path.as_deref().and_then(model::get_model);
            if current != inner.model {
                inner.model = current;
                changed = true;
            }
        }

        if !inner.prefs.notifications {
            banners.clear();
        }
        if changed {
            let snap = snapshot(&inner);
            if inner.tray_state != Some(snap.state) {
                inner.tray_state = Some(snap.state);
                tray = Some((snap.state, snap.sessions.len()));
            }
            emit = Some(snap);
        }
    }

    for (title, body) in banners {
        let _ = app.notification().builder().title(title).body(body).show();
    }
    if let Some((state, count)) = tray {
        update_tray(app, state, count);
    }
    if let Some(snap) = emit {
        let _ = app.emit("snapshot", snap);
    }
}

fn tray_image(state: State) -> Option<Image<'static>> {
    let bytes: &'static [u8] = match state {
        State::Idle => include_bytes!("../icons/tray/idle@2x.png"),
        State::Running => include_bytes!("../icons/tray/running@2x.png"),
        State::Waiting => include_bytes!("../icons/tray/waiting@2x.png"),
        State::Done => include_bytes!("../icons/tray/done@2x.png"),
    };
    Image::from_bytes(bytes).ok()
}

fn update_tray(app: &AppHandle, state: State, count: usize) {
    let Some(tray) = app.tray_by_id(TRAY) else { return };
    let label = match state {
        State::Idle => "Ready",
        State::Running => "Working",
        State::Waiting => "Waiting for you",
        State::Done => "Done",
    };
    let _ = tray.set_icon(tray_image(state));
    let _ = tray.set_tooltip(Some(format!("Claude Menu Bar: {label} ({count} sessions)")));
}

// MARK: Panel window

fn place_panel(app: &AppHandle) {
    let Some(win) = app.get_webview_window(PANEL) else { return };
    let monitor = win.current_monitor().ok().flatten().or_else(|| win.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    // Before the window is first shown some platforms report a 0x0 size, so
    // fall back to the configured size (tauri.conf.json: 300 x 480).
    let size = win
        .outer_size()
        .ok()
        .filter(|s| s.width >= 100 && s.height >= 100)
        .unwrap_or_else(|| tauri::PhysicalSize::new((300.0 * scale) as u32, (480.0 * scale) as u32));
    let margin = (16.0 * scale) as i32;
    let taskbar = (56.0 * scale) as i32; // keep clear of a bottom taskbar/panel
    let area = monitor.size();
    let origin = monitor.position();
    let x = origin.x + area.width as i32 - size.width as i32 - margin;
    let y = origin.y + area.height as i32 - size.height as i32 - taskbar;
    let _ = win.set_position(PhysicalPosition::new(x.max(origin.x), y.max(origin.y)));
}

fn set_panel_visible(app: &AppHandle, visible: bool) {
    if let Some(win) = app.get_webview_window(PANEL) {
        if visible {
            let _ = win.show();
            let _ = win.set_always_on_top(true);
        } else {
            let _ = win.hide();
        }
    }
    let data = app.state::<AppData>();
    let mut inner = data.lock();
    if inner.prefs.show_panel != visible {
        inner.prefs.show_panel = visible;
        save_prefs(&inner);
    }
}

fn toggle_panel(app: &AppHandle) {
    let visible = app.get_webview_window(PANEL).and_then(|w| w.is_visible().ok()).unwrap_or(false);
    set_panel_visible(app, !visible);
}

// MARK: Commands (called from ui/app.js)

#[tauri::command]
fn get_snapshot(data: tauri::State<'_, AppData>) -> Snapshot {
    snapshot(&data.lock())
}

#[tauri::command]
fn set_model(app: AppHandle, data: tauri::State<'_, AppData>, model: Option<String>) -> Result<(), String> {
    if let Some(m) = &model {
        if !MODELS.contains(&m.as_str()) {
            return Err(format!("Unknown model {m}"));
        }
    }
    let snap = {
        let mut inner = data.lock();
        let path = inner.settings_path.clone().ok_or("Can't find ~/.claude/settings.json")?;
        model::set_model(&path, model.as_deref()).map_err(|e| format!("Couldn't change the model: {e}"))?;
        inner.model = model;
        snapshot(&inner)
    };
    let _ = app.emit("snapshot", snap);
    Ok(())
}

#[tauri::command]
fn set_pref(app: AppHandle, data: tauri::State<'_, AppData>, key: String, value: bool) -> Result<(), String> {
    let snap = {
        let mut inner = data.lock();
        match key.as_str() {
            "muted" => inner.prefs.muted = value,
            "rain_muted" => inner.prefs.rain_muted = value,
            "notifications" => inner.prefs.notifications = value,
            k => match k.strip_prefix("section_") {
                Some(section @ ("sessions" | "model" | "activity")) => {
                    inner.prefs.sections.insert(section.to_string(), value);
                }
                _ => return Err(format!("Unknown setting {key}")),
            },
        }
        save_prefs(&inner);
        snapshot(&inner)
    };
    if key == "notifications" {
        if let Some(items) = app.try_state::<TrayItems>() {
            let _ = items.notifications.set_checked(value);
        }
    }
    let _ = app.emit("snapshot", snap);
    Ok(())
}

/// Returns true if a matching window was brought to the front.
#[tauri::command]
fn open_session(data: tauri::State<'_, AppData>, id: String) -> bool {
    let name = data.lock().store.sessions.get(&id).map(project_name);
    name.is_some_and(|n| focus::focus_window(&n))
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    set_panel_visible(&app, false);
}

// MARK: Setup

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let notifications_on = app.state::<AppData>().lock().prefs.notifications;
    let autostart_on = app.autolaunch().is_enabled().unwrap_or(false);
    let show = MenuItem::with_id(app, "show", "Show / hide panel", true, None::<&str>)?;
    let notifications = CheckMenuItem::with_id(app, "notifications", "Notifications", true, notifications_on, None::<&str>)?;
    let autostart = CheckMenuItem::with_id(app, "autostart", "Start at login", true, autostart_on, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Claude Menu Bar", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&show, &notifications, &autostart, &separator, &quit])?;
    app.manage(TrayItems { notifications: notifications.clone() });

    let mut builder = TrayIconBuilder::with_id(TRAY)
        .tooltip("Claude Menu Bar")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(move |app, event| match event.id().as_ref() {
            "show" => toggle_panel(app),
            "notifications" => {
                let on = notifications.is_checked().unwrap_or(true);
                let data = app.state::<AppData>();
                let mut inner = data.lock();
                inner.prefs.notifications = on;
                save_prefs(&inner);
                let _ = app.emit("snapshot", snapshot(&inner));
            }
            "autostart" => {
                let launcher = app.autolaunch();
                let _ = if autostart.is_checked().unwrap_or(false) { launcher.enable() } else { launcher.disable() };
                let _ = autostart.set_checked(launcher.is_enabled().unwrap_or(false));
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                toggle_panel(tray.app_handle());
            }
        });
    if let Some(icon) = tray_image(State::Idle) {
        builder = builder.icon(icon);
    }
    builder.build(app)?;
    Ok(())
}

fn main() {
    let claude_dir = paths::claude_dir().ok();
    let inner = Inner {
        store: SessionStore::default(),
        extra: HashMap::new(),
        usage: paths::history_path().ok().map(UsageTracker::new),
        today: 0,
        week: 0,
        model: None,
        prefs: Prefs::default(),
        prefs_path: None,
        sessions_dir: paths::sessions_dir().ok(),
        settings_path: paths::settings_path().ok(),
        projects_root: claude_dir.and_then(|d| fs::canonicalize(d.join("projects")).ok()),
        tray_state: None,
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| set_panel_visible(app, true)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(AppData(Mutex::new(inner)))
        .invoke_handler(tauri::generate_handler![get_snapshot, set_model, set_pref, open_session, hide_panel])
        .setup(|app| {
            let handle = app.handle().clone();
            {
                let data = handle.state::<AppData>();
                let mut inner = data.lock();
                if let Ok(dir) = handle.path().app_config_dir() {
                    let path = dir.join("prefs.json");
                    if let Some(prefs) = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()) {
                        inner.prefs = prefs;
                    }
                    inner.prefs_path = Some(path);
                }
                if let Some(dir) = &inner.sessions_dir {
                    let _ = fs::create_dir_all(dir);
                }
            }
            build_tray(&handle)?;
            if let Some(win) = handle.get_webview_window(PANEL) {
                let hide_handle = handle.clone();
                win.on_window_event(move |event| {
                    // Closing the panel (Alt+F4) hides it; the app lives in the tray.
                    if let WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        set_panel_visible(&hide_handle, false);
                    }
                });
            }
            let show = handle.state::<AppData>().lock().prefs.show_panel;
            set_panel_visible(&handle, show);
            place_panel(&handle);

            thread::spawn(move || {
                let mut n: u64 = 0;
                loop {
                    tick(&handle, n);
                    n = n.wrapping_add(1);
                    thread::sleep(Duration::from_secs(1));
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Claude Menu Bar")
        .run(|_app, event| {
            // Keep running in the tray when the panel is hidden.
            if let RunEvent::ExitRequested { api, code: None, .. } = event {
                api.prevent_exit();
            }
        });
}
