import Foundation
import os

let defaultLogPath = "/Library/Logs/mac-display/mac-display.log"
let logSubsystem = "local.mac-display"

enum Log {
    /// Emit debug lines (CLI --verbose, or "logLevel": "debug" in the config).
    static var verbose = false
    /// Prefix lines with a timestamp (daemon mode).
    static var timestamps = false
    /// Mirror every line into the macOS unified log (daemon mode).
    static var unifiedLogging = false

    private static var file: RotatingLogFile?
    private static let osLog = Logger(subsystem: logSubsystem, category: "daemon")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Send all output (including stdout/stderr, so runtime crash messages too) to a
    /// size-capped log file that rotates itself: path, path.1 … path.<keep>.
    static func useFile(path: String, maxBytes: Int, keep: Int) throws {
        file = try RotatingLogFile(path: path, maxBytes: maxBytes, keep: keep)
    }

    /// Change the rotation limits of the active log file (from the config).
    static func setRotation(maxBytes: Int, keep: Int) {
        file?.setLimits(maxBytes: maxBytes, keep: keep)
    }

    /// Always reaches the unified log, even before/without a log file (startup failures).
    static func fault(_ message: String) {
        osLog.fault("\(message, privacy: .public)")
    }

    static func info(_ message: String) { emit(message, .default) }

    static func debug(_ message: String) {
        if verbose { emit(message, .debug) }
    }

    static func warn(_ message: String) { emit("warning: " + message, .error) }

    static func error(_ message: String) { emit("error: " + message, .error) }

    private static func emit(_ message: String, _ level: OSLogType) {
        if unifiedLogging {
            osLog.log(level: level, "\(message, privacy: .public)")
        }
        let line = timestamps ? "\(formatter.string(from: Date())) \(message)\n" : "\(message)\n"
        if let file {
            file.write(Data(line.utf8))
        } else {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}

/// Append-only log file capped at `maxBytes`; when full it is renamed to `.1`
/// (`.1` -> `.2` …, the oldest beyond `keep` is deleted) and a fresh file is started.
/// Total disk use is bounded by roughly maxBytes * (keep + 1).
final class RotatingLogFile {
    static let maxKeep = 20

    let path: String
    private(set) var maxBytes: Int
    private(set) var keep: Int
    private var size = 0

    init(path: String, maxBytes: Int, keep: Int) throws {
        self.path = path
        self.maxBytes = max(maxBytes, 4096)
        self.keep = min(max(keep, 0), Self.maxKeep)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try reopen()
    }

    /// Open `path` and make it the process's stdout and stderr.
    private func reopen() throws {
        // O_NOFOLLOW: never append through a planted symlink (we may be running as root).
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw MacDisplayError.failed("cannot open log file \(path): \(String(cString: strerror(errno)))")
        }
        var st = stat()
        size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

    func setLimits(maxBytes: Int, keep: Int) {
        let newKeep = min(max(keep, 0), Self.maxKeep)
        // Drop copies beyond the new limit.
        if newKeep < self.keep {
            for i in (newKeep + 1)...self.keep { unlink("\(path).\(i)") }
        }
        self.maxBytes = max(maxBytes, 4096)
        self.keep = newKeep
    }

    func write(_ data: Data) {
        if size > 0 && size + data.count > maxBytes { rotate() }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(STDOUT_FILENO, base + offset, buf.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        size += data.count
    }

    private func rotate() {
        if keep == 0 {
            unlink(path)
        } else {
            unlink("\(path).\(keep)")
            for i in stride(from: keep - 1, through: 1, by: -1) {
                Darwin.rename("\(path).\(i)", "\(path).\(i + 1)")
            }
            Darwin.rename(path, "\(path).1")
        }
        // If reopening fails we keep writing to the renamed file, which is still open.
        try? reopen()
    }

    /// Existing log files, oldest first.
    static func files(path: String, keep: Int = RotatingLogFile.maxKeep) -> [String] {
        let candidates = (stride(from: keep, through: 1, by: -1).map { "\(path).\($0)" }) + [path]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

enum MacDisplayError: Error, CustomStringConvertible {
    case privateAPI(String)
    case ioKit(String, kern_return_t)
    case config(String)
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .privateAPI(let m): return m
        case .ioKit(let call, let kr): return "\(call) failed: \(describe(kr))"
        case .config(let m): return "config: \(m)"
        case .usage(let m): return m
        case .failed(let m): return m
        }
    }
}

func describe(_ kr: kern_return_t) -> String {
    let hex = "0x" + String(UInt32(bitPattern: kr), radix: 16)
    guard let cstr = mach_error_string(kr) else { return hex }
    return "\(String(cString: cstr)) (\(hex))"
}
