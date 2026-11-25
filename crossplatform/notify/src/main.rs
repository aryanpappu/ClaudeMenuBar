//! Silent hook entry point and interactive hook settings commands.

use claude_menubar_core::{hooks, paths, protocol::{self, Action}};
use std::{
    env,
    io::{self, IsTerminal, Read, Write},
    path::PathBuf,
    process::{Command, ExitCode},
    time::{SystemTime, UNIX_EPOCH},
};

const HELP: &str = "\
Usage: claude-notify <running|waiting|done|idle|end>
       claude-notify install-hooks [--dry-run] [--wsl]
       claude-notify uninstall-hooks [--dry-run]
       claude-notify check-hooks
       claude-notify --version | --help";

fn main() -> ExitCode {
    let started = SystemTime::now();
    let mut args = env::args_os().skip(1);
    let command = args.next();
    let command = command.as_deref().and_then(|arg| arg.to_str());
    if let Some(command @ ("running" | "waiting" | "done" | "idle" | "end")) = command {
        let now_ms = started.duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        if let Err(error) = run_hook(command, now_ms) {
            let _ = writeln!(io::stderr().lock(), "claude-notify: {error}");
        }
        return ExitCode::SUCCESS;
    }

    let args: Vec<_> = args.collect();
    let dry_run = args.iter().any(|arg| arg == "--dry-run");
    let wsl = args.iter().any(|arg| arg == "--wsl");
    let result = match command {
        Some("--help") if args.is_empty() => {
            println!("{HELP}");
            Ok(())
        }
        Some("--version") if args.is_empty() => {
            println!("claude-notify {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("check-hooks") if args.is_empty() => paths::settings_path().and_then(|path| hooks::check(&path)),
        Some("install-hooks") if args.iter().all(|arg| arg == "--dry-run" || arg == "--wsl") => {
            install_hooks(dry_run, wsl)
        }
        Some("uninstall-hooks") if args.iter().all(|arg| arg == "--dry-run") => {
            paths::settings_path()
                .and_then(|path| hooks::uninstall(&path, dry_run))
                .map(|report| print_report(report, dry_run))
        }
        _ => {
            eprintln!("{HELP}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("claude-notify: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run_hook(command: &str, now_ms: u64) -> io::Result<()> {
    let stdin = io::stdin();
    let mut bytes = Vec::new();
    let input = if stdin.is_terminal() {
        None
    } else {
        stdin.lock().read_to_end(&mut bytes)?;
        Some(bytes.as_slice())
    };
    match protocol::classify(command, input, now_ms) {
        Action::Write(file) => protocol::write_atomic(&paths::sessions_dir()?, &file),
        Action::Delete(id) => protocol::delete(&paths::sessions_dir()?, &id),
        Action::Nothing => Ok(()),
    }
}

fn install_hooks(dry_run: bool, wsl: bool) -> io::Result<()> {
    let helper = hooks::quote_helper(&env::current_exe()?)?;
    let prefix = if wsl {
        let dir = wsl_sessions_dir()?;
        let dir = dir.to_str().ok_or_else(|| invalid("WSL sessions path is not UTF-8"))?;
        format!("CLAUDE_MENUBAR_DIR={} {helper}", hooks::quote_posix(dir))
    } else {
        helper
    };
    let report = hooks::install(&paths::settings_path()?, &prefix, dry_run)?;
    print_report(report, dry_run);
    Ok(())
}

fn print_report(report: hooks::Report, dry_run: bool) {
    if report.changes.is_empty() {
        println!("  hooks: already up to date");
        return;
    }
    for change in report.changes {
        println!("  {change}");
    }
    if dry_run {
        println!("  (dry run: nothing written)");
    }
    if let Some(backup) = report.backup {
        println!("  backup: {}", backup.display());
    }
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn command_output(program: &str, args: &[&str]) -> io::Result<String> {
    let output = Command::new(program).args(args).output()?;
    if !output.status.success() {
        return Err(invalid(format!("{program} failed: {}", String::from_utf8_lossy(&output.stderr).trim())));
    }
    String::from_utf8(output.stdout).map_err(|error| invalid(format!("{program} returned invalid UTF-8: {error}")))
}

fn wsl_sessions_dir() -> io::Result<PathBuf> {
    let local = command_output("cmd.exe", &["/c", "echo", "%LOCALAPPDATA%"])?;
    let local = local.trim();
    if local.is_empty() || local == "%LOCALAPPDATA%" || local.lines().count() != 1 {
        return Err(invalid("cmd.exe did not return a Windows LOCALAPPDATA path"));
    }
    let mounted = command_output("wslpath", &["-u", local])?;
    let mounted = PathBuf::from(mounted.trim());
    if !mounted.is_absolute() {
        return Err(invalid("wslpath did not return an absolute path"));
    }
    Ok(mounted.join("ClaudeMenuBar").join("sessions"))
}
