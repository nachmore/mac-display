import Foundation
import IOKit

/// Thin loader for the private IOMobileFramebuffer.framework calls used to read and
/// switch a display's "digital out mode" (DCP colour element + timing element) on
/// Apple silicon. These talk straight to the display coprocessor driver through
/// IOKit, so they work without a WindowServer session: at the login window, on the
/// lock screen, and from a LaunchDaemon.
///
/// Signatures were confirmed by disassembly on macOS 26:
///   IOMobileFramebufferOpen(io_service_t, task_port_t, uint32_t type, IOMobileFramebufferRef *out)
///   IOMobileFramebufferGetDigitalOutMode(ref, uint32_t *colorID, uint32_t *timingID)
///   IOMobileFramebufferSetDigitalOutMode(ref, uint32_t colorID, uint32_t timingID)
struct IOMFB {
    typealias Ref = UnsafeMutableRawPointer
    typealias OpenFn = @convention(c) (io_service_t, mach_port_t, UInt32, UnsafeMutablePointer<Ref?>) -> kern_return_t
    typealias GetModeFn = @convention(c) (Ref, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> kern_return_t
    typealias SetModeFn = @convention(c) (Ref, UInt32, UInt32) -> kern_return_t

    let open: OpenFn
    let getDigitalOutMode: GetModeFn
    let setDigitalOutMode: SetModeFn

    static let frameworkPath = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

    static let shared: Result<IOMFB, MacDisplayError> = load()

    private static func load() -> Result<IOMFB, MacDisplayError> {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            return .failure(.privateAPI("cannot load IOMobileFramebuffer.framework (Apple silicon only): \(reason)"))
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let open = symbol("IOMobileFramebufferOpen", as: OpenFn.self),
              let get = symbol("IOMobileFramebufferGetDigitalOutMode", as: GetModeFn.self),
              let set = symbol("IOMobileFramebufferSetDigitalOutMode", as: SetModeFn.self)
        else {
            return .failure(.privateAPI("IOMobileFramebuffer digital-out API not found on this macOS version"))
        }
        return .success(IOMFB(open: open, getDigitalOutMode: get, setDigitalOutMode: set))
    }
}

struct ModeIDs: Equatable, CustomStringConvertible {
    var color: Int
    var timing: Int
    var description: String { "color \(color) / timing \(timing)" }
}

/// An open IOMobileFramebuffer connection (a CF object; released on deinit).
final class Framebuffer {
    private let ref: IOMFB.Ref
    private let api: IOMFB
    /// The IOMFB object stores the service port name without retaining it, so hold our
    /// own reference for as long as the connection lives.
    private let service: io_service_t

    init(service: io_service_t, api: IOMFB) throws {
        IOObjectRetain(service)
        var out: IOMFB.Ref?
        let kr = api.open(service, mach_task_self_, 0, &out)
        guard kr == KERN_SUCCESS, let out else {
            IOObjectRelease(service)
            throw MacDisplayError.ioKit("IOMobileFramebufferOpen", kr)
        }
        self.ref = out
        self.api = api
        self.service = service
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
        IOObjectRelease(service)
    }

    func currentMode() throws -> ModeIDs {
        var color: UInt32 = 0
        var timing: UInt32 = 0
        let kr = api.getDigitalOutMode(ref, &color, &timing)
        guard kr == KERN_SUCCESS else { throw MacDisplayError.ioKit("IOMobileFramebufferGetDigitalOutMode", kr) }
        return ModeIDs(color: Int(color), timing: Int(timing))
    }

    func setMode(_ mode: ModeIDs) throws {
        guard let c = UInt32(exactly: mode.color), let t = UInt32(exactly: mode.timing) else {
            throw MacDisplayError.failed("invalid mode IDs \(mode)")
        }
        let kr = api.setDigitalOutMode(ref, c, t)
        guard kr == KERN_SUCCESS else { throw MacDisplayError.ioKit("IOMobileFramebufferSetDigitalOutMode", kr) }
    }
}
