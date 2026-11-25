//! "Open": bring the terminal or editor window of a session to the front.
//!
//! Like the macOS app, a window counts only if its title contains the project
//! folder name as a whole word ("api" does not match "rapid-api-tests").
//! - Windows: EnumWindows + SetForegroundWindow. Allowed because the user has
//!   just clicked our panel, so we own the foreground.
//! - Linux X11: `wmctrl` (if installed).
//! - Linux Wayland: not possible (compositors don't let apps raise others);
//!   returns false and the panel copies the project path instead.

/// Case-insensitive whole-word match of `name` inside `title`.
pub fn title_matches(title: &str, name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let title = title.to_lowercase();
    let name = name.to_lowercase();
    let is_word = |c: char| c.is_alphanumeric() || matches!(c, '_' | '.' | '-');
    let mut start = 0;
    while let Some(pos) = title[start..].find(&name) {
        let begin = start + pos;
        let end = begin + name.len();
        let before_ok = title[..begin].chars().next_back().map_or(true, |c| !is_word(c));
        let after_ok = title[end..].chars().next().map_or(true, |c| !is_word(c));
        if before_ok && after_ok {
            return true;
        }
        // Advance by one character (not one byte) to stay on a char boundary.
        start = begin + title[begin..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

const OWN_TITLE: &str = "Claude Menu Bar";

#[cfg(windows)]
pub fn focus_window(name: &str) -> bool {
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowTextLengthW, GetWindowTextW, IsIconic, IsWindowVisible,
        SetForegroundWindow, ShowWindow, SW_RESTORE,
    };

    struct Search {
        name: String,
        found: Vec<HWND>,
    }

    unsafe extern "system" fn visit(hwnd: HWND, lparam: LPARAM) -> BOOL {
        // SAFETY: lparam is the &mut Search passed to EnumWindows below, which
        // outlives the (synchronous) enumeration.
        let search = unsafe { &mut *(lparam as *mut Search) };
        unsafe {
            if IsWindowVisible(hwnd) == 0 {
                return 1;
            }
            let len = GetWindowTextLengthW(hwnd);
            if len <= 0 {
                return 1;
            }
            let mut buf = vec![0u16; len as usize + 1];
            let copied = GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32);
            let title = String::from_utf16_lossy(&buf[..copied.max(0) as usize]);
            if title != OWN_TITLE && title_matches(&title, &search.name) {
                search.found.push(hwnd);
            }
        }
        1
    }

    let mut search = Search { name: name.to_string(), found: Vec::new() };
    // SAFETY: `visit` only dereferences lparam as the Search above.
    unsafe {
        EnumWindows(Some(visit), &mut search as *mut Search as LPARAM);
    }
    let Some(&hwnd) = search.found.first() else { return false };
    unsafe {
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        SetForegroundWindow(hwnd) != 0
    }
}

#[cfg(target_os = "linux")]
pub fn focus_window(name: &str) -> bool {
    use std::process::Command;
    let wayland_only = std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("DISPLAY").is_none();
    if wayland_only {
        return false;
    }
    // `wmctrl -l`: "0x04000007  0 host Window title"
    let Ok(out) = Command::new("wmctrl").arg("-l").output() else { return false };
    if !out.status.success() {
        return false;
    }
    let list = String::from_utf8_lossy(&out.stdout);
    let window = list.lines().find_map(|line| {
        // id, desktop, host, then the title words
        let mut words = line.split_whitespace();
        let id = words.next()?;
        let _desktop = words.next()?;
        let _host = words.next()?;
        let title = words.collect::<Vec<_>>().join(" ");
        (title != OWN_TITLE && title_matches(&title, name)).then(|| id.to_string())
    });
    match window {
        Some(id) => Command::new("wmctrl").args(["-i", "-a", &id]).status().is_ok_and(|s| s.success()),
        None => false,
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn focus_window(_name: &str) -> bool {
    false // macOS uses the native Swift app
}

#[cfg(test)]
mod tests {
    use super::title_matches;

    #[test]
    fn whole_word_only() {
        assert!(title_matches("my-app — bash", "my-app"));
        assert!(title_matches("~/code/My-App: claude", "my-app"));
        assert!(title_matches("api", "api"));
        assert!(!title_matches("rapid-api-tests", "api"));
        assert!(!title_matches("api_v2", "api"));
        assert!(title_matches("ÄÖ api", "api"));
        assert!(!title_matches("anything", ""));
    }
}
