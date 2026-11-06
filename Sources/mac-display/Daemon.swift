import Foundation
import IOKit
import IOKit.pwr_mgt

// iokit_common_msg() values; the C macros are function-like so Swift can't import them.
private let msgCanSystemSleep: UInt32 = 0xE000_0270
private let msgSystemWillSleep: UInt32 = 0xE000_0280
private let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

/// Monotonic seconds (unaffected by clock changes; pauses during sleep, which is fine
/// because retry budgets reset on wake anyway).
private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// Keeps every matching display in its configured mode. All methods run on the main queue.
final class Engine {
    let configPath: String
    private(set) var config: AppConfig?
    private var configStamp: ConfigStamp?
    private var configLoadedOnce = false
    private var generation = 0
    private var handles: [UInt64: Framebuffer] = [:]
    private var states: [UInt64: DisplayState] = [:]
    /// Recent switch times per pipe. Unlike DisplayState this survives disconnects, so a
    /// display that re-connects after every switch (some docks/TVs do) can't loop forever.
    private var switchHistory: [UInt64: [TimeInterval]] = [:]
    private var lastLogged: [String: String] = [:]

    /// Ask the run loop for another check after a delay (set by Daemon).
    var scheduleCheck: ((TimeInterval, String) -> Void)?
    var onConfigChange: (() -> Void)?
    /// --verbose on the command line: debug logging regardless of the config.
    var forceVerbose = false

    private var wasPaused = false

    static let loopWindow: TimeInterval = 600
    private var loopLimit: Int { max(2 * (config?.maxAttempts ?? 5), 10) }

    private struct ConfigStamp: Equatable {
        let seconds: Int
        let nanoseconds: Int
        let size: Int64
        let inode: UInt64
        let device: Int32
    }

    private struct DisplayState {
        let edid: String
        var label: String?
        /// Generation + mode last evaluated as needing no action (fast path for polls).
        var settledGeneration: Int?
        var settledMode: ModeIDs?
        var attempts = 0
        var lastAttempt: TimeInterval?
        var compliantSince: TimeInterval?
        var gaveUp = false
        /// Follow-up checks scheduled while the link wasn't readable yet.
        var linkWaits = 0

        init(edid: String) { self.edid = edid }

        mutating func resetEpisode() {
            attempts = 0
            lastAttempt = nil
            compliantSince = nil
            gaveUp = false
            settledGeneration = nil
            settledMode = nil
            linkWaits = 0
        }
    }

    init(configPath: String) {
        self.configPath = configPath
    }

    /// Fresh retry budget for every display (wake, config change).
    func resetEpisodes() {
        for id in states.keys { states[id]?.resetEpisode() }
    }

    /// A display was plugged in or removed somewhere. Give a fresh retry budget to
    /// displays we haven't just switched ourselves (a switch can make some displays
    /// re-connect; those are handled by the loop guard instead).
    func noteTopologyChange() {
        let now = uptime()
        for id in states.keys {
            if let last = states[id]?.lastAttempt, now - last < 30 { continue }
            states[id]?.resetEpisode()
        }
    }

    // MARK: Config

    private static func stamp(_ path: String) -> ConfigStamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil } // follows symlinks
        return ConfigStamp(
            seconds: Int(st.st_mtimespec.tv_sec), nanoseconds: Int(st.st_mtimespec.tv_nsec),
            size: Int64(st.st_size), inode: UInt64(st.st_ino), device: st.st_dev)
    }

    /// Re-read the config if the file changed. Returns true if the active config changed.
    @discardableResult
    func reloadConfigIfNeeded(force: Bool = false) -> Bool {
        let stamp = Self.stamp(configPath)
        if !force && configLoadedOnce && stamp == configStamp { return false }
        configLoadedOnce = true
        configStamp = stamp
        guard stamp != nil else {
            if config != nil {
                Log.warn("config \(configPath) was removed; no longer managing displays")
            } else {
                logOnce("config", "error: config \(configPath) not found; waiting for it to appear")
            }
            let changed = config != nil
            config = nil
            generation += 1
            return changed
        }
        do {
            let c = try AppConfig.load(path: configPath)
            config = c
            generation += 1
            lastLogged = [:]
            switchHistory = [:]
            resetEpisodes()
            Log.verbose = forceVerbose || c.debugLogging
            Log.setRotation(maxBytes: c.logMaxKB * 1024, keep: c.logKeep)
            Log.info("loaded \(configPath): \(c.displays.count) rule(s), poll every \(c.pollIntervalSeconds)s"
                + (Log.verbose ? ", debug logging on" : ""))
            onConfigChange?()
            return true
        } catch {
            Log.error("\(error)" + (config != nil ? " (keeping the previous config)" : ""))
            return false
        }
    }

    // MARK: Check

    /// Bring every attached display in line with the config. `full` skips the poll fast
    /// path (used for display events, where the registry may have changed).
    func check(reason: String, full: Bool = false) {
        reloadConfigIfNeeded()
        guard let config else { return }
        let api: IOMFB
        switch IOMFB.shared {
        case .success(let a): api = a
        case .failure(let e):
            logOnce("api", "error: \(e)")
            return
        }
        Log.debug("check (\(reason)\(full ? ", full" : ""))")

        let now = uptime()
        var present = Set<UInt64>()
        for fb in Registry.framebuffers() {
            guard let edid = fb.edidUUID else { continue }
            let id = fb.registryID
            present.insert(id)
            var st = states[id] ?? DisplayState(edid: edid)
            if st.edid != edid {
                st = DisplayState(edid: edid)
                handles[id] = nil
                lastLogged["state-\(id)"] = nil
            }
            evaluate(fb, &st, config: config, api: api, now: now, reason: reason, full: full)
            states[id] = st
        }
        for id in Array(states.keys) where !present.contains(id) {
            let label = states.removeValue(forKey: id)?.label
            handles[id] = nil
            lastLogged["state-\(id)"] = nil
            Log.info("\(label ?? "display on pipe 0x\(String(id, radix: 16))") disconnected")
        }
    }

    private func evaluate(_ fb: FramebufferService, _ st: inout DisplayState, config: AppConfig, api: IOMFB,
                          now: TimeInterval, reason: String, full: Bool) {
        let id = fb.registryID
        let handle: Framebuffer
        if let h = handles[id] {
            handle = h
        } else {
            do {
                handle = try Framebuffer(service: fb.service, api: api)
                handles[id] = handle
                lastLogged["open-\(id)"] = nil
            } catch {
                logOnce("open-\(id)", "error: \(fb.port): cannot open the framebuffer: \(error)")
                waitForLink(&st, config)
                return
            }
        }
        let mode: ModeIDs
        do {
            mode = try handle.currentMode()
            lastLogged["read-\(id)"] = nil
        } catch {
            handles[id] = nil // reopen next time
            logOnce("read-\(id)", "warning: \(fb.port): cannot read the current mode: \(error)")
            waitForLink(&st, config)
            return
        }
        if mode.color == 0 && mode.timing == 0 {
            Log.debug("\(fb.port): link not up yet")
            waitForLink(&st, config)
            return
        }

        // Fast path: nothing changed since this mode was last judged.
        if !full, st.settledGeneration == generation, st.settledMode == mode { return }

        guard let info = Registry.readDisplay(fb), !info.timings.isEmpty else {
            waitForLink(&st, config)
            return
        }
        st.linkWaits = 0
        let who = "\(info.name) [\(info.port)]"
        st.label = who

        guard let (index, rule) = config.rule(for: info) else {
            logOnce("state-\(id)", "\(who) (\(info.identity)): no matching rule, leaving it alone")
            st.settledGeneration = generation
            st.settledMode = mode
            return
        }
        let ruleName = "rule #\(index + 1) \"\(rule.title)\""

        switch Planner.plan(info, current: mode, rule: rule) {
        case .compliant:
            if st.compliantSince == nil { st.compliantSince = now }
            st.gaveUp = false
            st.settledGeneration = generation
            st.settledMode = mode
            logOnce("state-\(id)", "\(who): \(info.describe(mode)) satisfies \(ruleName)")

        case .impossible(let why):
            st.settledGeneration = generation
            st.settledMode = mode
            logOnce("state-\(id)", "warning: \(who): cannot satisfy \(ruleName): \(why)")

        case .change(let target):
            st.settledGeneration = nil
            st.settledMode = nil
            if Pause.activeUntil() != nil {
                logOnce("pause-\(id)", "\(who): setup is running; not switching")
                return
            }
            // A mode that held for a while means earlier attempts were a separate episode.
            if let since = st.compliantSince, now - since >= 120 {
                st.attempts = 0
                st.gaveUp = false
            }
            st.compliantSince = nil
            if st.attempts >= config.maxAttempts {
                if !st.gaveUp {
                    st.gaveUp = true
                    Log.warn("\(who): still not in the desired mode after \(st.attempts) attempts (is another app "
                        + "changing it?). Pausing until the display is reconnected, the Mac wakes, the config changes, "
                        + "or the daemon restarts (sudo launchctl kickstart -k system/local.mac-display).")
                }
                return
            }
            var history = (switchHistory[id] ?? []).filter { now - $0 < Self.loopWindow }
            if history.count >= loopLimit {
                switchHistory[id] = history
                logOnce("loop-\(id)", "warning: \(who): \(history.count) switches in \(Int(Self.loopWindow / 60)) minutes; "
                    + "the display may be re-connecting after every switch. Pausing switches for this display.")
                if let oldest = history.first { scheduleCheck?(Self.loopWindow - (now - oldest) + 1, "loop-guard") }
                return
            }
            let backoff = Self.backoff(afterAttempts: st.attempts)
            if let last = st.lastAttempt, now - last < backoff {
                scheduleCheck?(backoff - (now - last) + 0.1, "retry")
                return
            }
            Log.info("\(who): \(info.describe(mode)) -> \(info.describe(target)) (\(ruleName); trigger: \(reason))")
            st.attempts += 1
            st.lastAttempt = now
            history.append(now)
            switchHistory[id] = history
            lastLogged["state-\(id)"] = nil
            lastLogged["loop-\(id)"] = nil
            do {
                try handle.setMode(target)
            } catch {
                Log.error("\(who): \(error)")
                handles[id] = nil
            }
            scheduleCheck?(config.verifyDelaySeconds, "verify")
        }
    }

    /// A display is attached but its mode isn't readable yet: look again soon (a few times;
    /// display events and the poll cover anything later).
    private func waitForLink(_ st: inout DisplayState, _ config: AppConfig) {
        guard st.linkWaits < 5 else { return }
        st.linkWaits += 1
        scheduleCheck?(max(config.settleDelaySeconds, 2), "link-wait")
    }

    /// Whether `mac-display setup`'s pause started or ended since the last call.
    func pauseStateChanged() -> Bool {
        let until = Pause.activeUntil()
        let paused = until != nil
        guard paused != wasPaused else { return false }
        wasPaused = paused
        if let until {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            Log.info("paused by `mac-display setup` (lease until \(f.string(from: until)), renewed while it runs)")
        } else {
            let ended = FileManager.default.fileExists(atPath: Pause.path) ? "setup's pause expired" : "setup finished"
            Log.info("\(ended); resuming")
            for key in lastLogged.keys where key.hasPrefix("pause-") { lastLogged[key] = nil }
            resetEpisodes()
        }
        return true
    }

    /// Minimum seconds between consecutive attempts.
    static func backoff(afterAttempts n: Int) -> TimeInterval {
        let steps: [TimeInterval] = [0, 3, 10, 30, 60]
        return steps[min(max(n, 0), steps.count - 1)]
    }

    /// Log a message only when it differs from the last one logged under `key`.
    private func logOnce(_ key: String, _ message: String) {
        guard lastLogged[key] != message else { return }
        lastLogged[key] = message
        Log.info(message)
    }
}

/// Event plumbing: IOKit display/link notifications, sleep/wake, config-file watch,
/// a safety-net poll, and signals.
final class Daemon {
    private let engine: Engine
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var interestNotifiers: [UInt64: io_object_t] = [:]
    private var powerPort: IONotificationPortRef?
    private var powerConnection: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var pollTimer: DispatchSourceTimer?
    private var configTimer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var firstPendingEvent: TimeInterval?
    private var pendingReasons = Set<String>()
    private var pendingTopologyChange = false
    private var signalSources: [DispatchSourceSignal] = []

    /// Services that appear/disappear or post messages when a display connects,
    /// disconnects, retrains its link, or changes mode.
    static let watchedClasses = ["IOMobileFramebufferShim", "DCPAVServiceProxy", "DCPDPDeviceProxy", "DCPAVVideoInterfaceProxy"]
    /// Never postpone a check longer than this while events keep arriving.
    static let maxDebounce: TimeInterval = 10
    static let configCheckInterval: TimeInterval = 3

    init(engine: Engine) {
        self.engine = engine
    }

    func run() -> Never {
        engine.scheduleCheck = { [weak self] delay, reason in self?.schedule(after: delay, reason: reason) }
        engine.onConfigChange = { [weak self] in self?.restartPollTimer() }
        engine.reloadConfigIfNeeded(force: true)
        setupDisplayNotifications()
        setupPowerNotifications()
        setupSignals()
        startConfigWatch()
        restartPollTimer()
        schedule(after: 0, reason: "startup", full: true)
        dispatchMain()
    }

    /// A timed check (verify, retry, link-wait, startup). If display events are still
    /// settling, it folds into the pending debounced check instead of acting mid-change.
    private func schedule(after delay: TimeInterval, reason: String, full: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            if self.debounce != nil {
                self.pendingReasons.insert(reason)
                return
            }
            self.engine.check(reason: reason, full: full)
        }
    }

    /// Debounced: one full check once events have been quiet for `settleDelaySeconds`
    /// (but never later than `maxDebounce` after the first event).
    fileprivate func displayEvent(_ what: String, topology: Bool = false) {
        pendingReasons.insert(what)
        if topology { pendingTopologyChange = true }
        let now = uptime()
        if firstPendingEvent == nil { firstPendingEvent = now }
        debounce?.cancel()
        let settle = engine.config?.settleDelaySeconds ?? 2
        let waited = now - (firstPendingEvent ?? now)
        let delay = max(0, min(settle, Self.maxDebounce - waited))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reasons = self.pendingReasons.sorted().joined(separator: ",")
            let topology = self.pendingTopologyChange
            self.pendingReasons = []
            self.pendingTopologyChange = false
            self.firstPendingEvent = nil
            self.debounce = nil
            if topology { self.engine.noteTopologyChange() }
            self.engine.check(reason: reasons, full: true)
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func restartPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
        let interval = engine.config?.pollIntervalSeconds ?? 15
        guard interval > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.engine.check(reason: "poll") }
        t.resume()
        pollTimer = t
    }

    /// Notice config edits within a few seconds, independent of the poll interval
    /// (one stat() per tick).
    private func startConfigWatch() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.configCheckInterval, repeating: Self.configCheckInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let configChanged = self.engine.reloadConfigIfNeeded()
            let pauseChanged = self.engine.pauseStateChanged()
            if configChanged || pauseChanged { self.engine.check(reason: configChanged ? "config" : "pause", full: true) }
        }
        t.resume()
        configTimer = t
    }

    // MARK: IOKit display notifications

    private func setupDisplayNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.warn("cannot create an IOKit notification port; relying on polling")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for cls in Self.watchedClasses {
            var added: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(cls), Daemon.onMatched, ref, &added) == KERN_SUCCESS {
                iterators.append(added)
                drainMatched(added, initial: true)
            }
            var removed: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(cls), Daemon.onTerminated, ref, &removed) == KERN_SUCCESS {
                iterators.append(removed)
                drainTerminated(removed, initial: true)
            }
        }
    }

    private static let onMatched: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue().drainMatched(iterator, initial: false)
    }

    private static let onTerminated: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue().drainTerminated(iterator, initial: false)
    }

    private static let onInterest: IOServiceInterestCallback = { refcon, _, messageType, _ in
        guard let refcon else { return }
        let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
        Log.debug("IOKit message 0x\(String(messageType, radix: 16))")
        daemon.displayEvent("display-event")
    }

    private func drainMatched(_ iterator: io_iterator_t, initial: Bool) {
        var any = false
        while true {
            let s = IOIteratorNext(iterator)
            if s == 0 { break }
            any = true
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &id)
            if interestNotifiers[id] == nil, let port = notifyPort {
                var notifier: io_object_t = 0
                let ref = Unmanaged.passUnretained(self).toOpaque()
                if IOServiceAddInterestNotification(port, s, kIOGeneralInterest, Daemon.onInterest, ref, &notifier) == KERN_SUCCESS {
                    interestNotifiers[id] = notifier
                }
            }
            IOObjectRelease(s)
        }
        if any && !initial { displayEvent("device-added", topology: true) }
    }

    private func drainTerminated(_ iterator: io_iterator_t, initial: Bool) {
        var any = false
        while true {
            let s = IOIteratorNext(iterator)
            if s == 0 { break }
            any = true
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &id)
            if let n = interestNotifiers.removeValue(forKey: id) { IOObjectRelease(n) }
            IOObjectRelease(s)
        }
        if any && !initial { displayEvent("device-removed", topology: true) }
    }

    // MARK: Sleep / wake

    private func setupPowerNotifications() {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let connection = IORegisterForSystemPower(ref, &port, Daemon.onPower, &notifier)
        guard connection != 0, let port else {
            Log.warn("cannot register for sleep/wake notifications; relying on display events and polling")
            return
        }
        powerConnection = connection
        powerPort = port
        powerNotifier = notifier
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
    }

    private static let onPower: IOServiceInterestCallback = { refcon, _, messageType, argument in
        guard let refcon else { return }
        Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue().handlePower(messageType, argument)
    }

    private func handlePower(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case msgCanSystemSleep, msgSystemWillSleep:
            // Must acknowledge, or sleep is delayed by 30 s.
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
            if messageType == msgSystemWillSleep { Log.info("system going to sleep") }
        case msgSystemHasPoweredOn:
            Log.info("system woke; re-checking displays")
            engine.resetEpisodes()
            // Each follow-up goes through the debounce, so nothing is switched while the
            // link is still training; later ones catch a late WindowServer reconfigure.
            for delay: TimeInterval in [0, 6, 15, 30] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.displayEvent("wake") }
            }
        default:
            break
        }
    }

    // MARK: Signals

    private func setupSignals() {
        for sig in [SIGHUP, SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if sig == SIGHUP {
                    Log.info("SIGHUP: reloading config")
                    self.engine.reloadConfigIfNeeded(force: true)
                    self.engine.check(reason: "sighup", full: true)
                } else {
                    Log.info("exiting (signal \(sig))")
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
