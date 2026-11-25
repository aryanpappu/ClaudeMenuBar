import Foundation

/// One session file written by `claude-notify` (see docs/PROTOCOL.md).
struct SessionFile: Equatable, Sendable {
    let sessionID: String
    let state: ClaudeState
    let kind: String?
    let request: String?
    let cwd: String?
    let transcriptPath: String?
    let ts: Int64

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
}

/// Watches the sessions folder (`~/.claude-menubar/sessions`) and reports the
/// full, validated list of session files whenever it may have changed.
///
/// Triggers: the folder watcher (any file added, replaced or removed), the
/// `com.claudemenubar.changed` distributed notification posted by the macOS
/// helper (instant), and `rescan()` calls from the app's 5 s sweep timer
/// (fallback; also re-creates the watcher if the folder was deleted).
final class SessionFiles: @unchecked Sendable {
    typealias Handler = @Sendable ([SessionFile]) -> Void

    static let changedNotification = Notification.Name("com.claudemenubar.changed")
    static let maxAgeMs: Int64 = 24 * 60 * 60 * 1000

    let directory: URL
    private let queue = DispatchQueue(label: "ClaudeMenuBar.SessionFiles", qos: .userInitiated)
    private let onChange: Handler
    private var source: DispatchSourceFileSystemObject?   // only touched on `queue`

    init(onChange: @escaping Handler) {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_MENUBAR_DIR"], custom.hasPrefix("/") {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSHomeDirectory() + "/.claude-menubar/sessions", isDirectory: true)
        }
        self.onChange = onChange
        DistributedNotificationCenter.default().addObserver(
            forName: Self.changedNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.rescan() }
    }

    func rescan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.armWatcherIfNeeded()
            self.onChange(self.readAll())
        }
    }

    /// Deletes files whose last event is older than 24 h (crashed sessions).
    func cleanupOldFiles() {
        queue.async { [weak self] in
            guard let self else { return }
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Self.maxAgeMs
            for file in self.readAll() where file.ts < cutoff {
                let url = self.url(for: file.sessionID)
                // Re-read right before deleting: the session may have just woken up.
                if let fresh = Self.parse(url: url), fresh.ts < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: Private (queue only)

    private func url(for id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    private func armWatcherIfNeeded() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                // The folder itself went away: re-create the watcher later.
                self.source?.cancel()
                self.source = nil
            }
            self.onChange(self.readAll())
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func readAll() -> [SessionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix("."), name.count <= 105 else { return nil }
            guard let file = Self.parse(url: directory.appendingPathComponent(name)),
                  name == file.sessionID + ".json" else { return nil }
            return file
        }
    }

    /// Validates one file against the protocol; nil if anything is off.
    static func parse(url: URL) -> SessionFile? {
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["v"] as? NSNumber)?.intValue == 1,
              let id = json["session_id"] as? String, AppState.isSafeID(id),
              let stateRaw = json["state"] as? String, let state = ClaudeState(rawValue: stateRaw),
              let ts = (json["ts"] as? NSNumber)?.int64Value
        else { return nil }
        func text(_ key: String, max: Int) -> String? {
            guard let s = json[key] as? String, !s.isEmpty, s.count <= max else { return nil }
            return s
        }
        return SessionFile(sessionID: id, state: state, kind: text("kind", max: 20),
                           request: text("request", max: 40), cwd: text("cwd", max: 1024),
                           transcriptPath: text("transcript_path", max: 1024), ts: ts)
    }

    deinit {
        source?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
