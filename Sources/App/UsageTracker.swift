import Foundation

/// Counts the user's Claude Code prompts for today and this week from
/// `~/.claude/history.jsonl`.
///
/// The history file is append-only and grows forever, so after one full read
/// at start-up only the newly appended bytes are parsed. Only timestamps from
/// the current week are kept in memory; nothing else from the file (including
/// the prompt text) is stored.
///
/// The file watcher survives the file being deleted, replaced or not existing
/// yet: it re-arms itself on the next `poll()`.
final class UsageTracker: @unchecked Sendable {
    typealias Handler = @Sendable (_ today: Int, _ week: Int) -> Void

    private let path: String
    private let queue = DispatchQueue(label: "ClaudeMenuBar.UsageTracker", qos: .utility)
    private let onChange: Handler

    // Everything below is only touched on `queue`.
    private var offset: UInt64 = 0
    private var fileID: UInt64 = 0        // inode of the file the offset belongs to
    private var partialLine = Data()
    private var timestamps: [Date] = []
    private var source: DispatchSourceFileSystemObject?

    init(path: String = NSHomeDirectory() + "/.claude/history.jsonl", onChange: @escaping Handler) {
        self.path = path
        self.onChange = onChange
    }

    /// Reads new data and makes sure the watcher is armed. Cheap; safe to call
    /// from a periodic timer.
    func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.armWatcherIfNeeded()
            self.readNewData()
        }
    }

    /// Recomputes the counts without reading the file (e.g. after midnight).
    func recount() {
        queue.async { [weak self] in self?.publish() }
    }

    // MARK: Private (queue only)

    private func armWatcherIfNeeded() {
        guard source == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }   // file not created yet; try again on next poll
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.delete) || event.contains(.rename) {
                // The file was replaced: drop the watcher and start over.
                self.source?.cancel()
                self.source = nil
                self.reset()
                self.fileID = 0
                self.armWatcherIfNeeded()
            }
            self.readNewData()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func reset() {
        offset = 0
        partialLine.removeAll()
        timestamps.removeAll()
    }

    private func readNewData() {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            // File gone: show zero instead of stale numbers.
            if offset > 0 || !timestamps.isEmpty { reset(); fileID = 0 }
            publish()
            return
        }
        defer { try? handle.close() }
        // A different inode means the file was replaced: start over, even if
        // the new file happens to be larger than the old offset.
        var st = stat()
        if fstat(handle.fileDescriptor, &st) == 0 {
            let id = UInt64(st.st_ino)
            if id != fileID { reset(); fileID = id }
        }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { reset() }   // truncated in place
        guard size > offset else { publish(); return }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd() else { return }
        offset += UInt64(chunk.count)

        var data = partialLine
        data.append(chunk)
        let weekStart = Self.weekStart(for: Date())
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            parse(line: data[lineStart..<newline], weekStart: weekStart)
            lineStart = data.index(after: newline)
        }
        partialLine = Data(data[lineStart...])
        publish()
    }

    private func parse(line: Data, weekStart: Date) {
        guard !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = json["timestamp"] as? Double else { return }
        let date = Date(timeIntervalSince1970: ms / 1000)
        if date >= weekStart { timestamps.append(date) }
    }

    private func publish() {
        let now = Date()
        let weekStart = Self.weekStart(for: now)
        let dayStart = Calendar.current.startOfDay(for: now)
        timestamps.removeAll { $0 < weekStart }
        let week = timestamps.count
        let today = timestamps.filter { $0 >= dayStart }.count
        onChange(today, week)
    }

    private static func weekStart(for date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))
            ?? date.addingTimeInterval(-7 * 86_400)
    }

    deinit { source?.cancel() }
}
