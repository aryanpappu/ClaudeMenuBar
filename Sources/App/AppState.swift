import Foundation
import AppKit
import SwiftUI
import ServiceManagement
import CoreGraphics

enum ClaudeState: String, Equatable, CaseIterable {
    case idle
    case running
    case waiting
    case done
}

struct ModelOption: Identifiable {
    let id: String
    let label: String
}

// One live Claude Code session (keyed by its session_id).
struct Session: Identifiable {
    let id: String
    var cwd: String
    var state: ClaudeState
    var lastActivity: Date
    var transcriptPath: String?
    var branch: String?      // git branch, read from the transcript
    var activity: String?    // short "what it's doing" label (aiTitle / last prompt)

    // Folder name of the working directory, e.g. "dynamic-multi-channel".
    var displayName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Sessions
    // Source of truth for the multi-session view. `state` below is a derived
    // aggregate kept for the menu-bar icon and the existing single-state views.
    @Published var sessions: [String: Session] = [:]

    // Which panel sections are expanded. These live here (not view-local) so
    // the panel can resize itself when any of them toggles.
    @Published var sessionsExpanded: Bool = true
    @Published var modelExpanded: Bool = true
    @Published var statsExpanded: Bool = true

    // Natural content height reported by the SwiftUI view; the floating panel
    // resizes itself to match. Seeded with a sensible first-render estimate.
    @Published var panelContentHeight: CGFloat = 480

    private static let globalSessionID = "__global__"   // used when a signal carries no session_id

    // Sessions shown in the panel: only the *active* ones (waiting or working),
    // waiting first, then most-recently-active. Finished (done) and idle (ready)
    // sessions are hidden — they still live in `sessions` until swept.
    var activeSessions: [Session] {
        sessions.values
            .filter { $0.id != Self.globalSessionID && ($0.state == .waiting || $0.state == .running) }
            .sorted { lhs, rhs in
                let l = Self.rank(lhs.state), r = Self.rank(rhs.state)
                if l != r { return l < r }
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id   // stable tiebreak so rows don't reshuffle
            }
    }

    private static func rank(_ s: ClaudeState) -> Int {
        switch s {
        case .waiting: 0
        case .running: 1
        case .done:    2
        case .idle:    3
        }
    }

    // MARK: Aggregate Claude state (derived from `sessions`)
    @Published var state: ClaudeState = .idle
    @Published var lastActivity: Date?

    // MARK: Model
    let modelOptions: [ModelOption] = [
        ModelOption(id: "haiku",  label: "Haiku"),
        ModelOption(id: "sonnet", label: "Sonnet"),
        ModelOption(id: "opus",   label: "Opus"),
    ]
    @Published var currentModel: String = "sonnet"

    // MARK: Sound
    @Published var isMuted: Bool = false {
        didSet { SoundManager.shared.isMuted = isMuted }
    }
    @Published var isRainMuted: Bool = false {
        didSet {
            SoundManager.shared.isRainMuted = isRainMuted
            if state == .running {
                if isRainMuted { SoundManager.shared.stopAll() }
                else           { SoundManager.shared.play(for: .running) }
            }
        }
    }

    // MARK: Usage
    @Published var weeklyMessages: Int = 0
    @Published var sessionMessages: Int = 0   // today's messages from history.jsonl

    // MARK: Misc
    @Published var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    @Published var showFloatingIcon: Bool = true {
        didSet {
            if showFloatingIcon { floatingPanel?.orderFrontRegardless() }
            else                { floatingPanel?.orderOut(nil) }
        }
    }

    private var ipcListener: IPCListener?
    private var sweepTimer: Timer?
    private var historyWatcher: DispatchSourceFileSystemObject?
    private var historyFD: Int32 = -1
    var floatingPanel: NSPanel?

    // How long a session lingers after finishing / going quiet.
    private let doneLingerSeconds: TimeInterval = 30
    private let staleSeconds: TimeInterval = 600           // idle → drop (10 min)
    private let runningStaleSeconds: TimeInterval = 1800   // running with no hooks → drop (30 min, crash cleanup)

    private init() {
        ipcListener = IPCListener { [weak self] newState, info in
            Task { @MainActor [weak self] in self?.apply(newState, info: info) }
        }
        loadModel()
        loadUsageStats()
        startHistoryWatcher()   // refreshes usage counts as messages are sent
        startSweepTimer()       // ages out finished / stale sessions
    }

    // MARK: State transitions

    // Upserts a single session, then re-derives the aggregate state.
    // `sessionID`/`cwd` default to empty so the debug "Force" buttons and any
    // signal without session info still work via a shared global session.
    func apply(_ newState: ClaudeState, sessionID: String = "", cwd: String = "") {
        apply(newState, info: sessionID.isEmpty ? [:] : ["session_id": sessionID, "cwd": cwd])
    }

    func apply(_ newState: ClaudeState, info: [String: String]) {
        let id = info["session_id"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.globalSessionID
        let cwd = info["cwd"] ?? ""
        let transcriptPath = info["transcript_path"].flatMap { $0.isEmpty ? nil : $0 }
        let remove = info["remove"] == "1"
        let now = Date()

        if remove {
            sessions[id] = nil
        } else if var existing = sessions[id] {
            existing.state = newState
            existing.lastActivity = now
            if !cwd.isEmpty { existing.cwd = cwd }
            if let transcriptPath { existing.transcriptPath = transcriptPath }
            sessions[id] = existing
        } else {
            sessions[id] = Session(id: id, cwd: cwd, state: newState, lastActivity: now,
                                   transcriptPath: transcriptPath)
        }

        lastActivity = now
        refreshAggregate()
        if newState == .done { loadUsageStats() }
        if let path = transcriptPath ?? sessions[id]?.transcriptPath, !remove {
            enrich(sessionID: id, transcriptPath: path)
        }
    }

    private var enrichingSessions: Set<String> = []

    // Reads git branch + a short activity label from a session's transcript
    // (~/.claude/projects/<cwd>/<session-id>.jsonl) off the main thread. Only
    // the tail of the (append-only, ever-growing) file is read, and overlapping
    // reads for the same session are skipped, so this stays cheap even though
    // it's triggered on every hook.
    private func enrich(sessionID: String, transcriptPath: String) {
        guard !enrichingSessions.contains(sessionID) else { return }
        enrichingSessions.insert(sessionID)
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.parseTranscriptTail(path: transcriptPath)
            await self?.applyEnrichment(sessionID: sessionID, branch: result.branch, activity: result.activity)
        }
    }

    private func applyEnrichment(sessionID: String, branch: String?, activity: String?) {
        enrichingSessions.remove(sessionID)
        guard var s = sessions[sessionID] else { return }
        if let branch { s.branch = branch }
        if let activity { s.activity = activity }
        sessions[sessionID] = s
    }

    // Parses the last ~64KB of the transcript for the most recent gitBranch and
    // activity label (aiTitle, falling back to the last prompt). A leading
    // partial line simply fails to parse and is skipped.
    nonisolated private static func parseTranscriptTail(path: String) -> (branch: String?, activity: String?) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return (nil, nil) }
        defer { try? handle.close() }
        let maxBytes: UInt64 = 64_000
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var branch: String?
        var activity: String?
        for line in text.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if branch == nil, let b = j["gitBranch"] as? String, !b.isEmpty { branch = b }
            if activity == nil {
                if let t = j["aiTitle"] as? String, !t.isEmpty { activity = t }
                else if let p = j["lastPrompt"] as? String, !p.isEmpty { activity = p }
            }
            if branch != nil && activity != nil { break }
        }
        return (branch, activity.map { String($0.prefix(60)) })
    }

    // Derives the menu-bar/aggregate state from all sessions and drives sound
    // on transitions. Priority: waiting > running > done > idle.
    private func refreshAggregate() {
        let states = sessions.values.map(\.state)
        let newAggregate: ClaudeState
        if states.contains(.waiting)      { newAggregate = .waiting }
        else if states.contains(.running) { newAggregate = .running }
        else if states.contains(.done)    { newAggregate = .done }
        else                              { newAggregate = .idle }

        guard newAggregate != state else { return }
        withAnimation(.easeInOut(duration: 0.35)) { state = newAggregate }
        SoundManager.shared.play(for: newAggregate)
    }

    // MARK: Session ageing
    // Replaces the old done-reset + pgrep watchers: finished sessions linger
    // briefly then go idle; long-quiet sessions are dropped from the list.

    private func startSweepTimer() {
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweep() }
        }
    }

    // Ages sessions out by state, never touching a live waiting/working row
    // prematurely:
    //   done    → idle after a short linger
    //   idle    → dropped after it's been quiet a while
    //   running → dropped only after a very long silence (crash cleanup; a
    //             live run keeps refreshing lastActivity via PreToolUse hooks)
    //   waiting → kept until a real signal clears it (never hide an Approve)
    private func sweep() {
        let now = Date()
        var changed = false
        for (id, s) in sessions {
            let age = now.timeIntervalSince(s.lastActivity)
            switch s.state {
            case .done where age > doneLingerSeconds:
                sessions[id]?.state = .idle
                changed = true
            case .idle where age > staleSeconds:
                sessions[id] = nil
                changed = true
            case .running where age > runningStaleSeconds:
                sessions[id] = nil
                changed = true
            default:
                break
            }
        }
        if changed { refreshAggregate() }
    }

    // MARK: history.jsonl watcher — keeps usage counts fresh

    private func startHistoryWatcher() {
        let path = NSHomeDirectory() + "/.claude/history.jsonl"
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        historyFD = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .background)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.loadUsageStats() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        historyWatcher = src
    }

    // MARK: Model

    func setModel(_ model: String) {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["model"] = model
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: URL(fileURLWithPath: path))
        }
        currentModel = model
    }

    private func loadModel() {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String else { return }
        currentModel = model
    }

    // MARK: Usage stats

    func loadUsageStats() {
        Task.detached(priority: .background) {
            let home = NSHomeDirectory()
            let histPath = home + "/.claude/history.jsonl"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: histPath)),
                  let text = String(data: data, encoding: .utf8) else { return }

            let now = Date()
            let calendar = Calendar.current
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            ) ?? now.addingTimeInterval(-7 * 86400)
            let dayStart = calendar.startOfDay(for: now)  // today's messages = "session"

            var weekly = 0
            var today  = 0
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let ts = json["timestamp"] as? Double else { continue }
                let date = Date(timeIntervalSince1970: ts / 1000.0)
                if date >= weekStart { weekly += 1 }
                if date >= dayStart  { today  += 1 }
            }

            let wc = weekly
            let tc = today
            await MainActor.run {
                self.weeklyMessages  = wc
                self.sessionMessages = tc
            }
        }
    }

    // MARK: Approval

    func sendApproval(for sessionID: String? = nil) {
        guard AXIsProcessTrusted() else {
            promptAccessibility()
            return   // don't clear the button — nothing was actually approved
        }
        // We must positively identify and raise the session's own terminal
        // before injecting keystrokes — a stray y+Return in the wrong window
        // could confirm a destructive prompt. No session context → do nothing.
        guard let id = sessionID, let session = sessions[id] else { return }

        WindowFocuser.focus(projectName: session.displayName) { [weak self] focused in
            guard let self else { return }
            // If we couldn't find the session's window, do NOT type into
            // whatever is frontmost. Leave the Approve button so the user
            // knows it didn't go through, and can approve manually.
            guard focused else { return }

            // Optimistically flip back to `running` so Approve disappears now;
            // the next PreToolUse hook confirms it anyway.
            if var s = self.sessions[id] {
                s.state = .running
                s.lastActivity = Date()
                self.sessions[id] = s
                self.refreshAggregate()
            }

            // Send the keystrokes once the activated window has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let src = CGEventSource(stateID: .hidSystemState)
                let yDown   = CGEvent(keyboardEventSource: src, virtualKey: 0x10, keyDown: true)
                let yUp     = CGEvent(keyboardEventSource: src, virtualKey: 0x10, keyDown: false)
                let retDown = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)
                let retUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
                [yDown, yUp, retDown, retUp].forEach { $0?.post(tap: .cghidEventTap) }
            }
        }
    }

    // Raises the terminal/editor window for a session (used when a row is tapped).
    func focusTerminal(for session: Session) {
        guard AXIsProcessTrusted() else { promptAccessibility(); return }
        WindowFocuser.focus(projectName: session.displayName) { _ in }
    }

    private func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: Launch at login

    func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled { try SMAppService.mainApp.unregister() }
            else                    { try SMAppService.mainApp.register() }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch { print("LaunchAtLogin toggle failed: \(error)") }
    }

    deinit {
        sweepTimer?.invalidate()
        historyWatcher?.cancel()
    }
}
