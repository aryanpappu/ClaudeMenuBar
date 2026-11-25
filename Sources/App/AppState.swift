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
    var pendingRequest: String?   // when waiting: the tool being requested, e.g. "Bash"
    var needsAnswer = false       // waiting for a typed answer (a question), not a yes/no approval

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
    @Published var sessionsExpanded: Bool = Prefs.bool("sessionsExpanded", default: true) {
        didSet { Prefs.set(sessionsExpanded, "sessionsExpanded") }
    }
    @Published var modelExpanded: Bool = Prefs.bool("modelExpanded", default: true) {
        didSet { Prefs.set(modelExpanded, "modelExpanded") }
    }
    @Published var statsExpanded: Bool = Prefs.bool("statsExpanded", default: true) {
        didSet { Prefs.set(statsExpanded, "statsExpanded") }
    }

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
    // "default" removes the "model" key so Claude Code uses its own default.
    static let defaultModelID = "default"
    let modelOptions: [ModelOption] = [
        ModelOption(id: AppState.defaultModelID, label: "Auto"),
        ModelOption(id: "haiku",  label: "Haiku"),
        ModelOption(id: "sonnet", label: "Sonnet"),
        ModelOption(id: "opus",   label: "Opus"),
    ]
    @Published var currentModel: String = AppState.defaultModelID

    // MARK: Sound
    @Published var isMuted: Bool = Prefs.bool("isMuted", default: false) {
        didSet {
            Prefs.set(isMuted, "isMuted")
            SoundManager.shared.isMuted = isMuted
        }
    }
    @Published var isRainMuted: Bool = Prefs.bool("isRainMuted", default: false) {
        didSet {
            Prefs.set(isRainMuted, "isRainMuted")
            SoundManager.shared.isRainMuted = isRainMuted
            if state == .running {
                if isRainMuted { SoundManager.shared.stopAll() }
                else           { SoundManager.shared.play(for: .running) }
            }
        }
    }

    // MARK: Usage
    @Published var weeklyMessages: Int = 0
    @Published var todayMessages: Int = 0     // today's prompts from history.jsonl

    // MARK: Misc
    @Published var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    // Typing "y + Return" into a terminal is powerful and can hit the wrong
    // prompt, so one-click Approve is opt-in. When off, the row button just
    // opens the session's terminal.
    @Published var oneClickApprove: Bool = Prefs.bool("oneClickApprove", default: false) {
        didSet { Prefs.set(oneClickApprove, "oneClickApprove") }
    }
    // Show the session's title / last prompt in notification banners. Off by
    // default: banners can appear in screen shares and on the lock screen.
    @Published var notificationPreviews: Bool = Prefs.bool("notificationPreviews", default: false) {
        didSet { Prefs.set(notificationPreviews, "notificationPreviews") }
    }
    @Published var notificationsEnabled: Bool = Prefs.bool("notificationsEnabled", default: true) {
        didSet { Prefs.set(notificationsEnabled, "notificationsEnabled") }
    }
    @Published var showFloatingIcon: Bool = Prefs.bool("showFloatingIcon", default: true) {
        didSet {
            Prefs.set(showFloatingIcon, "showFloatingIcon")
            if showFloatingIcon { floatingPanel?.orderFrontRegardless() }
            else                { floatingPanel?.orderOut(nil) }
        }
    }

    private var sessionFiles: SessionFiles?
    private var lastFileTs: [String: Int64] = [:]   // newest applied ts per session file
    private var fileSessionIDs: Set<String> = []    // sessions currently backed by a file
    private var initialLoadDone = false
    private var sweepCount = 0
    private var sweepTimer: Timer?
    private var usageTracker: UsageTracker?
    var floatingPanel: NSPanel?

    // How long a session lingers after finishing / going quiet.
    private let doneLingerSeconds: TimeInterval = 30
    private let staleSeconds: TimeInterval = 600           // idle → drop (10 min)
    private let runningStaleSeconds: TimeInterval = 1800   // running with no hooks → drop (30 min, crash cleanup)

    private init() {
        sessionFiles = SessionFiles { [weak self] files in
            Task { @MainActor [weak self] in self?.sync(files) }
        }
        SoundManager.shared.isMuted = isMuted
        SoundManager.shared.isRainMuted = isRainMuted
        loadModel()
        usageTracker = UsageTracker { [weak self] today, week in
            Task { @MainActor [weak self] in
                self?.todayMessages = today
                self?.weeklyMessages = week
            }
        }
        usageTracker?.poll()    // first full read + arms the file watcher
        sessionFiles?.rescan()  // loads sessions that were running before launch
        sessionFiles?.cleanupOldFiles()
        startSweepTimer()       // ages out finished / stale sessions
    }

    // Applies the current set of session files (docs/PROTOCOL.md). Only files
    // newer than what was already applied count, so a session the sweep has
    // dropped isn't brought back by its old file. The first load (app start)
    // is silent: no banners, no sounds.
    private func sync(_ files: [SessionFile]) {
        let silent = !initialLoadDone
        initialLoadDone = true
        let present = Set(files.map(\.sessionID))

        // A file that disappeared means `end` (SessionEnd).
        for id in fileSessionIDs.subtracting(present) where sessions[id] != nil {
            apply(.idle, info: ["session_id": id, "remove": "1"], silent: silent)
        }
        fileSessionIDs = present
        lastFileTs = lastFileTs.filter { present.contains($0.key) }

        for file in files.sorted(by: { $0.ts < $1.ts }) {
            guard file.ts > (lastFileTs[file.sessionID] ?? .min) else { continue }
            lastFileTs[file.sessionID] = file.ts
            var info = ["session_id": file.sessionID]
            info["cwd"] = file.cwd
            info["transcript_path"] = file.transcriptPath
            info["request"] = file.request
            info["kind"] = file.kind
            apply(file.state, info: info, at: file.date, silent: silent)
        }
        if silent { sweep() }   // age out what went stale while the app was closed
    }

    // MARK: State transitions

    // Upserts a single session, then re-derives the aggregate state.
    // `sessionID`/`cwd` default to empty so the debug "Force" buttons and any
    // signal without session info still work via a shared global session.
    func apply(_ newState: ClaudeState, sessionID: String = "", cwd: String = "") {
        apply(newState, info: sessionID.isEmpty ? [:] : ["session_id": sessionID, "cwd": cwd])
    }

    func apply(_ newState: ClaudeState, info: [String: String], at now: Date = Date(), silent: Bool = false) {
        // Any local process can post these distributed notifications, so treat
        // every field as untrusted input: bound sizes, validate ids and only
        // accept transcript paths inside ~/.claude/projects.
        let id = info["session_id"].flatMap { Self.isSafeID($0) ? $0 : nil } ?? Self.globalSessionID
        let cwd = String((info["cwd"] ?? "").prefix(1024))
        let transcriptPath = info["transcript_path"].flatMap(Self.validatedTranscriptPath)
        let request = info["request"].map { String($0.prefix(40)) }
        let remove = info["remove"] == "1"
        let needsAnswer = newState == .waiting && info["kind"] == "question"
        let oldState = sessions[id]?.state

        if remove {
            sessions[id] = nil
        } else if var existing = sessions[id] {
            existing.state = newState
            existing.lastActivity = now
            if !cwd.isEmpty { existing.cwd = cwd }
            if let transcriptPath { existing.transcriptPath = transcriptPath }
            existing.pendingRequest = (newState == .waiting) ? request : nil
            existing.needsAnswer = needsAnswer
            sessions[id] = existing
        } else {
            sessions[id] = Session(id: id, cwd: cwd, state: newState, lastActivity: now,
                                   transcriptPath: transcriptPath,
                                   pendingRequest: (newState == .waiting) ? request : nil,
                                   needsAnswer: needsAnswer)
        }

        lastActivity = max(lastActivity ?? now, now)
        refreshAggregate(playSound: !silent)
        if oldState == nil { loadModel() }   // pick up model changes made elsewhere
        if let path = transcriptPath ?? sessions[id]?.transcriptPath, !remove {
            enrich(sessionID: id, transcriptPath: path)
        }

        // Notify on entering a new attention state (not on every repeat hook).
        // A request that was answered must not leave a stale "Approve" banner.
        if oldState == .waiting && newState != .waiting {
            NotificationManager.shared.clearWaiting(sessionID: id)
        }
        if !remove, !silent, notificationsEnabled, let session = sessions[id], newState != oldState {
            if newState == .waiting {
                NotificationManager.shared.notifyWaiting(session: session)
            } else if newState == .done {
                NotificationManager.shared.notifyDone(session: session)
            }
        }
    }

    nonisolated static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    private static let transcriptRoot = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        .resolvingSymlinksInPath().path + "/"

    private static func validatedTranscriptPath(_ path: String) -> String? {
        guard !path.isEmpty, path.count < 1024, path.hasSuffix(".jsonl") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(transcriptRoot) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return resolved
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
        guard let data = try? handle.read(upToCount: Int(maxBytes)) else { return (nil, nil) }
        // Lossy decode: the tail can start in the middle of a multi-byte
        // character; that only damages the first (partial) line we skip anyway.
        let text = String(decoding: data, as: UTF8.self)

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
    private func refreshAggregate(playSound: Bool = true) {
        let states = sessions.values.map(\.state)
        let newAggregate: ClaudeState
        if states.contains(.waiting)      { newAggregate = .waiting }
        else if states.contains(.running) { newAggregate = .running }
        else if states.contains(.done)    { newAggregate = .done }
        else                              { newAggregate = .idle }

        guard newAggregate != state else { return }
        withAnimation(.easeInOut(duration: 0.35)) { state = newAggregate }
        if playSound { SoundManager.shared.play(for: newAggregate) }
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
        // Fallback for missed folder events; hourly clean-up of dead files.
        sessionFiles?.rescan()
        sweepCount += 1
        if sweepCount % 720 == 0 { sessionFiles?.cleanupOldFiles() }
        // Re-arms the history watcher if the file appeared/was replaced, and
        // rolls the counts over at midnight / week start.
        usageTracker?.poll()
    }

    // MARK: Model
    // Reads/writes the "model" key of ~/.claude/settings.json. The file is the
    // user's real Claude Code config, so: re-read right before writing, keep
    // every other key, write atomically, and never write if it can't be parsed.

    private static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
    }

    func setModel(_ model: String) {
        let url = Self.settingsURL
        // Only a missing file may be created from scratch. Any other read
        // problem, an empty file or invalid JSON: leave the file alone.
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("ClaudeMenuBar: can't read settings.json as a JSON object; not touching it")
                return
            }
            json = parsed
        }
        if model == Self.defaultModelID { json.removeValue(forKey: "model") }
        else { json["model"] = model }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: json,
                                                 options: [.prettyPrinted, .withoutEscapingSlashes])
            try out.write(to: url, options: .atomic)
            currentModel = model
        } catch {
            NSLog("ClaudeMenuBar: could not write settings.json: \(error)")
        }
    }

    private func loadModel() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        currentModel = (json["model"] as? String) ?? Self.defaultModelID
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

        // requireUnique: if two terminal windows match this project name we
        // can't tell which one is waiting, so refuse rather than guess.
        // Questions need a typed answer, and Approve may be switched off: in
        // both cases just bring the terminal forward.
        guard oneClickApprove, !session.needsAnswer else { focusTerminal(for: session); return }

        let request = session.pendingRequest
        WindowFocuser.focus(projectName: session.displayName, requireUnique: true) { [weak self] target in
            // If we couldn't single out the session's window, do NOT type into
            // whatever is frontmost. The Approve button stays so the user can
            // approve by hand.
            guard let target else { return }

            // Type once the raised window has settled, re-checking everything
            // at that moment: still opted in, the same request still waiting,
            // and exactly that window focused. The state itself is left to
            // the next hook (PreToolUse), which also clears the banner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.oneClickApprove,
                      let current = self.sessions[id], current.state == .waiting,
                      current.pendingRequest == request, !current.needsAnswer,
                      WindowFocuser.isFocused(target) else { return }
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
    }
}
