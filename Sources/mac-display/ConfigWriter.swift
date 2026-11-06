import Foundation

// Renders an AppConfig back to a commented JSON5 file (used by `setup` and `default-config`).

private func q(_ s: String) -> String {
    let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
    return String(decoding: data, as: UTF8.self)
}

private func num(_ d: Double) -> String {
    d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(format: "%g", d)
}

private func list(_ values: [String]) -> String {
    values.count == 1 ? q(values[0]) : "[" + values.map(q).joined(separator: ", ") + "]"
}

private func object(_ fields: [(String, String)]) -> String {
    "{ " + fields.map { "\(q($0.0)): \($0.1)" }.joined(separator: ", ") + " }"
}

extension DisplayMatch {
    var rendered: String {
        var f: [(String, String)] = []
        if let name { f.append(("name", list(name))) }
        if let vendor { f.append(("vendor", list(vendor))) }
        if let productID { f.append(("productID", productID.count == 1 ? "\(productID[0])" : "[" + productID.map(String.init).joined(separator: ", ") + "]")) }
        if let serial { f.append(("serial", list(serial))) }
        if let port { f.append(("port", list(port))) }
        return f.isEmpty ? "{}" : object(f)
    }
}

extension ColorCriteria {
    var rendered: String {
        var f: [(String, String)] = []
        if let id { f.append(("id", "\(id)")) }
        if let bitDepth { f.append(("bitDepth", "\(bitDepth)")) }
        if let hdr { f.append(("hdr", hdr ? "true" : "false")) }
        if let eotf {
            if case .other(let n) = eotf { f.append(("eotf", "\(n)")) } else { f.append(("eotf", q(eotf.key))) }
        }
        if let encoding {
            if case .other(let n) = encoding { f.append(("encoding", "\(n)")) } else { f.append(("encoding", q(encoding.key))) }
        }
        if let range { f.append(("range", q(range == .full ? "full" : "limited"))) }
        if let colorimetry {
            let key = Colorimetry.key(colorimetry)
            f.append(("colorimetry", Int(key) == nil ? q(key) : key))
        }
        return object(f)
    }
}

extension TimingCriteria {
    var rendered: String {
        var f: [(String, String)] = []
        if let id { f.append(("id", "\(id)")) }
        if let width, let height {
            f.append(("resolution", q("\(width)x\(height)")))
        } else {
            if let width { f.append(("width", "\(width)")) }
            if let height { f.append(("height", "\(height)")) }
        }
        if let refreshHz { f.append(("refreshHz", num(refreshHz))) }
        if refreshToleranceHz != 0.5 { f.append(("refreshToleranceHz", num(refreshToleranceHz))) }
        return object(f)
    }
}

extension DisplayRule {
    func rendered(indent: String = "    ") -> String {
        var lines: [String] = []
        if let label { lines.append("\"label\": \(q(label))") }
        if !enabled { lines.append("\"enabled\": false") }
        lines.append("\"match\": \(match.rendered)")
        if let colorMode { lines.append("\"colorMode\": \(colorMode.rendered)") }
        if let timing { lines.append("\"timing\": \(timing.rendered)") }
        return "\(indent){\n" + lines.map { "\(indent)  \($0)" }.joined(separator: ",\n") + "\n\(indent)}"
    }
}

extension AppConfig {
    func rendered() -> String {
        let defaults = AppConfig()
        var top: [String] = [
            "  // Display events and wake trigger checks immediately; this poll is a safety net (0 = off).",
            "  \"pollIntervalSeconds\": \(num(pollIntervalSeconds)),",
            "  // \"info\", or \"debug\" to log every check and IOKit event.",
            "  \"logLevel\": \(q(debugLogging ? "debug" : "info")),",
            "  // The log rotates itself: a new file at logMaxKB, keeping logKeep old ones.",
            "  \"logMaxKB\": \(logMaxKB),",
            "  \"logKeep\": \(logKeep),",
        ]
        if settleDelaySeconds != defaults.settleDelaySeconds { top.append("  \"settleDelaySeconds\": \(num(settleDelaySeconds)),") }
        if verifyDelaySeconds != defaults.verifyDelaySeconds { top.append("  \"verifyDelaySeconds\": \(num(verifyDelaySeconds)),") }
        if maxAttempts != defaults.maxAttempts { top.append("  \"maxAttempts\": \(maxAttempts),") }

        let rules = displays.isEmpty
            ? "  \"displays\": [\n    // Nothing yet. Run `mac-display setup`, or add a rule like:\n"
                + "    // { \"label\": \"My monitor\", \"match\": { \"name\": \"LC49G95T\" },\n"
                + "    //   \"colorMode\": { \"bitDepth\": 8, \"hdr\": false, \"encoding\": \"ycbcr444\", \"range\": \"limited\" } },\n  ],"
            : "  \"displays\": [\n" + displays.map { $0.rendered() }.joined(separator: ",\n") + ",\n  ],"

        return configHeader + "{\n" + top.joined(separator: "\n") + "\n\n"
            + "  // Rules are tried in order; the first enabled rule whose \"match\" fits a display wins.\n"
            + "  // Displays that match no rule are left alone.\n"
            + rules + "\n}\n"
    }
}

private let configHeader = """
// mac-display config (JSON with comments; trailing commas are fine).
// Written by `mac-display setup`; hand edits are fine too. The daemon picks up changes
// within a few seconds; an invalid edit is logged and the previous version kept.
//
//   mac-display setup         pick a display, try its modes, save one here
//   mac-display list          every mode each display offers (`list --json` = paste-able values)
//   mac-display status        daemon health + what this config does
//   mac-display check-config  validate this file
//
// Rule reference:
//   match:     name (EDID product name, globs OK) | vendor ("SAM") | productID | serial | port ("dispext0")
//              (each also takes a list = any of; every key given must match; {} = every display)
//   colorMode: bitDepth 6|8|10|12 · encoding "rgb"|"ycbcr444"|"ycbcr422"|"ycbcr420" · range "full"|"limited"
//              hdr true|false · eotf "sdr"|"pq"|"hlg" · colorimetry "bt709"|"bt601"|"bt2020"|"srgb"|… · id N
//              (only what you give is enforced; the rest stays as close to the current mode as possible)
//   timing:    resolution "WxH" (or width/height) · refreshHz N · refreshToleranceHz (0.5) · id N
//              (optional; without it the resolution/refresh rate is never changed)

"""
