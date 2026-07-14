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

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Claude state
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
    private var processTimer: Timer?
    private var doneResetTimer: Timer?
    private var historyWatcher: DispatchSourceFileSystemObject?
    private var historyFD: Int32 = -1
    var floatingPanel: NSPanel?

    private init() {
        ipcListener = IPCListener { [weak self] newState in
            Task { @MainActor [weak self] in self?.apply(newState) }
        }
        loadModel()
        loadUsageStats()
        startHistoryWatcher()   // detects message submission before first PreToolUse hook
        startProcessWatcher()   // safety net for crashes
    }

    // MARK: State transitions

    func apply(_ newState: ClaudeState) {
        doneResetTimer?.invalidate()
        withAnimation(.easeInOut(duration: 0.35)) {
            state = newState
            lastActivity = Date()
        }
        SoundManager.shared.play(for: newState)
        if newState == .done {
            loadUsageStats()
            // 30s keeps the Done ✓ icon visible while the user types the next message,
            // so there's no flash through "Ready" before the next PreToolUse fires.
            doneResetTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.state = .idle }
            }
        }
    }

    // MARK: history.jsonl watcher
    // Detects the moment the user submits a message (history.jsonl is appended to).
    // This fires BEFORE the first PreToolUse hook, so extended-thinking phases
    // correctly show "Thinking..." from the very start.

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                // history.jsonl was written → user just sent a message
                if self.state == .idle || self.state == .done {
                    self.apply(.running)
                }
                self.loadUsageStats()
            }
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

    func sendApproval() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            return
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let yDown   = CGEvent(keyboardEventSource: src, virtualKey: 0x10, keyDown: true)
        let yUp     = CGEvent(keyboardEventSource: src, virtualKey: 0x10, keyDown: false)
        let retDown = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)
        let retUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
        [yDown, yUp, retDown, retUp].forEach { $0?.post(tap: .cghidEventTap) }
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

    // MARK: Process watcher — safety net only

    private func startProcessWatcher() {
        processTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            let running = Self.isClaudeRunning()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .running && !running { self.apply(.done) }
            }
        }
    }

    nonisolated private static func isClaudeRunning() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "claude"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    deinit {
        processTimer?.invalidate()
        doneResetTimer?.invalidate()
        historyWatcher?.cancel()
    }
}
