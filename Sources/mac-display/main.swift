import Foundation

let toolVersion = "1.0.0"
let defaultConfigPath = "/usr/local/etc/mac-display/config.json"

let usage = """
mac-display \(toolVersion) - pin external display connection modes (bit depth, YCbCr/RGB,
range, SDR/HDR, timing) on Apple silicon, including at the login window.

Usage: mac-display <command> [options]

Commands:
  list [--timings] [--all] [--json]
        Show attached displays, their current connection mode and the modes they offer.
  status [--config PATH]
        Show whether the daemon is running (and its last error/log line), and what the
        config does to each display (changes nothing).
  apply [--config PATH] [--dry-run]
        Apply the config once.
  set [--display SEL] [colour options] [timing options] [--dry-run]
        Switch one display right now (the daemon will re-apply your config afterwards
        if this conflicts with it).
          colour: --depth N  --encoding rgb|ycbcr444|ycbcr422|ycbcr420  --range full|limited
                  --sdr | --hdr  --eotf sdr|pq|hlg  --colorimetry NAME  --color-id N
          timing: --resolution WxH  --refresh HZ  --timing-id N
          SEL:    name (substring), serial, port (e.g. dispext0) or index from `list`
  daemon [--config PATH] [--log-file PATH]
        Keep the configured modes applied (what the LaunchDaemon runs). With --log-file,
        output goes to a self-rotating file (size limits: logMaxKB / logKeep in the config).
  logs [-f] [-n N] [--log-file PATH]
        Show the daemon log (last N lines, default 100, across rotated files; -n all for
        everything); -f keeps following it.
  setup [--config PATH]
        Interactive: pick a display, try its modes live (each reverts after 15 s unless you
        confirm), and save the one you want to the config. Uses sudo.
  check-config [--config PATH]
        Validate a config file.
  default-config
        Print a starter config with no rules.
  version

Options:
  --config PATH   Config file (default: $MAC_DISPLAY_CONFIG or \(defaultConfigPath))
  --verbose, -v   More logging (debug level)

"""

// MARK: - Argument parsing

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags = Set<String>()
    /// Unrecognised options (an error for every command except `daemon`, which only warns,
    /// so a stale plist can't stop the display from being managed).
    var unknown: [String] = []

    static let valueOptions: Set<String> = [
        "config", "display", "depth", "bit-depth", "encoding", "range", "eotf", "colorimetry",
        "color-id", "colour-id", "id", "timing-id", "resolution", "refresh",
        "log-file", "lines",
    ]
    static let flagOptions: Set<String> = ["timings", "all", "json", "dry-run", "sdr", "hdr", "verbose", "help", "version", "follow"]
    static let shortOptions: [String: String] = ["-h": "help", "-f": "follow", "-n": "lines", "-v": "verbose"]

    init(_ argv: ArraySlice<String>) throws {
        var it = argv.makeIterator()
        while let arg = it.next() {
            if let long = Self.shortOptions[arg] {
                if Self.valueOptions.contains(long) {
                    guard let v = it.next() else { throw MacDisplayError.usage("\(arg) needs a value") }
                    options[long] = v
                } else {
                    flags.insert(long)
                }
                continue
            }
            guard arg.hasPrefix("--") else {
                if arg.hasPrefix("-") && arg.count > 1 { unknown.append(arg); continue }
                positional.append(arg)
                continue
            }
            var name = String(arg.dropFirst(2))
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if Self.valueOptions.contains(name) {
                guard let v = value ?? it.next(), value != nil || !v.hasPrefix("--") else {
                    throw MacDisplayError.usage("--\(name) needs a value")
                }
                options[name] = v
            } else if Self.flagOptions.contains(name) {
                guard value == nil else { throw MacDisplayError.usage("--\(name) does not take a value") }
                flags.insert(name)
            } else {
                unknown.append("--\(name)")
            }
        }
    }

    var configPath: String {
        options["config"] ?? ProcessInfo.processInfo.environment["MAC_DISPLAY_CONFIG"] ?? defaultConfigPath
    }

    func int(_ name: String) throws -> Int? {
        guard let s = options[name] else { return nil }
        guard let v = Int(s) else { throw MacDisplayError.usage("--\(name) expects an integer, got \"\(s)\"") }
        return v
    }
}

// MARK: - Helpers

func loadAPI() throws -> IOMFB { try IOMFB.shared.get() }

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

func encodingOrder(_ e: PixelEncoding) -> Int {
    switch e {
    case .rgb: return 0
    case .ycbcr444: return 1
    case .ycbcr422: return 2
    case .ycbcr420: return 3
    case .other(let n): return 10 + n
    }
}

/// Wait for a requested switch to show up in GetDigitalOutMode.
func waitFor(_ target: ModeIDs, on fb: Framebuffer, timeout: TimeInterval = 8) -> ModeIDs? {
    let deadline = Date().addingTimeInterval(timeout)
    var last: ModeIDs?
    while Date() < deadline {
        usleep(250_000)
        last = try? fb.currentMode()
        if last == target { return last }
    }
    return last
}

func switchMode(_ d: AttachedDisplay, to target: ModeIDs, dryRun: Bool) throws {
    print("  -> \(d.info.describe(target))")
    if dryRun {
        print("  (dry run, not switching)")
        return
    }
    try d.framebuffer.setMode(target)
    let now = waitFor(target, on: d.framebuffer)
    guard now == target else {
        throw MacDisplayError.failed("\(d.info.name): requested \(target) but the display reports \(now.map { "\($0)" } ?? "nothing")")
    }
    print("  done")
}

func selectDisplay(_ displays: [AttachedDisplay], _ selector: String?) throws -> AttachedDisplay {
    guard !displays.isEmpty else { throw MacDisplayError.failed("no external displays with switchable connection modes found") }
    guard let sel = selector else {
        if displays.count == 1 { return displays[0] }
        throw MacDisplayError.usage("several displays attached; pick one with --display (name, serial, port or index):\n"
            + displays.enumerated().map { "  \($0.offset + 1). \($0.element.info.name) (\($0.element.info.identity))" }.joined(separator: "\n"))
    }
    // Most specific first: index from `list`, then exact port/serial, exact name, name substring.
    if let i = Int(sel), (1...displays.count).contains(i) { return displays[i - 1] }
    let key = normalizeKey(sel)
    var tiers: [(AttachedDisplay) -> Bool] = [
        { d in
            d.info.port.caseInsensitiveCompare(sel) == .orderedSame
                || d.info.alphanumericSerial?.caseInsensitiveCompare(sel) == .orderedSame
                || d.info.serialNumber.map(String.init) == sel
        },
    ]
    // A bare number that isn't a valid index is only tried as a serial, never as part of a name.
    if Int(sel) == nil {
        tiers.append { d in !key.isEmpty && normalizeKey(d.info.name) == key }
        tiers.append { d in !key.isEmpty && normalizeKey(d.info.name).contains(key) }
    }
    for tier in tiers {
        let hits = displays.filter(tier)
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 { throw MacDisplayError.usage("\"\(sel)\" matches several displays; use the index, port or serial") }
    }
    throw MacDisplayError.usage("no display matches \"\(sel)\"")
}

// MARK: - Commands

func cmdList(_ a: Args) throws {
    let displays = attachedDisplays(api: try loadAPI())
    let showAll = a.flags.contains("all")

    if a.flags.contains("json") {
        let out: [[String: Any]] = displays.map { d in
            let t = d.info.timing(d.mode.timing)
            var o: [String: Any] = [
                "name": d.info.name, "vendor": d.info.vendor ?? NSNull(), "productID": d.info.productID ?? NSNull(),
                "serial": d.info.alphanumericSerial ?? d.info.serialNumber.map(String.init) ?? NSNull(),
                "port": d.info.port, "edidUUID": d.info.edidUUID,
                "current": [
                    "colorID": d.mode.color, "timingID": d.mode.timing,
                    "color": d.info.color(d.mode.color, timing: d.mode.timing)?.json ?? NSNull(),
                    "timing": t?.json ?? NSNull(),
                ] as [String: Any],
                "colorModes": (t?.colorModes ?? []).filter { showAll || !$0.isVirtual }.map(\.json),
            ]
            if a.flags.contains("timings") {
                o["timings"] = d.info.timings.filter { showAll || !$0.isVirtual }.map(\.json)
            }
            return o
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        return
    }

    if displays.isEmpty {
        print("No external displays with switchable connection modes found.")
        return
    }
    for (i, d) in displays.enumerated() {
        if i > 0 { print() }
        print("\(i + 1). \(d.info.name)  (\(d.info.identity))")
        print("   current: \(d.info.describe(d.mode))")
        guard let t = d.info.timing(d.mode.timing) else { continue }
        print("   colour modes at \(t.summary):")
        print("        " + pad("ID", 5) + pad("bits", 5) + pad("SDR/HDR", 11) + pad("encoding", 13) + pad("range", 9) + pad("colorimetry", 14) + "score")
        let modes = t.colorModes.filter { showAll || !$0.isVirtual }.sorted {
            ($0.depth, encodingOrder($0.encoding), $0.rangeRaw, $0.eotf.raw, $0.colorimetry)
                < ($1.depth, encodingOrder($1.encoding), $1.rangeRaw, $1.eotf.raw, $1.colorimetry)
        }
        for c in modes {
            var notes: [String] = []
            if c.isVirtual { notes.append("virtual") }
            if t.unsafeColorIDs.contains(c.id) { notes.append("unsafe") }
            let mark = c.id == d.mode.color ? "   *  " : "      "
            print(mark + "  " + pad("\(c.id)", 5) + pad("\(c.depth)", 5) + pad(c.eotf.label, 11) + pad(c.encoding.label, 13)
                + pad(c.rangeLabel, 9) + pad(Colorimetry.label(c.colorimetry), 14) + "\(c.score)"
                + (notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"))
        }
        if a.flags.contains("timings") {
            print("   timings:")
            let timings = d.info.timings.filter { showAll || !$0.isVirtual }.sorted {
                ($0.width * $0.height, $0.refreshHz, $0.id) > ($1.width * $1.height, $1.refreshHz, $1.id)
            }
            for tm in timings {
                let mark = tm.id == d.mode.timing ? "   *  " : "      "
                var notes: [String] = []
                if tm.isPreferred { notes.append("preferred") }
                if tm.isVirtual { notes.append("virtual") }
                print(mark + "  " + pad("\(tm.id)", 5) + pad(tm.summary, 26) + "score \(tm.score)"
                    + (notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"))
            }
        } else {
            print("   \(d.info.timings.filter { !$0.isVirtual }.count) timings available (add --timings to list them)")
        }
    }
}

func cmdStatus(_ a: Args) throws {
    let daemon = DaemonStatus.query(logPath: a.options["log-file"] ?? defaultLogPath)
    for line in daemon.render() { print(line) }
    let config: AppConfig
    do {
        config = try AppConfig.load(path: a.configPath)
    } catch {
        print("config:  \(error)")
        throw MacDisplayError.failed("fix the config, then run `mac-display status` again")
    }
    let displays = attachedDisplays(api: try loadAPI())
    print("config:  \(a.configPath) (\(config.displays.count) rule(s))")
    printDisplayPlans(config: config, displays: displays)
}

/// Each display, its current mode, the rule that applies, and what the daemon does about it.
func printDisplayPlans(config: AppConfig, displays: [AttachedDisplay]) {
    if displays.isEmpty { print("No external displays with switchable connection modes found.") }
    for d in displays {
        print()
        print("\(d.info.name)  (\(d.info.identity))")
        print("  current: \(d.info.describe(d.mode))")
        guard let (i, rule) = config.rule(for: d.info) else {
            print("  no matching rule: left alone")
            continue
        }
        print("  rule #\(i + 1) \"\(rule.title)\" wants: \(rule.wants)")
        switch Planner.plan(d.info, current: d.mode, rule: rule) {
        case .compliant: print("  OK: already in the desired mode")
        case .change(let m): print("  would switch to: \(d.info.describe(m))")
        case .impossible(let why): print("  cannot satisfy rule: \(why)")
        }
    }
}

func cmdApply(_ a: Args) throws {
    let config = try AppConfig.load(path: a.configPath)
    let displays = attachedDisplays(api: try loadAPI())
    var failures: [String] = []
    for d in displays {
        guard let (i, rule) = config.rule(for: d.info) else { continue }
        print("\(d.info.name): rule #\(i + 1) \"\(rule.title)\"")
        print("  current: \(d.info.describe(d.mode))")
        switch Planner.plan(d.info, current: d.mode, rule: rule) {
        case .compliant:
            print("  already in the desired mode")
        case .impossible(let why):
            print("  cannot satisfy rule: \(why)")
            failures.append(d.info.name)
        case .change(let target):
            do { try switchMode(d, to: target, dryRun: a.flags.contains("dry-run")) } catch {
                print("  error: \(error)")
                failures.append(d.info.name)
            }
        }
    }
    if !failures.isEmpty { throw MacDisplayError.failed("could not apply the config to: \(failures.joined(separator: ", "))") }
}

func cmdSet(_ a: Args) throws {
    var color = ColorCriteria()
    color.id = try a.int("color-id") ?? a.int("colour-id") ?? a.int("id")
    color.bitDepth = try a.int("depth") ?? a.int("bit-depth")
    if let e = a.options["encoding"] {
        guard let v = PixelEncoding(name: e) else { throw MacDisplayError.usage("--encoding: use \(PixelEncoding.names.joined(separator: ", "))") }
        color.encoding = v
    }
    if let r = a.options["range"] {
        guard let v = QuantRange(name: r) else { throw MacDisplayError.usage("--range: use full or limited") }
        color.range = v
    }
    if a.flags.contains("sdr") && a.flags.contains("hdr") { throw MacDisplayError.usage("--sdr and --hdr are mutually exclusive") }
    if a.flags.contains("sdr") { color.hdr = false }
    if a.flags.contains("hdr") { color.hdr = true }
    if let e = a.options["eotf"] {
        guard let v = Eotf(name: e) else { throw MacDisplayError.usage("--eotf: use \(Eotf.names.joined(separator: ", "))") }
        color.eotf = v
    }
    if let s = a.options["colorimetry"] {
        guard let v = Colorimetry.code(named: s) else {
            throw MacDisplayError.usage("--colorimetry: use one of \(Colorimetry.table.map(\.key).joined(separator: ", "))")
        }
        color.colorimetry = v
    }

    var timing = TimingCriteria()
    timing.id = try a.int("timing-id")
    if let r = a.options["resolution"] {
        guard let (w, h) = parseResolution(r) else { throw MacDisplayError.usage("--resolution expects WIDTHxHEIGHT") }
        timing.width = w
        timing.height = h
    }
    if let r = a.options["refresh"] {
        guard let hz = Double(r), hz > 0 else { throw MacDisplayError.usage("--refresh expects a number in Hz") }
        timing.refreshHz = hz
    }
    let hasTiming = timing.id != nil || timing.width != nil || timing.refreshHz != nil
    guard !color.isEmpty || hasTiming else {
        throw MacDisplayError.usage("nothing to set; give colour options (e.g. --depth 8 --encoding ycbcr444 --range limited --sdr) and/or timing options")
    }

    let displays = attachedDisplays(api: try loadAPI())
    let d = try selectDisplay(displays, a.options["display"])
    let rule = DisplayRule(label: "command line", colorMode: color.isEmpty ? nil : color, timing: hasTiming ? timing : nil)
    print("\(d.info.name)  (\(d.info.identity))")
    print("  current: \(d.info.describe(d.mode))")
    switch Planner.plan(d.info, current: d.mode, rule: rule) {
    case .compliant: print("  already in the requested mode")
    case .impossible(let why): throw MacDisplayError.failed(why)
    case .change(let target): try switchMode(d, to: target, dryRun: a.flags.contains("dry-run"))
    }
}

func cmdCheckConfig(_ a: Args) throws {
    let config = try AppConfig.load(path: a.configPath)
    print("OK: \(a.configPath)")
    print("  pollIntervalSeconds \(config.pollIntervalSeconds), settleDelaySeconds \(config.settleDelaySeconds), "
        + "verifyDelaySeconds \(config.verifyDelaySeconds), maxAttempts \(config.maxAttempts)")
    for (i, r) in config.displays.enumerated() {
        print("  rule #\(i + 1) \"\(r.title)\"\(r.enabled ? "" : " (disabled)"): match \(r.match.summary) -> \(r.wants)")
    }
}

func cmdDaemon(_ a: Args) throws -> Never {
    Log.timestamps = true
    Log.unifiedLogging = true
    var logFileError: Error?
    if let path = a.options["log-file"] {
        // Defaults until the config is loaded (logMaxKB / logKeep).
        let defaults = AppConfig()
        do { try Log.useFile(path: path, maxBytes: defaults.logMaxKB * 1024, keep: defaults.logKeep) } catch { logFileError = error }
    }
    Log.info("mac-display \(toolVersion) daemon starting (pid \(getpid()), uid \(getuid()), config \(a.configPath))")
    if let logFileError { Log.error("\(logFileError); logging to stdout and the unified log only") }
    for w in daemonArgWarnings { Log.warn("ignoring command-line problem: \(w) (check \(daemonPlistPath))") }
    if case .failure(let e) = IOMFB.shared { Log.error("\(e)") }
    let engine = Engine(configPath: a.configPath)
    engine.forceVerbose = a.flags.contains("verbose")
    Daemon(engine: engine).run()
}

func cmdLogs(_ a: Args) throws {
    let path = a.options["log-file"] ?? defaultLogPath
    let follow = a.flags.contains("follow")
    let limit: Int?
    switch a.options["lines"] {
    case nil: limit = 100
    case "all": limit = nil
    case let s?:
        guard let n = Int(s), n >= 0 else { throw MacDisplayError.usage("-n expects a number or \"all\"") }
        limit = n
    }
    let files = RotatingLogFile.files(path: path)
    if files.isEmpty && !follow {
        throw MacDisplayError.failed("no log at \(path) yet (is the daemon installed? try: sudo launchctl print system/local.mac-display)")
    }
    // Last `limit` lines across the rotated files, oldest first.
    var lines: [Substring] = []
    for f in files.reversed() {
        guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
        var chunk = text.split(separator: "\n", omittingEmptySubsequences: false)
        if chunk.last == "" { chunk.removeLast() }
        lines.insert(contentsOf: chunk, at: 0)
        if let limit, lines.count >= limit { break }
    }
    if let limit, lines.count > limit { lines.removeFirst(lines.count - limit) }
    for l in lines { print(l) }
    guard follow else { return }
    fflush(stdout)
    // tail -F follows the file across rotations.
    let argv = ["/usr/bin/tail", "-n", "0", "-F", path]
    var cargs = argv.map { strdup($0) }
    cargs.append(nil)
    execv("/usr/bin/tail", &cargs)
    throw MacDisplayError.failed("cannot run /usr/bin/tail: \(String(cString: strerror(errno)))")
}

// MARK: - Main

/// Command-line problems the daemon reports (in its log) instead of refusing to start.
var daemonArgWarnings: [String] = []

setvbuf(stdout, nil, _IOLBF, 0)

do {
    let args = try Args(CommandLine.arguments.dropFirst())
    Log.verbose = args.flags.contains("verbose")
    let aliases = ["ls": "list", "check": "check-config", "log": "logs"]
    var command = args.flags.contains("help") ? "help" : args.flags.contains("version") ? "version" : (args.positional.first ?? "help")
    command = aliases[command] ?? command
    // Problems with the command line. Fatal, except for `daemon`, which logs them and runs
    // anyway: a typo in the LaunchDaemon plist must not stop the display being managed.
    var problems: [String] = args.unknown.map { "unknown option \($0)" }
    problems += args.positional.dropFirst().map { "unexpected argument \"\($0)\"" }

    // Reject options a command would silently ignore (e.g. `daemon --dry-run` would really switch).
    let allowed: [String: Set<String>] = [
        "list": ["timings", "all", "json"],
        "status": ["config", "log-file"],
        "apply": ["config", "dry-run"],
        "set": ["display", "depth", "bit-depth", "encoding", "range", "eotf", "colorimetry", "color-id", "colour-id",
                "id", "timing-id", "resolution", "refresh", "sdr", "hdr", "dry-run"],
        "daemon": ["config", "log-file"],
        "check-config": ["config"],
        "setup": ["config"],
        "default-config": [],
        "logs": ["follow", "lines", "log-file"],
    ]
    if let ok = allowed[command] {
        let unsupported = Set(args.options.keys).union(args.flags).subtracting(ok).subtracting(["verbose"])
        if !unsupported.isEmpty {
            problems.append("`\(command)` does not take " + unsupported.sorted().map { "--\($0)" }.joined(separator: ", "))
        }
    }
    if command == "daemon" {
        daemonArgWarnings = problems
    } else if let first = problems.first {
        throw MacDisplayError.usage("\(first) (see `mac-display help`)")
    }

    switch command {
    case "list": try cmdList(args)
    case "status": try cmdStatus(args)
    case "apply": try cmdApply(args)
    case "set": try cmdSet(args)
    case "daemon": try cmdDaemon(args)
    case "logs": try cmdLogs(args)
    case "check-config": try cmdCheckConfig(args)
    case "setup": try cmdSetup(args)
    case "default-config": print(AppConfig().rendered(), terminator: "")
    case "version": print(toolVersion)
    case "help": print(usage, terminator: "")
    default: throw MacDisplayError.usage("unknown command \"\(command)\"\n\n\(usage)")
    }
} catch {
    // The LaunchDaemon has no stderr; make startup failures visible in the unified log.
    if CommandLine.arguments.dropFirst().contains("daemon") { Log.fault("daemon failed to start: \(error)") }
    FileHandle.standardError.write("mac-display: \(error)\n".data(using: .utf8)!)
    exit(1)
}
