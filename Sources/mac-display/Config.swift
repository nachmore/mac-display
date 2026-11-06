import Foundation

// MARK: - Config model

struct AppConfig {
    /// Safety-net re-check interval. Display/link/wake events trigger checks immediately. 0 disables.
    var pollIntervalSeconds: Double = 15
    /// How long display events must be quiet before acting (lets a link finish training).
    var settleDelaySeconds: Double = 2
    /// How long after a switch to re-check that it took.
    var verifyDelaySeconds: Double = 4
    /// Switch attempts per "episode" before pausing (prevents fighting another tool forever).
    /// An episode restarts when the display reconnects, the Mac wakes, or the config changes.
    var maxAttempts: Int = 5
    /// "info" (default) or "debug" (log every check and IOKit event; for troubleshooting).
    var debugLogging = false
    /// Daemon log rotation: start a new file at this size, keep this many old ones.
    var logMaxKB = 1024
    var logKeep = 3
    var displays: [DisplayRule] = []

    /// First enabled rule that matches the display.
    func rule(for display: DisplayInfo) -> (index: Int, rule: DisplayRule)? {
        for (i, r) in displays.enumerated() where r.enabled && r.match.matches(display) {
            return (i, r)
        }
        return nil
    }

    static func load(path: String) throws -> AppConfig {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw MacDisplayError.config("cannot read \(path): \((error as NSError).localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            throw MacDisplayError.config("\(path): \(describeDecodingError(error))")
        }
    }
}

struct DisplayRule {
    var label: String?
    var enabled = true
    var match = DisplayMatch()
    var colorMode: ColorCriteria?
    var timing: TimingCriteria?

    var title: String { label ?? match.summary }

    var wants: String {
        [colorMode?.summary, timing?.summary].compactMap { $0 }.joined(separator: " @ ")
    }
}

struct DisplayMatch {
    /// EDID product name, e.g. "LC49G95T". Glob patterns (`*`, `?`) allowed; case-insensitive.
    var name: [String]?
    /// EDID manufacturer ID, e.g. "SAM", "DEL", "GSM".
    var vendor: [String]?
    var productID: [Int]?
    /// EDID serial: the alphanumeric serial string, or the numeric serial.
    var serial: [String]?
    /// Display pipe the monitor is attached to, e.g. "dispext0". Glob patterns allowed.
    var port: [String]?

    func matches(_ d: DisplayInfo) -> Bool {
        if let name, !name.contains(where: { glob($0, d.productName ?? "") }) { return false }
        if let vendor, !vendor.contains(where: { $0.caseInsensitiveCompare(d.vendor ?? "") == .orderedSame }) { return false }
        if let productID, !productID.contains(where: { $0 == d.productID }) { return false }
        if let serial {
            let candidates = [d.alphanumericSerial, d.serialNumber.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }
            if !serial.contains(where: { s in candidates.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }) { return false }
        }
        if let port, !port.contains(where: { glob($0, d.port) }) { return false }
        return true
    }

    var summary: String {
        var parts: [String] = []
        if let name { parts.append("name " + name.joined(separator: "|")) }
        if let vendor { parts.append("vendor " + vendor.joined(separator: "|")) }
        if let productID { parts.append("product " + productID.map(String.init).joined(separator: "|")) }
        if let serial { parts.append("serial " + serial.joined(separator: "|")) }
        if let port { parts.append("port " + port.joined(separator: "|")) }
        return parts.isEmpty ? "any display" : parts.joined(separator: ", ")
    }
}

struct ColorCriteria {
    /// Exact DCP colour element ID (see `mac-display list`). Overrides nothing else; all given fields must match.
    var id: Int?
    var bitDepth: Int?
    var encoding: PixelEncoding?
    var range: QuantRange?
    /// false = SDR only, true = any HDR transfer function.
    var hdr: Bool?
    var eotf: Eotf?
    var colorimetry: Int?

    var isEmpty: Bool {
        id == nil && bitDepth == nil && encoding == nil && range == nil && hdr == nil && eotf == nil && colorimetry == nil
    }

    func matches(_ c: ColorElement) -> Bool {
        if let id, c.id != id { return false }
        if let bitDepth, c.depth != bitDepth { return false }
        if let encoding, c.encoding != encoding { return false }
        if let range, c.rangeRaw != range.rawValue { return false }
        if let hdr, c.eotf.isHDR != hdr { return false }
        if let eotf, c.eotf != eotf { return false }
        if let colorimetry, c.colorimetry != colorimetry { return false }
        return true
    }

    var summary: String {
        var parts: [String] = []
        if let id { parts.append("color \(id)") }
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        if let eotf { parts.append(eotf.label) } else if let hdr { parts.append(hdr ? "HDR" : "SDR") }
        if let encoding { parts.append(encoding.label) }
        if let range { parts.append(range.label) }
        if let colorimetry { parts.append(Colorimetry.label(colorimetry)) }
        return parts.isEmpty ? "any colour mode" : parts.joined(separator: " ")
    }
}

struct TimingCriteria {
    /// Exact DCP timing element ID (see `mac-display list --timings`).
    var id: Int?
    var width: Int?
    var height: Int?
    var refreshHz: Double?
    var refreshToleranceHz: Double = 0.5

    func matches(_ t: TimingElement) -> Bool {
        if let id, t.id != id { return false }
        if let width, t.width != width { return false }
        if let height, t.height != height { return false }
        if let refreshHz, abs(t.refreshHz - refreshHz) > refreshToleranceHz { return false }
        return true
    }

    var summary: String {
        var parts: [String] = []
        if let id { parts.append("timing \(id)") }
        if width != nil || height != nil {
            parts.append("\(width.map(String.init) ?? "*")x\(height.map(String.init) ?? "*")")
        }
        if let refreshHz { parts.append(String(format: "%g Hz", refreshHz)) }
        return parts.isEmpty ? "any timing" : parts.joined(separator: " ")
    }
}

// MARK: - Decoding (strict: unknown keys are errors, so typos don't silently do nothing)

struct AnyKey: CodingKey {
    let stringValue: String
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

private func pathString(_ path: [CodingKey]) -> String {
    var s = ""
    for k in path {
        if let i = k.intValue { s += "[\(i)]" } else { s += (s.isEmpty ? "" : ".") + k.stringValue }
    }
    return s.isEmpty ? "top level" : s
}

private func strictContainer(_ decoder: Decoder, _ allowed: [String]) throws -> KeyedDecodingContainer<AnyKey> {
    let c = try decoder.container(keyedBy: AnyKey.self)
    // Keys starting with "_" are ignored, so they can be used for notes.
    let unknown = c.allKeys.map(\.stringValue).filter { !allowed.contains($0) && !$0.hasPrefix("_") }
    if !unknown.isEmpty {
        throw MacDisplayError.config(
            "\(pathString(decoder.codingPath)): unknown key(s) \(unknown.sorted().map { "\"\($0)\"" }.joined(separator: ", ")); "
                + "allowed: \(allowed.joined(separator: ", "))")
    }
    return c
}

private func invalid(_ decoder: Decoder, _ key: String, _ message: String) -> MacDisplayError {
    let p = pathString(decoder.codingPath)
    return .config("\(p == "top level" ? "" : p + ".")\(key): \(message)")
}

/// Error for the object being decoded itself (not one of its keys).
private func invalidHere(_ decoder: Decoder, _ message: String) -> MacDisplayError {
    .config("\(pathString(decoder.codingPath)): \(message)")
}

/// One element of a list that may hold strings or (whole) numbers.
private struct StringOrNumber: Decodable {
    let string: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            string = s
        } else if let d = try? c.decode(Double.self), d.rounded() == d, abs(d) < 1e15 {
            string = String(Int(d))
        } else {
            throw invalidHere(decoder, "expected a string or a whole number")
        }
    }
}

private extension KeyedDecodingContainer where Key == AnyKey {
    func opt<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T? {
        try decodeIfPresent(T.self, forKey: AnyKey(key))
    }

    /// A whole number (8.0 is fine, 8.5 is an error with a useful message).
    func int(_ key: String, _ decoder: Decoder) throws -> Int? {
        let k = AnyKey(key)
        guard contains(k) else { return nil }
        guard let d = try? decode(Double.self, forKey: k) else { throw invalid(decoder, key, "must be a number") }
        guard d.rounded() == d, abs(d) < 1e15 else { throw invalid(decoder, key, "must be a whole number") }
        return Int(d)
    }

    /// A string or number, or an array of them; returned as strings.
    func stringList(_ key: String, _ decoder: Decoder) throws -> [String]? {
        let k = AnyKey(key)
        guard contains(k) else { return nil }
        if let one = try? decode(StringOrNumber.self, forKey: k) { return [one.string] }
        guard let many = try? decode([StringOrNumber].self, forKey: k) else {
            throw invalid(decoder, key, "expected a string, a number, or a list of them")
        }
        return many.map(\.string)
    }

    /// A whole number, or an array of them.
    func intList(_ key: String, _ decoder: Decoder) throws -> [Int]? {
        guard let strings = try stringList(key, decoder) else { return nil }
        return try strings.map {
            guard let i = Int($0) else { throw invalid(decoder, key, "expected a whole number or a list of them") }
            return i
        }
    }

    /// A string or a whole number, returned as a string.
    func stringOrNumber(_ key: String, _ decoder: Decoder) throws -> String? {
        let k = AnyKey(key)
        guard contains(k) else { return nil }
        guard let v = try? decode(StringOrNumber.self, forKey: k) else {
            throw invalid(decoder, key, "expected a string or a whole number")
        }
        return v.string
    }
}

extension AppConfig: Decodable {
    init(from decoder: Decoder) throws {
        let c = try strictContainer(decoder, ["pollIntervalSeconds", "settleDelaySeconds", "verifyDelaySeconds", "maxAttempts",
                                              "logLevel", "logMaxKB", "logKeep", "displays"])
        if let v = try c.opt("pollIntervalSeconds", Double.self) {
            guard v == 0 || (1...3600).contains(v) else { throw invalid(decoder, "pollIntervalSeconds", "must be 0 (off) or 1-3600") }
            pollIntervalSeconds = v
        }
        if let v = try c.opt("settleDelaySeconds", Double.self) {
            guard (0...60).contains(v) else { throw invalid(decoder, "settleDelaySeconds", "must be 0-60") }
            settleDelaySeconds = v
        }
        if let v = try c.opt("verifyDelaySeconds", Double.self) {
            guard (1...60).contains(v) else { throw invalid(decoder, "verifyDelaySeconds", "must be 1-60") }
            verifyDelaySeconds = v
        }
        if let v = try c.int("maxAttempts", decoder) {
            guard (1...100).contains(v) else { throw invalid(decoder, "maxAttempts", "must be 1-100") }
            maxAttempts = v
        }
        if let level = try c.opt("logLevel", String.self) {
            switch level.lowercased() {
            case "info": debugLogging = false
            case "debug": debugLogging = true
            default: throw invalid(decoder, "logLevel", "must be \"info\" or \"debug\"")
            }
        }
        if let v = try c.int("logMaxKB", decoder) {
            guard (16...1_048_576).contains(v) else { throw invalid(decoder, "logMaxKB", "must be 16-1048576") }
            logMaxKB = v
        }
        if let v = try c.int("logKeep", decoder) {
            guard (0...RotatingLogFile.maxKeep).contains(v) else { throw invalid(decoder, "logKeep", "must be 0-\(RotatingLogFile.maxKeep)") }
            logKeep = v
        }
        displays = try c.opt("displays", [DisplayRule].self) ?? []
    }
}

extension DisplayRule: Decodable {
    init(from decoder: Decoder) throws {
        let c = try strictContainer(decoder, ["label", "enabled", "match", "colorMode", "timing"])
        label = try c.opt("label", String.self)
        enabled = try c.opt("enabled", Bool.self) ?? true
        guard let m = try c.opt("match", DisplayMatch.self) else {
            throw invalid(decoder, "match", "required (use {} to match every display)")
        }
        match = m
        colorMode = try c.opt("colorMode", ColorCriteria.self)
        timing = try c.opt("timing", TimingCriteria.self)
        if colorMode == nil && timing == nil {
            throw invalidHere(decoder, "a rule needs \"colorMode\" and/or \"timing\"")
        }
    }
}

extension DisplayMatch: Decodable {
    init(from decoder: Decoder) throws {
        let c = try strictContainer(decoder, ["name", "vendor", "productID", "serial", "port"])
        name = try c.stringList("name", decoder)
        vendor = try c.stringList("vendor", decoder)
        productID = try c.intList("productID", decoder)
        serial = try c.stringList("serial", decoder) // alphanumeric or numeric
        port = try c.stringList("port", decoder)
        for (key, list) in [("name", name), ("vendor", vendor), ("serial", serial), ("port", port)] where list?.isEmpty == true {
            throw invalid(decoder, key, "empty list would never match")
        }
        if productID?.isEmpty == true { throw invalid(decoder, "productID", "empty list would never match") }
    }
}

extension ColorCriteria: Decodable {
    init(from decoder: Decoder) throws {
        let c = try strictContainer(decoder, ["id", "bitDepth", "encoding", "range", "hdr", "eotf", "colorimetry"])
        id = try c.int("id", decoder)
        if let d = try c.int("bitDepth", decoder) {
            guard [6, 8, 10, 12, 14, 16].contains(d) else { throw invalid(decoder, "bitDepth", "must be 6, 8, 10, 12, 14 or 16") }
            bitDepth = d
        }
        if let e = try c.stringOrNumber("encoding", decoder) {
            guard let v = PixelEncoding(name: e) else {
                throw invalid(decoder, "encoding", "\"\(e)\" is not one of \(PixelEncoding.names.joined(separator: ", ")) (or a raw code)")
            }
            encoding = v
        }
        if let r = try c.stringOrNumber("range", decoder) {
            guard let v = QuantRange(name: r) else { throw invalid(decoder, "range", "must be \"full\" or \"limited\"") }
            range = v
        }
        hdr = try c.opt("hdr", Bool.self)
        if let e = try c.stringOrNumber("eotf", decoder) {
            guard let v = Eotf(name: e) else {
                throw invalid(decoder, "eotf", "must be one of \(Eotf.names.joined(separator: ", ")) (or a raw code)")
            }
            eotf = v
        }
        if let e = eotf, let h = hdr, e.isHDR != h {
            throw invalid(decoder, "eotf", "\"\(e.label)\" contradicts \"hdr\": \(h)")
        }
        if let s = try c.stringOrNumber("colorimetry", decoder) {
            guard let v = Colorimetry.code(named: s) else {
                throw invalid(decoder, "colorimetry", "unknown value \"\(s)\"; use one of \(Colorimetry.table.map(\.key).joined(separator: ", ")) (or a raw code)")
            }
            colorimetry = v
        }
        if isEmpty { throw invalidHere(decoder, "is empty; set at least one of bitDepth, encoding, range, hdr, eotf, colorimetry, id") }
    }
}

extension TimingCriteria: Decodable {
    init(from decoder: Decoder) throws {
        let c = try strictContainer(decoder, ["id", "width", "height", "resolution", "refreshHz", "refreshToleranceHz"])
        id = try c.int("id", decoder)
        width = try c.int("width", decoder)
        height = try c.int("height", decoder)
        if let res = try c.opt("resolution", String.self) {
            guard let (w, h) = parseResolution(res) else { throw invalid(decoder, "resolution", "expected \"WIDTHxHEIGHT\", e.g. \"5120x1440\"") }
            if (width != nil && width != w) || (height != nil && height != h) {
                throw invalid(decoder, "resolution", "conflicts with width/height")
            }
            width = w
            height = h
        }
        if let r = try c.opt("refreshHz", Double.self) {
            guard r > 0 && r < 1000 else { throw invalid(decoder, "refreshHz", "must be between 0 and 1000") }
            refreshHz = r
        }
        if let t = try c.opt("refreshToleranceHz", Double.self) {
            guard t >= 0 && t <= 10 else { throw invalid(decoder, "refreshToleranceHz", "must be 0-10") }
            refreshToleranceHz = t
        }
        if id == nil && width == nil && height == nil && refreshHz == nil {
            throw invalidHere(decoder, "is empty; set resolution/width/height, refreshHz, or id")
        }
    }
}

extension DisplayMatch: Equatable {}

func parseResolution(_ s: String) -> (Int, Int)? {
    let parts = s.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
    return (w, h)
}

func glob(_ pattern: String, _ string: String) -> Bool {
    fnmatch(pattern, string, FNM_CASEFOLD) == 0
}

func describeDecodingError(_ error: Error) -> String {
    if let e = error as? MacDisplayError {
        if case .config(let m) = e { return m }
        return e.description
    }
    guard let e = error as? DecodingError else { return "\(error)" }
    func render(_ ctx: DecodingError.Context) -> String {
        var msg = ctx.debugDescription
        if let u = ctx.underlyingError as NSError?, let detail = u.userInfo[NSDebugDescriptionErrorKey] as? String ?? u.userInfo["NSDebugDescription"] as? String {
            msg += " (\(detail))"
        }
        return ctx.codingPath.isEmpty ? msg : "\(pathString(ctx.codingPath)): \(msg)"
    }
    switch e {
    case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .keyNotFound(_, let ctx), .dataCorrupted(let ctx):
        return render(ctx)
    @unknown default:
        return "\(e)"
    }
}
