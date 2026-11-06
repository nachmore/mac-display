import Foundation

let daemonLabel = "local.mac-display"
let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"

/// What launchd (and the daemon's own logs) say about the LaunchDaemon. Everything here
/// is readable without sudo.
struct DaemonStatus {
    enum State {
        case notInstalled
        case notLoaded
        case disabled
        case running(pid: Int32)
        case notRunning(launchdState: String)
    }

    var state: State
    var runs: Int?
    var lastExitCode: String?
    var started: Date?
    var lastLogLine: String?
    /// Most recent startup failure / fault from the unified log (only looked up when unhealthy).
    var lastFault: String?

    var isHealthy: Bool {
        if case .running = state { return true }
        return false
    }

    static func query(logPath: String = defaultLogPath) -> DaemonStatus {
        var s = DaemonStatus(state: .notInstalled)
        s.lastLogLine = lastLine(of: logPath)
        let installed = FileManager.default.fileExists(atPath: daemonPlistPath)

        if let disabled = run("/bin/launchctl", ["print-disabled", "system"])?.out,
           disabled.contains("\"\(daemonLabel)\" => disabled") || disabled.contains("\"\(daemonLabel)\" => true") {
            s.state = .disabled
        }

        guard let printed = run("/bin/launchctl", ["print", "system/\(daemonLabel)"]), printed.status == 0 else {
            if case .disabled = s.state {} else { s.state = installed ? .notLoaded : .notInstalled }
            if installed { s.lastFault = recentFault() }
            return s
        }
        // Top-level "key = value" lines are indented by exactly one tab.
        var fields: [String: String] = [:]
        for line in printed.out.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: " = "), fields[String(t[..<r.lowerBound])] == nil {
                fields[String(t[..<r.lowerBound])] = String(t[r.upperBound...])
            }
        }
        s.runs = fields["runs"].flatMap { Int($0) }
        s.lastExitCode = fields["last exit code"]
        if fields["state"] == "running", let pid = fields["pid"].flatMap({ Int32($0) }) {
            s.state = .running(pid: pid)
            s.started = processStart(pid)
        } else if case .disabled = s.state {
            // keep
        } else {
            s.state = .notRunning(launchdState: fields["state"] ?? "unknown")
        }
        let exitedBadly = s.lastExitCode.map { $0 != "0" && $0 != "(never exited)" } ?? false
        if !s.isHealthy || exitedBadly { s.lastFault = recentFault() }
        return s
    }

    /// Lines for `mac-display status`.
    func render() -> [String] {
        var out: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let restarts = (runs ?? 0) > 1 ? ", started \(runs!) times, last exit code \(lastExitCode ?? "?")" : ""
        switch state {
        case .running(let pid):
            out.append("daemon:  running (pid \(pid)\(started.map { ", up since \(df.string(from: $0))" } ?? "")\(restarts))")
        case .notInstalled:
            out.append("daemon:  not installed (run ./install.sh)")
        case .notLoaded:
            out.append("daemon:  NOT RUNNING: installed but not loaded")
            out.append("         start it: sudo launchctl bootstrap system \(daemonPlistPath)")
        case .disabled:
            out.append("daemon:  DISABLED: switched off in System Settings > General > Login Items & Extensions")
            out.append("         (or via launchctl); switch it on, then re-run ./install.sh")
        case .notRunning(let launchdState):
            let why = launchdState == "spawn scheduled" ? "launchd keeps restarting it after failures" : "launchd state: \(launchdState)"
            out.append("daemon:  NOT RUNNING: \(why) (\(runs ?? 0) runs, last exit code \(lastExitCode ?? "?"))")
        }
        if let until = Pause.activeUntil() {
            out.append("         paused:     by `mac-display setup` until \(df.string(from: until))")
        }
        if let lastFault { out.append("         last error: \(lastFault)") }
        if let lastLogLine { out.append("         last log:   \(lastLogLine)") }
        if !isHealthy, case .notInstalled = state {} else if !isHealthy {
            out.append("         details:    sudo launchctl print system/\(daemonLabel)  ·  mac-display logs")
        }
        return out
    }
}

/// Run a command, returning its exit status and stdout (stderr discarded).
private func run(_ path: String, _ args: [String]) -> (status: Int32, out: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func processStart(_ pid: Int32) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
}

private func lastLine(of path: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let end = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: end > 8192 ? end - 8192 : 0)
    guard let data = try? h.readToEnd() else { return nil }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
}

/// Last fault-level message (startup failures) from the unified log in the past day.
private func recentFault() -> String? {
    let predicate = "subsystem == \"\(logSubsystem)\" AND messageType == fault"
    guard let r = run("/usr/bin/log", ["show", "--last", "1d", "--style", "compact", "--predicate", predicate]) else { return nil }
    guard let line = r.out.split(separator: "\n").last(where: { $0.contains("[\(logSubsystem):") }) else { return nil }
    // "2026-11-06 12:06:42.238 F  mac-display[48477:c1531] [local.mac-display:daemon] message"
    let stamp = line.prefix(19)
    if let r = line.range(of: "] ", range: (line.range(of: "[\(logSubsystem):")?.lowerBound ?? line.startIndex)..<line.endIndex) {
        return "\(stamp) \(line[r.upperBound...])"
    }
    return String(line)
}
