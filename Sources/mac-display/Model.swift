import Foundation

// MARK: - Attribute vocabularies (DCP "ColorElements" fields)

enum PixelEncoding: Hashable {
    case rgb, ycbcr420, ycbcr422, ycbcr444, other(Int)

    // DCP PixelEncoding codes. 3 is YCbCr 4:4:4 and 2 is 4:2:2: DCP scores 3 above 2
    // (just as it scores RGB above both), only 3 is DSC-capable (DSC mandates 4:4:4
    // support, not 4:2:2), and BetterDisplay labels code 3 as "YCbCr 4:4:4".
    // Asahi Linux's parser.h lists these two the other way round.
    init(raw: Int) {
        switch raw {
        case 0: self = .rgb
        case 1: self = .ycbcr420
        case 2: self = .ycbcr422
        case 3: self = .ycbcr444
        default: self = .other(raw)
        }
    }

    var raw: Int {
        switch self {
        case .rgb: return 0
        case .ycbcr420: return 1
        case .ycbcr422: return 2
        case .ycbcr444: return 3
        case .other(let n): return n
        }
    }

    var key: String {
        switch self {
        case .rgb: return "rgb"
        case .ycbcr420: return "ycbcr420"
        case .ycbcr422: return "ycbcr422"
        case .ycbcr444: return "ycbcr444"
        case .other(let n): return "\(n)"
        }
    }

    var label: String {
        switch self {
        case .rgb: return "RGB"
        case .ycbcr420: return "YCbCr 4:2:0"
        case .ycbcr422: return "YCbCr 4:2:2"
        case .ycbcr444: return "YCbCr 4:4:4"
        case .other(let n): return "encoding \(n)"
        }
    }

    init?(name: String) {
        let k = normalizeKey(name)
        switch k {
        case "rgb", "rgb444": self = .rgb
        case "ycbcr444", "yuv444", "ycc444", "444": self = .ycbcr444
        case "ycbcr422", "yuv422", "ycc422", "422": self = .ycbcr422
        case "ycbcr420", "yuv420", "ycc420", "420": self = .ycbcr420
        default:
            if let n = Int(k) { self.init(raw: n) } else { return nil }
        }
    }

    static let names = ["rgb", "ycbcr444", "ycbcr422", "ycbcr420"]
}

/// Quantisation range (DCP calls this "DynamicRange": 0 = full, 1 = limited).
enum QuantRange: Int {
    case full = 0, limited = 1

    var label: String { self == .full ? "Full" : "Limited" }

    init?(name: String) {
        switch normalizeKey(name) {
        case "full", "pc", "0": self = .full
        case "limited", "video", "tv", "1": self = .limited
        default: return nil
        }
    }
}

/// Transfer function (DCP "EOTF").
enum Eotf: Hashable {
    case sdr, hdrGamma, pq, hlg, other(Int)

    init(raw: Int) {
        switch raw {
        case 0: self = .sdr
        case 1: self = .hdrGamma
        case 2: self = .pq
        case 3: self = .hlg
        default: self = .other(raw)
        }
    }

    var raw: Int {
        switch self {
        case .sdr: return 0
        case .hdrGamma: return 1
        case .pq: return 2
        case .hlg: return 3
        case .other(let n): return n
        }
    }

    var label: String {
        switch self {
        case .sdr: return "SDR"
        case .hdrGamma: return "HDR (gamma)"
        case .pq: return "HDR (PQ)"
        case .hlg: return "HDR (HLG)"
        case .other(let n): return "EOTF \(n)"
        }
    }

    var isHDR: Bool { self != .sdr }

    /// Config spelling.
    var key: String {
        switch self {
        case .sdr: return "sdr"
        case .hdrGamma: return "hdr-gamma"
        case .pq: return "pq"
        case .hlg: return "hlg"
        case .other(let n): return "\(n)"
        }
    }

    init?(name: String) {
        let k = normalizeKey(name)
        switch k {
        case "sdr": self = .sdr
        case "hdrgamma": self = .hdrGamma
        case "pq", "hdr10", "st2084", "hdrpq": self = .pq
        case "hlg", "hdrhlg": self = .hlg
        default:
            if let n = Int(k) { self.init(raw: n) } else { return nil }
        }
    }

    static let names = ["sdr", "pq", "hlg", "hdr-gamma"]
}

/// DCP colorimetry codes (as reverse-engineered by Asahi Linux; consistent with the
/// values seen on real displays: 0/1 for YCbCr SDR, 7/9 for BT.2020, 10 for sRGB).
enum Colorimetry {
    static let table: [(code: Int, key: String, label: String)] = [
        (0, "bt601", "BT.601"),
        (1, "bt709", "BT.709"),
        (2, "xvycc601", "xvYCC 601"),
        (3, "xvycc709", "xvYCC 709"),
        (4, "sycc601", "sYCC 601"),
        (5, "adobeycc601", "AdobeYCC 601"),
        (6, "bt2020c", "BT.2020 (constant luminance)"),
        (7, "bt2020", "BT.2020"),
        (8, "dolbyvision", "Dolby Vision"),
        (9, "bt2020rgb", "BT.2020 RGB"),
        (10, "srgb", "sRGB"),
        (11, "scrgb", "scRGB"),
        (12, "scrgbfixed", "scRGB fixed"),
        (13, "adobergb", "Adobe RGB"),
        (14, "dcip3d65", "DCI-P3 D65"),
        (15, "dcip3theater", "DCI-P3 theater"),
        (16, "rgb", "default RGB"),
    ]

    static func label(_ code: Int) -> String {
        table.first { $0.code == code }?.label ?? "colorimetry \(code)"
    }

    static func key(_ code: Int) -> String {
        table.first { $0.code == code }?.key ?? "\(code)"
    }

    /// Accepts a key ("bt709"), a label as printed by `list` ("BT.709"), or a raw code.
    static func code(named name: String) -> Int? {
        let k = normalizeKey(name)
        if let n = Int(k) { return n }
        return table.first { $0.key == k || normalizeKey($0.label) == k }?.code
    }
}

/// Lowercase and strip everything but letters and digits ("YCbCr 4:4:4" -> "ycbcr444").
func normalizeKey(_ s: String) -> String {
    String(s.lowercased().filter { $0.isLetter || $0.isNumber })
}

// MARK: - Elements

struct ColorElement {
    let id: Int
    let depth: Int
    let encoding: PixelEncoding
    let rangeRaw: Int
    let eotf: Eotf
    let colorimetry: Int
    let score: Int
    let isVirtual: Bool
    let supportsDSC: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["ID"] as? Int else { return nil }
        self.id = id
        depth = d["Depth"] as? Int ?? 0
        encoding = PixelEncoding(raw: d["PixelEncoding"] as? Int ?? -1)
        rangeRaw = d["DynamicRange"] as? Int ?? -1
        eotf = Eotf(raw: d["EOTF"] as? Int ?? -1)
        colorimetry = d["Colorimetry"] as? Int ?? -1
        score = d["Score"] as? Int ?? 0
        isVirtual = d["IsVirtual"] as? Bool ?? false
        supportsDSC = (d["SupportsDSC"] as? Int ?? 0) != 0
    }

    var range: QuantRange? { QuantRange(rawValue: rangeRaw) }
    var rangeLabel: String { range?.label ?? "range \(rangeRaw)" }

    /// e.g. "8-bit SDR YCbCr 4:4:4 Limited, BT.709"
    var summary: String {
        "\(depth)-bit \(eotf.label) \(encoding.label) \(rangeLabel), \(Colorimetry.label(colorimetry))"
    }

    /// Field names and values match the config's colorMode keys, so they can be copied over.
    var json: [String: Any] {
        [
            "id": id, "bitDepth": depth,
            "encoding": encoding.key, "encodingCode": encoding.raw, "encodingLabel": encoding.label,
            "range": range.map { $0 == .full ? "full" : "limited" } ?? "\(rangeRaw)", "rangeCode": rangeRaw,
            "hdr": eotf.isHDR, "eotf": eotf.key, "eotfCode": eotf.raw, "eotfLabel": eotf.label,
            "colorimetry": Colorimetry.key(colorimetry), "colorimetryCode": colorimetry,
            "colorimetryLabel": Colorimetry.label(colorimetry),
            "score": score, "virtual": isVirtual, "summary": summary,
        ]
    }
}

struct TimingElement {
    let id: Int
    let width: Int
    let height: Int
    let refreshHz: Double
    let score: Int
    let isVirtual: Bool
    let isPreferred: Bool
    let isInterlaced: Bool
    let colorModes: [ColorElement]
    let unsafeColorIDs: Set<Int>

    init?(_ d: [String: Any]) {
        guard let id = d["ID"] as? Int else { return nil }
        self.id = id
        let h = d["HorizontalAttributes"] as? [String: Any] ?? [:]
        let v = d["VerticalAttributes"] as? [String: Any] ?? [:]
        width = h["Active"] as? Int ?? 0
        height = v["Active"] as? Int ?? 0
        // Vertical sync rate is 16.16 fixed point.
        let precise = v["PreciseSyncRate"] as? Int ?? 0
        let rate = precise != 0 ? precise : (v["SyncRate"] as? Int ?? 0)
        refreshHz = Double(rate) / 65536.0
        score = d["Score"] as? Int ?? 0
        isVirtual = d["IsVirtual"] as? Bool ?? false
        isPreferred = d["IsPreferred"] as? Bool ?? false
        isInterlaced = d["IsInterlaced"] as? Bool ?? false
        colorModes = (d["ColorModes"] as? [[String: Any]] ?? []).compactMap(ColorElement.init)
        unsafeColorIDs = Set(d["UnsafeColorElementIDs"] as? [Int] ?? [])
    }

    /// Colour modes the display can really be switched to on this timing.
    var usableColorModes: [ColorElement] {
        colorModes.filter { !$0.isVirtual && !unsafeColorIDs.contains($0.id) }
    }

    var summary: String {
        "\(width)x\(height)\(isInterlaced ? "i" : "") @ \(String(format: "%.2f", refreshHz)) Hz"
    }

    var json: [String: Any] {
        [
            "id": id, "width": width, "height": height,
            "refreshHz": (refreshHz * 100).rounded() / 100,
            "score": score, "preferred": isPreferred, "virtual": isVirtual, "interlaced": isInterlaced,
            "summary": summary,
        ]
    }
}

struct DisplayInfo {
    let registryID: UInt64
    let port: String
    let edidUUID: String
    let productName: String?
    let vendor: String?
    let productID: Int?
    let serialNumber: Int?
    let alphanumericSerial: String?
    let colors: [Int: ColorElement]
    let timings: [TimingElement]

    var name: String { productName ?? "Unknown display" }

    var identity: String {
        var parts: [String] = []
        if let vendor { parts.append(vendor) }
        if let productID { parts.append("product \(productID)") }
        if let s = alphanumericSerial, !s.isEmpty { parts.append("serial \(s)") }
        else if let s = serialNumber, s != 0 { parts.append("serial \(s)") }
        parts.append("port \(port)")
        return parts.joined(separator: ", ")
    }

    func timing(_ id: Int) -> TimingElement? { timings.first { $0.id == id } }

    /// Colour element description, preferring the copy listed under the given timing.
    func color(_ id: Int, timing: Int? = nil) -> ColorElement? {
        if let timing, let t = self.timing(timing), let c = t.colorModes.first(where: { $0.id == id }) { return c }
        return colors[id]
    }

    func describe(_ mode: ModeIDs) -> String {
        let t = timing(mode.timing)?.summary ?? "timing \(mode.timing)"
        let c = color(mode.color, timing: mode.timing)?.summary ?? "color \(mode.color)"
        return "\(t) · \(c) [color \(mode.color), timing \(mode.timing)]"
    }
}
