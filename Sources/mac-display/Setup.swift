import Foundation

// MARK: - Daemon pause (used while `setup` tries modes)

/// A short lease the daemon honours while `setup` runs: a root-owned file holding the
/// epoch time it ends. Setup renews it in the background, so if setup is killed or
/// suspended the daemon resumes within about a minute. /var/run is cleared at boot.
enum Pause {
    static let path = "/var/run/mac-display.pause"
    static let lease: TimeInterval = 60
    static let renewEvery: TimeInterval = 20

    static func activeUntil() -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_uid == 0, (st.st_mode & S_IFMT) == S_IFREG,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let until = Date(timeIntervalSince1970: epoch)
        // Ignore expired leases, and anything further out than a lease could be.
        guard until > Date(), until.timeIntervalSinceNow <= lease + 60 else { return nil }
        return until
    }

    /// Atomically (temp file + rename), so the daemon never sees a half-written file.
    static func set() throws {
        let tmp = "\(path).\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MacDisplayError.failed("\(path): \(String(cString: strerror(errno)))") }
        let text = "\(Int(Date().timeIntervalSince1970 + lease))\n"
        let ok = write(fd, text, text.utf8.count) == text.utf8.count
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            let e = String(cString: strerror(errno))
            unlink(tmp)
            throw MacDisplayError.failed("\(path): \(e)")
        }
    }

    static func clear() { unlink(path) }
}

// MARK: - Terminal helpers

private enum Term {
    /// nil on end of input.
    static func ask(_ prompt: String) -> String? {
        print(prompt, terminator: " ")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }

    static func yesNo(_ prompt: String, default def: Bool) -> Bool {
        while true {
            guard let a = ask("\(prompt) [\(def ? "Y/n" : "y/N")]")?.lowercased() else { return false }
            if a.isEmpty { return def }
            if ["y", "yes"].contains(a) { return true }
            if ["n", "no"].contains(a) { return false }
        }
    }

    /// 1-based choice; nil on end of input or "q".
    static func choose(_ prompt: String, count: Int, default def: Int) -> Int? {
        while true {
            guard let a = ask("\(prompt) [\(def)]") else { return nil }
            if a.isEmpty { return def }
            if a.lowercased() == "q" { return nil }
            if let n = Int(a), (1...count).contains(n) { return n }
            print("Enter a number from 1 to \(count).")
        }
    }

    /// After a switch: wait for the picture, then keep the mode only if the user types
    /// "y" in time. Keys pressed while the screen was dark (e.g. Enter to "wake" it) are
    /// discarded, and a bare Enter never keeps a mode.
    static func confirmKeep(seconds: Int = 15, settle: UInt32 = 3) -> Bool {
        print("  Waiting for the picture…")
        sleep(settle)
        tcflush(STDIN_FILENO, TCIFLUSH)
        var remaining = seconds
        while remaining > 0 {
            print("\r  Type y and press Enter to keep this mode (reverting in \(remaining) s) ", terminator: "")
            fflush(stdout)
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 1000) > 0 {
                guard let line = readLine() else { return false }
                switch line.trimmingCharacters(in: .whitespaces).lowercased() {
                case "y", "yes", "keep": return true
                case "n", "no", "r": return false
                default: continue // includes a bare Enter; keep counting down
                }
            }
            remaining -= 1
        }
        print()
        return false
    }
}

// MARK: - Session (pause lease + interruption safety)

private final class SetupSession {
    static let shared = SetupSession()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mac-display.setup")
    /// While a trial mode is unconfirmed: the mode to restore if setup is interrupted.
    private var pendingRevert: (Framebuffer, ModeIDs)?
    private var terminating = false
    private(set) var paused = false
    private var warned = false
    private var renewTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    /// The config is backed up once per session, before the first save.
    var backedUp = false

    func begin() {
        renewPause()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Pause.renewEvery, repeating: Pause.renewEvery)
        t.setEventHandler { [unowned self] in self.renewPause() }
        t.resume()
        renewTimer = t
        signal(SIGTSTP, SIG_IGN) // a suspended setup would leave a trial mode unconfirmed
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            s.setEventHandler { [unowned self] in self.interrupted(sig) }
            s.resume()
            signalSources.append(s)
        }
    }

    func renewPause() {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating else { return }
        do {
            try Pause.set()
            paused = true
        } catch {
            if !paused && !warned {
                warned = true
                print("warning: couldn't pause the daemon (\(error)); if it is running it may undo modes you try.")
            }
        }
    }

    /// Issue a switch atomically with recording how to undo it, so an interrupt can't
    /// slip in between.
    func switchMode(_ fb: Framebuffer, to target: ModeIDs, revertTo from: ModeIDs?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating else { throw MacDisplayError.failed("interrupted") }
        pendingRevert = from.map { (fb, $0) }
        try fb.setMode(target)
    }

    func clearPendingRevert() {
        lock.lock()
        pendingRevert = nil
        lock.unlock()
    }

    private func interrupted(_ sig: Int32) {
        lock.lock()
        terminating = true
        let revert = pendingRevert
        pendingRevert = nil
        lock.unlock()
        print("\nInterrupted.")
        if let (fb, mode) = revert {
            print("Reverting the mode you were trying…")
            var handle = fb
            if restoreMode(&handle, to: mode, reopen: nil) != mode {
                print("warning: couldn't confirm the revert. Run: mac-display set --color-id \(mode.color) --timing-id \(mode.timing)")
            }
        }
        end()
        exit(128 + sig)
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        renewTimer?.cancel()
        renewTimer = nil
        if paused {
            Pause.clear()
            paused = false
        }
    }
}

/// Switch to `mode` and confirm it took, retrying (and reopening the connection if a call
/// fails). Returns what the display reports at the end.
@discardableResult
private func restoreMode(_ fb: inout Framebuffer, to mode: ModeIDs, reopen: (() -> Framebuffer?)?) -> ModeIDs? {
    var last: ModeIDs?
    for _ in 1...4 {
        do {
            try fb.setMode(mode)
        } catch {
            if let fresh = reopen?() { fb = fresh }
            usleep(800_000)
            continue
        }
        last = waitFor(mode, on: fb, timeout: 6)
        if last == mode { return last }
    }
    return last ?? (try? fb.currentMode())
}

/// One display being set up: its connection, reopened if it goes stale.
private final class Target {
    let service: FramebufferService
    let api: IOMFB
    var fb: Framebuffer

    init(_ d: AttachedDisplay, api: IOMFB) {
        service = d.service
        self.api = api
        fb = d.framebuffer
    }

    func reopen() -> Framebuffer? {
        guard let fresh = try? Framebuffer(service: service.service, api: api) else { return nil }
        fb = fresh
        return fresh
    }

    /// Current mode, waiting out link training (0/0) and transient errors.
    func readMode(retryFor seconds: TimeInterval) -> ModeIDs? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let m = try? fb.currentMode() {
                if !(m.color == 0 && m.timing == 0) { return m }
            } else {
                _ = reopen()
            }
            usleep(500_000)
        } while Date() < deadline
        return nil
    }

    @discardableResult
    func restore(to mode: ModeIDs) -> ModeIDs? {
        var handle = fb
        let result = restoreMode(&handle, to: mode, reopen: { self.reopen() })
        fb = handle
        return result
    }
}

// MARK: - Setup command

private enum Outcome { case next, quit }

func cmdSetup(_ a: Args) throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        throw MacDisplayError.usage("setup is interactive; run it in a terminal")
    }
    let configPath = a.configPath
    // MAC_DISPLAY_SETUP_NO_SUDO=1 (testing only): run unprivileged, without pausing the daemon.
    if getuid() != 0 && ProcessInfo.processInfo.environment["MAC_DISPLAY_SETUP_NO_SUDO"] != "1" {
        print("Setup needs admin rights to pause the daemon while you try modes, and to save \(configPath).")
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let argv: [String] = ["sudo", exe, "setup", "--config", configPath]
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        execv("/usr/bin/sudo", &cargs)
        throw MacDisplayError.failed("cannot run sudo: \(String(cString: strerror(errno)))")
    }
    let api = try loadAPI()
    let usesDaemonConfig = (configPath as NSString).resolvingSymlinksInPath
        == (defaultConfigPath as NSString).resolvingSymlinksInPath

    var config = AppConfig()
    if FileManager.default.fileExists(atPath: configPath) {
        do {
            config = try AppConfig.load(path: configPath)
        } catch {
            print("The current config can't be read:\n  \(error)")
            guard Term.yesNo("Start a fresh config? (the old file is kept as .bak when you save)", default: false) else { return }
        }
    }

    let session = SetupSession.shared
    session.begin()
    defer { session.end() }

    print("""

    mac-display setup: pick a display, try its modes, and save the one you want.
    Each mode you try reverts by itself after 15 s unless you type y to keep it, so a
    mode that blanks the screen is harmless.\(session.paused ? " The daemon is paused until you finish." : "")
    """)
    if !usesDaemonConfig {
        print("Note: you're editing \(configPath), but the daemon uses \(defaultConfigPath).")
    }

    var savedAnything = false
    while true {
        let displays = attachedDisplays(api: api)
        guard !displays.isEmpty else {
            print("\nNo external displays with switchable connection modes are attached.")
            break
        }
        let d: AttachedDisplay
        if displays.count == 1 {
            d = displays[0]
        } else {
            print("\nDisplays:")
            for (i, x) in displays.enumerated() { print("  \(i + 1). \(x.info.name)  (\(x.info.identity))") }
            guard let n = Term.choose("Which display?", count: displays.count, default: 1) else { break }
            d = displays[n - 1]
        }
        let others = displays.filter { $0.info.registryID != d.info.registryID }.map(\.info)
        let target = Target(d, api: api)
        let (outcome, saved) = try setupDisplay(target, d.info, others: others, config: &config,
                                                configPath: configPath, session: session)
        savedAnything = savedAnything || saved
        if outcome == .quit || displays.count < 2 || !Term.yesNo("\nSet up another display?", default: false) { break }
    }

    session.end()
    print()
    if savedAnything {
        print(usesDaemonConfig ? "Saved \(configPath). The daemon applies it within a few seconds."
                               : "Saved \(configPath) (not the daemon's config).")
    } else {
        print("Nothing saved.")
    }
    if usesDaemonConfig {
        print("What the daemon will do now:")
        printDisplayPlans(config: config, displays: attachedDisplays(api: api))
    }
}

private func sortedModes(_ t: TimingElement) -> [ColorElement] {
    t.usableColorModes.sorted {
        ($0.depth, encodingOrder($0.encoding), $0.rangeRaw, $0.eotf.raw, $0.colorimetry)
            < ($1.depth, encodingOrder($1.encoding), $1.rangeRaw, $1.eotf.raw, $1.colorimetry)
    }
}

private func describeMode(_ mode: ModeIDs?, _ info: DisplayInfo) -> String {
    mode.map { info.describe($0) } ?? "no readable mode"
}

private func setupDisplay(_ t: Target, _ initialInfo: DisplayInfo, others: [DisplayInfo], config: inout AppConfig,
                          configPath: String, session: SetupSession) throws -> (Outcome, Bool) {
    var info = initialInfo
    var saved = false
    guard let original = t.readMode(retryFor: 10) else {
        print("\n\(info.name): can't read its current mode (it may be disconnected or still waking up).")
        return (.next, false)
    }

    while true {
        session.renewPause()
        guard let mode = t.readMode(retryFor: 10) else {
            print("\n  Can't read \(info.name)'s current mode (it may be disconnected or still waking up).")
            if Term.yesNo("  Try again?", default: true) { continue }
            return (.next, saved)
        }
        if let fresh = Registry.readDisplay(t.service) { info = fresh }
        print("\n\(info.name)  (\(info.identity))")
        print("  now:    \(info.describe(mode))")
        if let (i, rule) = config.rule(for: info) {
            print("  config: rule #\(i + 1) \"\(rule.title)\" wants \(rule.wants)")
        } else {
            print("  config: no rule for this display yet (it is left alone)")
        }

        let modes = info.timing(mode.timing).map(sortedModes) ?? []
        if let timing = info.timing(mode.timing) {
            print("\n  Colour modes at \(timing.summary):")
            print("        " + pad("#", 4) + pad("bits", 5) + pad("SDR/HDR", 11) + pad("encoding", 13) + pad("range", 9) + "colorimetry")
            for (i, c) in modes.enumerated() {
                let mark = c.id == mode.color ? "    *  " : "       "
                print(mark + " " + pad("\(i + 1)", 4) + pad("\(c.depth)", 5) + pad(c.eotf.label, 11) + pad(c.encoding.label, 13)
                    + pad(c.rangeLabel, 9) + Colorimetry.label(c.colorimetry))
            }
            print("\n  Number = try that mode · t = change resolution/refresh · s = save the current mode")
        } else {
            print("\n  The display reports a timing (\(mode.timing)) that isn't in its list; it may still be settling.")
            print("  Enter = look again")
        }
        print("  r = back to the mode you started with · q = done with this display")
        guard let input = Term.ask("  >")?.lowercased() else { return (.quit, saved) }

        switch input {
        case "":
            continue
        case "q", "quit", "done":
            explainAfterSetup(info, mode: mode, config: config)
            return (.next, saved)
        case "s", "save":
            if try saveRule(info, mode: mode, original: original, others: others, config: &config,
                            configPath: configPath, session: session) {
                saved = true
            }
        case "r":
            if mode == original { print("  Already in the starting mode.") }
            else { trySwitch(t, info, to: original, confirm: false, session: session) }
        case "t":
            if let target = chooseTiming(info, current: mode) {
                trySwitch(t, info, to: target, confirm: true, session: session)
            }
        default:
            if let n = Int(input), !modes.isEmpty, (1...modes.count).contains(n) {
                trySwitch(t, info, to: ModeIDs(color: modes[n - 1].id, timing: mode.timing), confirm: true, session: session)
            } else {
                print("  Enter a mode number, t, s, r or q.")
            }
        }
    }
}

/// On leaving a display: say what the daemon will do with it once setup ends.
private func explainAfterSetup(_ info: DisplayInfo, mode: ModeIDs, config: AppConfig) {
    guard let (_, rule) = config.rule(for: info) else {
        print("  No rule for this display, so the daemon leaves it as it is.")
        return
    }
    switch Planner.plan(info, current: mode, rule: rule) {
    case .compliant: print("  The daemon will keep this mode.")
    case .change(let m): print("  When setup ends, the daemon will switch this display to \(info.describe(m)) (press s first to save this mode instead).")
    case .impossible(let why): print("  warning: the saved rule can't be satisfied: \(why)")
    }
}

private func chooseTiming(_ info: DisplayInfo, current: ModeIDs) -> ModeIDs? {
    let timings = info.timings.filter { !$0.isVirtual && !$0.usableColorModes.isEmpty }.sorted {
        ($0.width * $0.height, $0.width, $0.refreshHz) > ($1.width * $1.height, $1.width, $1.refreshHz)
    }
    guard !timings.isEmpty else { return nil }
    print("\n  Resolutions / refresh rates:")
    for (i, t) in timings.enumerated() {
        let mark = t.id == current.timing ? "    *  " : "       "
        print(mark + " " + pad("\(i + 1)", 4) + t.summary + (t.isPreferred ? "  (preferred)" : ""))
    }
    let def = (timings.firstIndex { $0.id == current.timing } ?? 0) + 1
    guard let n = Term.choose("  Which one? (q = cancel)", count: timings.count, default: def) else { return nil }
    let t = timings[n - 1]
    if t.id == current.timing { return nil }
    // Keep the current colour mode if this timing offers it, else the closest one.
    if t.usableColorModes.contains(where: { $0.id == current.color }) {
        return ModeIDs(color: current.color, timing: t.id)
    }
    let closest = Planner.pick(t.usableColorModes, closestTo: info.color(current.color, timing: current.timing))
    return ModeIDs(color: closest.id, timing: t.id)
}

/// Switch, then (if `confirm`) keep it only on an explicit "y"; otherwise, or on any
/// failure, put the previous mode back and check that it took. Never throws: setup
/// must stay in control of the display.
private func trySwitch(_ t: Target, _ info: DisplayInfo, to target: ModeIDs, confirm: Bool, session: SetupSession) {
    session.renewPause()
    guard let from = t.readMode(retryFor: 5) else {
        print("  Can't read the current mode right now; try again.")
        return
    }
    guard target != from else {
        print("  That's the current mode.")
        return
    }
    print("  Switching to \(info.describe(target))")
    print("  (the screen may go dark for a few seconds)")
    defer { session.clearPendingRevert() }
    do {
        try session.switchMode(t.fb, to: target, revertTo: confirm ? from : nil)
    } catch {
        print("  The switch failed: \(error)")
        if let now = t.readMode(retryFor: 3), now != from { restoreAndReport(t, info, from) }
        return
    }
    var now = waitFor(target, on: t.fb)
    if now != target { now = t.readMode(retryFor: 4) } // slow links can take a while
    guard now == target else {
        print("  The display didn't switch (it reports \(describeMode(now, info))).")
        if now != from { restoreAndReport(t, info, from) }
        return
    }
    guard confirm else {
        print("  Done.")
        return
    }
    if Term.confirmKeep() {
        print("  Kept. Press s to save it as this display's default.")
    } else {
        restoreAndReport(t, info, from)
    }
}

private func restoreAndReport(_ t: Target, _ info: DisplayInfo, _ from: ModeIDs) {
    print("  Reverting…")
    let end = t.restore(to: from)
    if end == from {
        print("  Back to \(info.describe(from)).")
    } else {
        print("  warning: couldn't confirm the revert; the display reports \(describeMode(end, info)).")
        print("  Press r to try again, or run: mac-display set --color-id \(from.color) --timing-id \(from.timing)")
        print("  (unplugging and replugging the display also resets it)")
    }
}

/// Glob-escape a literal display name for DisplayMatch.name.
private func globEscaped(_ s: String) -> String {
    var out = ""
    for ch in s {
        if "*?[]\\".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

/// Whether a match pins specific hardware (rather than "any display" / a port).
private func isSpecific(_ m: DisplayMatch) -> Bool {
    m.name != nil || m.serial != nil || m.productID != nil
}

/// Ask how to save the current mode, show the rule, and write the config. Returns true if saved.
private func saveRule(_ info: DisplayInfo, mode: ModeIDs, original: ModeIDs, others: [DisplayInfo],
                      config: inout AppConfig, configPath: String, session: SetupSession) throws -> Bool {
    guard let color = info.color(mode.color, timing: mode.timing), let timing = info.timing(mode.timing) else {
        print("  Can't describe the current mode; not saving.")
        return false
    }
    // Every attribute that has a known value, so the rule picks exactly this mode.
    var criteria = ColorCriteria()
    if color.depth > 0 { criteria.bitDepth = color.depth }
    if color.encoding.raw >= 0 { criteria.encoding = color.encoding }
    criteria.range = color.range
    if color.eotf.raw >= 0 {
        if color.eotf.isHDR { criteria.eotf = color.eotf } else { criteria.hdr = false }
    }
    if color.colorimetry >= 0 { criteria.colorimetry = color.colorimetry }
    if criteria.isEmpty { criteria.id = color.id }

    // What the rule should cover.
    let winning = config.rule(for: info)
    let identity: DisplayMatch
    if let name = info.productName, !name.isEmpty {
        identity = DisplayMatch(name: [globEscaped(name)])
    } else {
        identity = DisplayMatch(vendor: info.vendor.map { [$0] }, productID: info.productID.map { [$0] })
    }
    typealias Choice = (text: String, match: DisplayMatch, label: String?, replaceIndex: Int?)
    var choices: [Choice] = []
    choices.append(("every \(info.name) (matched by model)", identity, info.name, nil))
    let serial = (info.alphanumericSerial?.isEmpty == false) ? info.alphanumericSerial : info.serialNumber.map(String.init)
    if let serial, serial != "0" {
        var unit = identity
        unit.serial = [serial]
        choices.append(("only this unit (serial \(serial))", unit, "\(info.name) \(serial)", nil))
    }
    choices.append(("whatever display is plugged into \(info.port)", DisplayMatch(port: [info.port]), "Display on \(info.port)", nil))
    if let (i, r) = winning, !(r.match == identity) {
        let update: Choice = ("update rule #\(i + 1) \"\(r.title)\" (matches \(r.match.summary))", r.match, r.label, i)
        // Offer updating first only when that rule is specific to this display.
        let sharedWithOthers = others.contains { r.match.matches($0) }
        if isSpecific(r.match) && !sharedWithOthers { choices.insert(update, at: 0) } else { choices.append(update) }
    }

    print("\n  Save \(color.summary) as the default for:")
    for (i, c) in choices.enumerated() { print("    \(i + 1). \(c.text)") }
    guard let n = Term.choose("  Choice (q = cancel)", count: choices.count, default: 1) else { return false }
    let choice = choices[n - 1]

    // Keep an existing timing pin unless asked otherwise.
    let replacedIndex = choice.replaceIndex ?? config.displays.firstIndex { $0.match == choice.match }
    let oldTiming = replacedIndex.flatMap { config.displays[$0].timing }
    let pinPrompt = oldTiming != nil
        ? "  Keep pinning the resolution/refresh rate (now \(timing.summary))?"
        : "  Also pin the resolution/refresh rate (\(timing.summary))?"
    session.renewPause()
    let pin = Term.yesNo(pinPrompt, default: mode.timing != original.timing || oldTiming != nil)
    var timingCriteria: TimingCriteria?
    if pin {
        if let oldTiming, oldTiming.matches(timing) {
            timingCriteria = oldTiming
        } else {
            timingCriteria = TimingCriteria(width: timing.width, height: timing.height,
                                            refreshHz: (timing.refreshHz * 100).rounded() / 100)
        }
    }
    let rule = DisplayRule(label: choice.label, enabled: true, match: choice.match, colorMode: criteria, timing: timingCriteria)

    // Place the rule where it wins for this display without shadowing earlier rules.
    var updated = config
    let w = winning?.index
    if let r = replacedIndex {
        if let w, r > w {
            updated.displays.remove(at: r)
            updated.displays.insert(rule, at: w)
        } else {
            updated.displays[r] = rule
        }
    } else {
        updated.displays.insert(rule, at: w ?? updated.displays.endIndex)
    }
    guard let now = updated.rule(for: info), now.rule.rendered() == rule.rendered() else {
        print("  internal error: the new rule wouldn't take effect for this display; not saving.")
        return false
    }

    print("\n  Rule #\(now.index + 1):\n" + rule.rendered(indent: "    "))
    for o in others {
        let before = config.rule(for: o).map { $0.rule.rendered() }
        let after = updated.rule(for: o).map { $0.rule.rendered() }
        if before != after {
            print("  Note: this also changes the rule for \(o.name) [\(o.port)] (now: \(updated.rule(for: o)?.rule.wants ?? "no rule")).")
        }
    }
    guard Term.yesNo("  Write it to \(configPath)?", default: true) else { return false }
    let backup = try writeConfig(updated, to: configPath, backup: !session.backedUp)
    session.backedUp = true
    config = updated
    print("  Saved." + (backup.map { " The config from before this session is in \($0)." } ?? ""))
    return true
}

// MARK: - Writing the config

/// Render, verify, and atomically replace the config. As root it refuses to write through
/// a symlink or into a directory that non-root users can modify. Returns the backup path
/// if one was made.
@discardableResult
func writeConfig(_ config: AppConfig, to path: String, backup: Bool) throws -> String? {
    let text = config.rendered()
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    do {
        let back = try decoder.decode(AppConfig.self, from: Data(text.utf8))
        guard back.rendered() == text else { throw MacDisplayError.failed("re-rendering differs") }
    } catch {
        throw MacDisplayError.failed("internal error: generated config doesn't round-trip (\(describeDecodingError(error))); nothing written")
    }

    let dir = (path as NSString).deletingLastPathComponent
    if getuid() == 0 { try checkRootSafe(dir) }
    var st = stat()
    if lstat(path, &st) == 0 && (st.st_mode & S_IFMT) != S_IFREG {
        throw MacDisplayError.failed("refusing to replace \(path): it is not a regular file (a symlink?)")
    }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])

    var backupPath: String?
    if backup, FileManager.default.fileExists(atPath: path) {
        let b = path + ".bak"
        unlink(b)
        try FileManager.default.copyItem(atPath: path, toPath: b)
        backupPath = b
    }

    let tmp = "\(path).tmp-\(getpid())"
    unlink(tmp)
    let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw MacDisplayError.failed("cannot write \(tmp): \(String(cString: strerror(errno)))") }
    let data = Data(text.utf8)
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    fchmod(fd, 0o644)
    fsync(fd)
    close(fd)
    guard written == data.count, rename(tmp, path) == 0 else {
        let e = String(cString: strerror(errno))
        unlink(tmp)
        throw MacDisplayError.failed("cannot write \(path): \(e)")
    }
    return backupPath
}

/// Every existing directory from `dir` up to / must be root-owned and not group/other-writable.
private func checkRootSafe(_ dir: String) throws {
    var d = dir
    while true {
        var st = stat()
        if lstat(d, &st) == 0 {
            if (st.st_mode & S_IFMT) != S_IFDIR || st.st_uid != 0 || (st.st_mode & 0o022) != 0 {
                throw MacDisplayError.failed("refusing to write the config as root: \(d) is not a root-owned directory "
                    + "that only root can modify (fix its ownership, or use a config under /usr/local/etc or /etc)")
            }
        }
        if d == "/" || d.isEmpty { break }
        d = (d as NSString).deletingLastPathComponent
    }
}
