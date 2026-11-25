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
    hooks, model, paths,
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
    setup_hint_shown: bool,
}

impl Default for Prefs {
    fn default() -> Self {
        let sections = ["sessions", "model", "activity"].iter().map(|s| (s.to_string(), true)).collect();
        Prefs { muted: false, rain_muted: false, notifications: true, show_panel: true, sections, setup_hint_shown: false }
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
    rev: u64,
    today: usize,
    week: usize,
    model: Option<String>,
    prefs: Prefs,
    prefs_path: Option<PathBuf>,
    sessions_dir: Option<PathBuf>,
    settings_path: Option<PathBuf>,
    tray_state: Option<State>,
}

/// `inner` is held only briefly and never during disk I/O; the usage reader
/// has its own lock because polling it reads history.jsonl.
struct AppData {
    inner: Mutex<Inner>,
    usage: Mutex<Option<UsageTracker>>,
}

impl AppData {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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
    /// Increases with every snapshot; the UI ignores one older than it has.
    rev: u64,
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

fn snapshot(inner: &mut Inner) -> Snapshot {
    inner.rev += 1;
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
        rev: inner.rev,
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

/// `~/.claude/projects`, resolved each time: Claude Code may create it after
/// the app started.
fn projects_root() -> Option<PathBuf> {
    paths::claude_dir().ok().and_then(|d| fs::canonicalize(d.join("projects")).ok())
}

/// Reads branch + title from the last 64 KB of a transcript. Only regular
/// .jsonl files under ~/.claude/projects are read (paths come from untrusted
/// session files; a FIFO would block the reader).
fn read_extra(transcript: Option<&str>) -> Extra {
    let (Some(root), Some(path)) = (projects_root(), transcript) else { return Extra::default() };
    let Ok(resolved) = fs::canonicalize(path) else { return Extra::default() };
    if !resolved.starts_with(&root) || resolved.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Extra::default();
    }
    if !fs::metadata(&resolved).is_ok_and(|m| m.is_file()) {
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
    let now = now_ms();
    let slow = n % 5 == 0;
    let (dir, settings) = {
        let inner = data.lock();
        (inner.sessions_dir.clone(), inner.settings_path.clone())
    };

    // 1. Disk reads, without holding the state lock.
    // A failed scan is skipped: it must not look like every session ended.
    let files = dir.as_deref().and_then(|d| protocol::scan(d).ok());
    let model_now = slow.then(|| settings.as_deref().and_then(model::get_model));
    let counts = if slow {
        let (day, week) = day_and_week_start();
        let mut usage = data.usage.lock().unwrap_or_else(|p| p.into_inner());
        usage.as_mut().and_then(|u| u.poll(day, week).ok())
    } else {
        None
    };
    if n % 3600 == 0 {
        if let Some(d) = &dir {
            let _ = sessions::cleanup_old_files(d, now);
        }
    }

    // 2. Apply under the lock.
    let mut banners = Vec::new();
    let mut to_enrich = Vec::new();
    let mut changed = n == 0;
    {
        let mut inner = data.lock();
        if let Some(files) = files {
            for event in inner.store.sync_from_files(files, now) {
                changed = true;
                match event {
                    Event::Added { session, silent } => {
                        if !silent {
                            banners.extend(banner(&session));
                        }
                        to_enrich.push((session.session_id.clone(), session.transcript_path.clone()));
                    }
                    Event::Changed { old, new } => {
                        if old.state != new.state {
                            banners.extend(banner(&new));
                        }
                        to_enrich.push((new.session_id.clone(), new.transcript_path.clone()));
                    }
                    Event::Removed { session } => {
                        inner.extra.remove(&session.session_id);
                    }
                }
            }
        }
        if slow && inner.store.sweep(now) {
            changed = true;
            let alive: Vec<String> = inner.store.sessions.keys().cloned().collect();
            inner.extra.retain(|id, _| alive.contains(id));
        }
        if let Some(c) = counts {
            if (c.today, c.week) != (inner.today, inner.week) {
                (inner.today, inner.week) = (c.today, c.week);
                changed = true;
            }
        }
        if let Some(m) = model_now {
            if m != inner.model {
                inner.model = m;
                changed = true;
            }
        }
        if !inner.prefs.notifications {
            banners.clear();
        }
    }

    // 3. Transcript reads (branch, title), again without the lock.
    if !to_enrich.is_empty() {
        let extras: Vec<(String, Extra)> =
            to_enrich.into_iter().map(|(id, path)| (id, read_extra(path.as_deref()))).collect();
        let mut inner = data.lock();
        for (id, extra) in extras {
            if inner.store.sessions.contains_key(&id) {
                inner.extra.insert(id, extra);
            }
        }
    }

    for (title, body) in banners {
        let _ = app.notification().builder().title(title).body(body).show();
    }
    if changed {
        let (snap, tray) = {
            let mut inner = data.lock();
            let snap = snapshot(&mut inner);
            let tray = (inner.tray_state != Some(snap.state)).then(|| (snap.state, snap.sessions.len()));
            inner.tray_state = Some(snap.state);
            (snap, tray)
        };
        if let Some((state, count)) = tray {
            update_tray(app, state, count);
        }
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
    let _ = tray.set_tooltip(Some(format!("Claude Menu Bar: {label} ({count} sessions). Menu: Show / hide panel")));
}

// MARK: Panel window

/// Bottom-right of the usable screen area (inside taskbars and docks).
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
    let area = monitor.work_area();
    let margin = (12.0 * scale) as i32;
    let x = area.position.x + area.size.width as i32 - size.width as i32 - margin;
    let y = area.position.y + area.size.height as i32 - size.height as i32 - margin;
    let _ = win.set_position(PhysicalPosition::new(x.max(area.position.x), y.max(area.position.y)));
}

fn set_panel_visible(app: &AppHandle, visible: bool) {
    if let Some(win) = app.get_webview_window(PANEL) {
        if visible {
            let _ = win.show();
            place_panel(app);
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

// MARK: Hook setup (tray menu)

const HELPER_NAME: &str = if cfg!(windows) { "claude-notify.exe" } else { "claude-notify" };

/// The helper shipped inside the installed app (Tauri `externalBin`, placed
/// next to the main executable).
fn bundled_helper() -> Option<PathBuf> {
    let path = std::env::current_exe().ok()?.parent()?.join(HELPER_NAME);
    path.is_file().then_some(path)
}

/// Where hooks point to. A fixed path, because the app's own location can
/// change (AppImage mounts at a new path on every launch, updates move files).
fn stable_helper_path() -> Option<PathBuf> {
    if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("ClaudeMenuBar").join("bin").join(HELPER_NAME))
    } else {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("bin").join(HELPER_NAME))
    }
}

fn setup_hooks() -> Result<String, String> {
    let source = bundled_helper().ok_or("The claude-notify helper is missing from this installation.")?;
    let target = stable_helper_path().ok_or("Can't find your home folder.")?;
    if let Some(dir) = target.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("Can't create {}: {e}", dir.display()))?;
    }
    if source != target {
        let tmp = target.with_extension("new");
        fs::copy(&source, &tmp).map_err(|e| format!("Can't copy the helper: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755));
        }
        fs::rename(&tmp, &target).map_err(|e| format!("Can't install the helper: {e}"))?;
    }
    let settings = paths::settings_path().map_err(|e| e.to_string())?;
    let prefix = hooks::quote_helper(&target).map_err(|e| e.to_string())?;
    let report = hooks::install(&settings, &prefix, false).map_err(|e| format!("Couldn't update {}: {e}", settings.display()))?;
    Ok(if report.changes.is_empty() {
        "Claude Code hooks were already set up.".into()
    } else {
        format!("Added {} Claude Code hooks. Restart running Claude Code sessions to pick them up.", report.changes.len())
    })
}

fn remove_hooks() -> Result<String, String> {
    let settings = paths::settings_path().map_err(|e| e.to_string())?;
    let report = hooks::uninstall(&settings, false).map_err(|e| format!("Couldn't update {}: {e}", settings.display()))?;
    Ok(if report.changes.is_empty() { "No Claude Menu Bar hooks were found.".into() } else { "Claude Code hooks removed.".into() })
}

fn tell(app: &AppHandle, result: Result<String, String>) {
    let (title, body) = match result {
        Ok(msg) => ("Claude Menu Bar", msg),
        Err(msg) => ("Claude Menu Bar: something went wrong", msg),
    };
    let _ = app.notification().builder().title(title).body(body).show();
}

// MARK: Commands (called from ui/app.js)

#[tauri::command]
fn get_snapshot(data: tauri::State<'_, AppData>) -> Snapshot {
    snapshot(&mut data.lock())
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
        snapshot(&mut inner)
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
        snapshot(&mut inner)
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
    let setup = MenuItem::with_id(app, "setup_hooks", "Set up Claude Code hooks", true, None::<&str>)?;
    let remove = MenuItem::with_id(app, "remove_hooks", "Remove Claude Code hooks", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Claude Menu Bar", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&show, &notifications, &autostart, &sep1, &setup, &remove, &sep2, &quit])?;
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
                let _ = app.emit("snapshot", snapshot(&mut inner));
            }
            "autostart" => {
                let launcher = app.autolaunch();
                let _ = if autostart.is_checked().unwrap_or(false) { launcher.enable() } else { launcher.disable() };
                let _ = autostart.set_checked(launcher.is_enabled().unwrap_or(false));
            }
            "setup_hooks" => tell(app, setup_hooks()),
            "remove_hooks" => tell(app, remove_hooks()),
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
    let inner = Inner {
        store: SessionStore::default(),
        extra: HashMap::new(),
        rev: 0,
        today: 0,
        week: 0,
        model: None,
        prefs: Prefs::default(),
        prefs_path: None,
        sessions_dir: paths::sessions_dir().ok(),
        settings_path: paths::settings_path().ok(),
        tray_state: None,
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| set_panel_visible(app, true)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(AppData {
            inner: Mutex::new(inner),
            usage: Mutex::new(paths::history_path().ok().map(UsageTracker::new)),
        })
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
            // First launch: point people at the one-time hook setup.
            {
                let data = handle.state::<AppData>();
                let mut inner = data.lock();
                if !inner.prefs.setup_hint_shown {
                    inner.prefs.setup_hint_shown = true;
                    save_prefs(&inner);
                    let _ = handle
                        .notification()
                        .builder()
                        .title("Claude Menu Bar is running")
                        .body("Open the tray menu and choose \"Set up Claude Code hooks\" once.")
                        .show();
                }
            }
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
