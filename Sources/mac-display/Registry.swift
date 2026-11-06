import Foundation
import IOKit

/// One IOMobileFramebufferShim service (a display pipe: built-in, dispext0, dispext1…).
/// The service object persists while displays come and go on that pipe.
final class FramebufferService {
    let service: io_service_t
    let registryID: UInt64
    let port: String

    /// Takes ownership of `service` (one reference).
    init(service: io_service_t) {
        self.service = service
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        registryID = id
        port = Registry.parentName(of: service) ?? String(format: "fb-%llx", id)
    }

    deinit { IOObjectRelease(service) }

    /// Present only while a display is attached to this pipe.
    var edidUUID: String? { Registry.property(service, "EDID UUID") as? String }
}

enum Registry {
    static let framebufferClass = "IOMobileFramebufferShim"

    static func framebuffers() -> [FramebufferService] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(framebufferClass), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [FramebufferService] = []
        while true {
            let s = IOIteratorNext(iterator)
            if s == 0 { break }
            result.append(FramebufferService(service: s))
        }
        return result.sorted { $0.port < $1.port }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func parentName(of entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &buf) == KERN_SUCCESS else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }

    /// Full description of the display attached to `fb`, or nil if none is attached.
    static func readDisplay(_ fb: FramebufferService) -> DisplayInfo? {
        guard let edid = fb.edidUUID,
              let attrs = property(fb.service, "DisplayAttributes") as? [String: Any]
        else { return nil }
        let product = attrs["ProductAttributes"] as? [String: Any] ?? [:]
        let colorList = (property(fb.service, "ColorElements") as? [[String: Any]] ?? []).compactMap(ColorElement.init)
        let timings = (property(fb.service, "TimingElements") as? [[String: Any]] ?? []).compactMap(TimingElement.init)
        var colors: [Int: ColorElement] = [:]
        for c in colorList { colors[c.id] = c }
        return DisplayInfo(
            registryID: fb.registryID,
            port: fb.port,
            edidUUID: edid,
            productName: (product["ProductName"] as? String)?.trimmingCharacters(in: .whitespaces),
            vendor: product["ManufacturerID"] as? String,
            productID: product["ProductID"] as? Int,
            serialNumber: product["SerialNumber"] as? Int,
            alphanumericSerial: (product["AlphanumericSerialNumber"] as? String)?.trimmingCharacters(in: .whitespaces),
            colors: colors,
            timings: timings
        )
    }
}

/// A display that is attached right now, with an open framebuffer connection.
struct AttachedDisplay {
    let service: FramebufferService
    let framebuffer: Framebuffer
    let info: DisplayInfo
    let mode: ModeIDs
}

/// Snapshot of every attached display that exposes switchable connection modes.
/// A display that can't be read is reported on stderr and skipped, so one bad pipe
/// doesn't hide the others.
func attachedDisplays(api: IOMFB) -> [AttachedDisplay] {
    var out: [AttachedDisplay] = []
    for fb in Registry.framebuffers() {
        guard let info = Registry.readDisplay(fb), !info.timings.isEmpty else { continue }
        do {
            let handle = try Framebuffer(service: fb.service, api: api)
            let mode = try handle.currentMode()
            out.append(AttachedDisplay(service: fb, framebuffer: handle, info: info, mode: mode))
        } catch {
            FileHandle.standardError.write("warning: \(info.name) [\(info.port)]: \(error)\n".data(using: .utf8)!)
        }
    }
    return out
}
