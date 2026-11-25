# Claude Menu Bar for Windows and Linux

Build the hook helper with Rust 1.77 or later. From the repository root:

```sh
cd crossplatform
cargo build --release -p claude-notify
cargo test --workspace
```

From the repository root, run the shared protocol vectors against the built binary. The workspace's `target` directory is under `crossplatform` by default.

```sh
python3 protocol/run_vectors.py crossplatform/target/release/claude-notify
```

On Windows, use `claude-notify.exe` in the binary path. To use the shorter `target/release/claude-notify` path, run this from the workspace:

```sh
python3 ../protocol/run_vectors.py target/release/claude-notify
```

Run the helper from its permanent location when installing hooks. Use `install-hooks --dry-run` to preview changes, `install-hooks --wsl` inside WSL to share the Windows sessions directory, and `uninstall-hooks` to remove the managed entries. The `check-hooks` command validates the settings file.

## Workspace layout

- `core/` contains session-file I/O, the session reducer, settings and hook management, model selection, and history counting.
- `notify/` builds `claude-notify`, the hook helper and installer.

## Desktop app

`crossplatform/app` is reserved for a future Tauri v2 desktop app.
