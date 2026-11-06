import Foundation

enum Plan {
    /// Current mode already satisfies the rule.
    case compliant
    /// Switch to this colour/timing pair.
    case change(ModeIDs)
    /// The display offers nothing that satisfies the rule.
    case impossible(String)
}

enum Planner {
    /// Decide what (if anything) to switch to. Attributes the rule doesn't mention are kept
    /// as close to the current mode as possible; remaining ties go to the mode macOS itself
    /// scores highest. A rule without `timing` never changes the timing.
    static func plan(_ d: DisplayInfo, current: ModeIDs, rule: DisplayRule) -> Plan {
        guard let currentTiming = d.timing(current.timing) else {
            return .impossible("current timing \(current.timing) is not in the display's timing list")
        }
        let currentColor = d.color(current.color, timing: current.timing)

        /// Whether a timing offers a colour mode the rule accepts.
        func offersColor(_ t: TimingElement) -> Bool {
            guard let cc = rule.colorMode else { return !t.usableColorModes.isEmpty }
            return t.usableColorModes.contains(where: cc.matches)
        }

        // 1. Timing: keep the current one unless the rule asks for something it can't give.
        var target = currentTiming
        if let tc = rule.timing, !(tc.matches(currentTiming) && offersColor(currentTiming)) {
            let matching = d.timings.filter { !$0.isVirtual && tc.matches($0) }
            guard let best = matching.filter(offersColor).min(by: {
                timingRank($0, tc, currentTiming) < timingRank($1, tc, currentTiming)
            }) else {
                if matching.isEmpty {
                    return .impossible("no timing matches \(tc.summary); available: \(timingList(d))")
                }
                return .impossible("no timing matching \(tc.summary) offers \(rule.colorMode?.summary ?? "a usable colour mode")")
            }
            target = best
        }
        let timingChanges = target.id != currentTiming.id
        let usable = target.usableColorModes

        // 2. Colour
        guard let cc = rule.colorMode else {
            if !timingChanges { return .compliant }
            if usable.contains(where: { $0.id == current.color }) {
                return .change(ModeIDs(color: current.color, timing: target.id))
            }
            guard !usable.isEmpty else { return .impossible("timing \(target.summary) has no usable colour modes") }
            return .change(ModeIDs(color: pick(usable, closestTo: currentColor).id, timing: target.id))
        }

        if !timingChanges, let cur = currentColor, cc.matches(cur) { return .compliant }
        let candidates = usable.filter { cc.matches($0) }
        guard !candidates.isEmpty else {
            let available = usable.map { "\($0.summary) [\($0.id)]" }
            return .impossible("no colour mode at \(target.summary) matches \(cc.summary); available: \(available.joined(separator: "; "))")
        }
        return .change(ModeIDs(color: pick(candidates, closestTo: currentColor).id, timing: target.id))
    }

    /// Lower is better: change as few unrequested attributes (resolution, refresh) as
    /// possible, then closest to the requested refresh (0.1 Hz granularity, so 59.98 and
    /// 60.00 tie), then the display's preferred timing, then macOS's score, then closest
    /// to the current refresh rate.
    private static func timingRank(_ t: TimingElement, _ tc: TimingCriteria, _ cur: TimingElement)
        -> (Int, Double, Int, Int, Double, Int)
    {
        var changes = 0
        if tc.width == nil && t.width != cur.width { changes += 1 }
        if tc.height == nil && t.height != cur.height { changes += 1 }
        if tc.refreshHz == nil && abs(t.refreshHz - cur.refreshHz) > tc.refreshToleranceHz { changes += 1 }
        let distance = tc.refreshHz.map { (abs(t.refreshHz - $0) * 10).rounded(.down) / 10 } ?? 0
        return (changes, distance, t.isPreferred ? 0 : 1, -t.score, abs(t.refreshHz - cur.refreshHz), t.id)
    }

    private static func timingList(_ d: DisplayInfo) -> String {
        let timings = d.timings.filter { !$0.isVirtual }.sorted {
            ($0.width * $0.height, $0.width, $0.refreshHz) > ($1.width * $1.height, $1.width, $1.refreshHz)
        }
        var seen = Set<String>()
        return timings.map(\.summary).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// Prefer candidates that keep more of the current mode's attributes, then macOS's score.
    /// Colorimetry is left to the score: it follows from the encoding, and keeping a
    /// leftover colorimetry from an unrelated mode is rarely what anyone wants.
    static func pick(_ candidates: [ColorElement], closestTo current: ColorElement?) -> ColorElement {
        candidates.max { a, b in
            (similarity(a, current), a.score, -a.id) < (similarity(b, current), b.score, -b.id)
        }!
    }

    private static func similarity(_ c: ColorElement, _ current: ColorElement?) -> Int {
        guard let cur = current else { return 0 }
        var n = 0
        if c.depth == cur.depth { n += 1 }
        if c.encoding == cur.encoding { n += 1 }
        if c.rangeRaw == cur.rangeRaw { n += 1 }
        if c.eotf == cur.eotf { n += 1 }
        return n
    }
}
