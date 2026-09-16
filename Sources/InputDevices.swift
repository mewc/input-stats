import Foundation
import CoreGraphics
import IOKit
import IOKit.hid

/// Attributes CGEvents from the tap to the physical device that produced them.
///
/// CoreGraphics doesn't publicly expose the source HID device, but every hardware CGEvent wraps an
/// IOHIDEvent whose "sender ID" is the IORegistry entry of the HID event service that emitted it.
/// `CGEventCopyIOHIDEvent` + `IOHIDEventGetSenderID` are private (stable since 10.6, used by
/// Karabiner/BTT-class tools); both are resolved with dlsym so a missing symbol degrades to
/// "unattributed" instead of failing to link. Device properties (product, vendor, transport,
/// built-in) are read once per sender by walking the registry entry's parents, then cached.
final class InputDeviceResolver {
    static let shared = InputDeviceResolver()

    private typealias CopyIOHIDEventFn = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderIDFn = @convention(c) (CFTypeRef) -> UInt64

    private let copyIOHIDEvent: CopyIOHIDEventFn?
    private let senderID: SenderIDFn?

    private struct CacheKey: Hashable {
        let sender: UInt64
        let role: InputDevice.Role
    }
    // Touched only from the main thread: the event tap callback runs on the main run loop, and
    // every resolver completion hops back to main before mutating these.
    private var cache: [CacheKey: Int] = [:]
    private var pending: Set<CacheKey> = []
    private var softwareIDs: [InputDevice.Role: Int] = [:]

    /// False when the private symbols are missing; every event then lands on the unattributed device.
    var isAvailable: Bool { copyIOHIDEvent != nil && senderID != nil }

    private init() {
        let handle = dlopen(nil, RTLD_NOW)
        if let sym = dlsym(handle, "CGEventCopyIOHIDEvent") {
            copyIOHIDEvent = unsafeBitCast(sym, to: CopyIOHIDEventFn.self)
        } else {
            copyIOHIDEvent = nil
        }
        if let sym = dlsym(handle, "IOHIDEventGetSenderID") {
            senderID = unsafeBitCast(sym, to: SenderIDFn.self)
        } else {
            senderID = nil
        }
    }

    /// Hardware events carry source PID 0; anything posted by another process is synthetic.
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) != 0
    }

    /// The `devices` row id for the device behind `event`. Never blocks: a cache hit is a
    /// dictionary lookup, and a never-seen sender is resolved in the background (IORegistry plus
    /// a SQLite write) while this event — and any others arriving in that window — attribute to
    /// the unknown device. Input must never wait on the database.
    func deviceID(for event: CGEvent, role: InputDevice.Role) -> Int {
        if Self.isSynthetic(event) { return softwareDevice(role: role) }
        guard let copyIOHIDEvent, let senderID,
              let hidEvent = copyIOHIDEvent(event)?.takeRetainedValue() else {
            return InputDevice.unattributedID
        }
        let sender = senderID(hidEvent)
        guard sender != 0 else { return softwareDevice(role: role) }

        let key = CacheKey(sender: sender, role: role)
        if let cached = cache[key] { return cached }
        resolve(key)
        return InputDevice.unattributedID
    }

    /// Resolve a sender once, off the main thread, and cache the result.
    private func resolve(_ key: CacheKey) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = Self.describe(sender: key.sender, role: key.role)
            let id = EventStore.shared.deviceID(for: descriptor)
            DispatchQueue.main.async {
                self.cache[key] = id
                self.pending.remove(key)
            }
        }
    }

    private func softwareDevice(role: InputDevice.Role) -> Int {
        if let id = softwareIDs[role] { return id }
        DispatchQueue.global(qos: .utility).async {
            let id = EventStore.shared.deviceID(for: .software(role: role))
            DispatchQueue.main.async { self.softwareIDs[role] = id }
        }
        return InputDevice.unattributedID
    }

    /// Resolve a HID sender (IORegistry entry ID) to device properties. The sender is usually an
    /// event *service* (e.g. AppleUserHIDEventService) whose product/vendor live on a parent
    /// IOHIDDevice, so every property is searched upward through the service plane.
    static func describe(sender: UInt64, role: InputDevice.Role) -> InputDeviceDescriptor {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        guard service != 0 else { return .unknown(role: role) }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
        }
        func int(_ key: String) -> Int { (property(key) as? NSNumber)?.intValue ?? 0 }
        func string(_ key: String) -> String { property(key) as? String ?? "" }
        func bool(_ key: String) -> Bool {
            if let n = property(key) as? NSNumber { return n.boolValue }
            return false
        }

        return InputDeviceDescriptor(
            role: role,
            name: string(kIOHIDProductKey),
            vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey),
            transport: string(kIOHIDTransportKey),
            isBuiltIn: bool(kIOHIDBuiltInKey),
            isSoftware: false
        )
    }
}

// MARK: - Trackpad gestures

import Cocoa

/// NSEvent.EventType raw values for trackpad gestures. CGEventType has no cases for these, but the
/// session tap still delivers them when their bits are in the mask.
enum GestureEventType: UInt32, CaseIterable {
    case rotate = 18
    case magnify = 30
    case swipe = 31
    case smartMagnify = 32

    /// NSEvent.EventType.pressure — trackpad force, used to detect Force clicks.
    static let pressureEventType: UInt32 = 34

    var kind: EventKind {
        switch self {
        case .rotate: return .gestureRotate
        case .magnify: return .gesturePinch
        case .swipe: return .gestureSwipe
        case .smartMagnify: return .gestureSmartZoom
        }
    }

    /// Pinch/rotate stream many events per gesture; count those once, at the `.began` phase.
    /// Swipe and smart-zoom are already one event per gesture.
    func countsAsGesture(_ event: CGEvent) -> Bool {
        switch self {
        case .swipe, .smartMagnify:
            return true
        case .rotate, .magnify:
            guard let nsEvent = NSEvent(cgEvent: event) else { return false }
            return nsEvent.phase.contains(.began)
        }
    }
}

// MARK: - Screens

/// Maps a pointer event's location to the screen it happened on.
///
/// `NSScreen.screens` is only safe to read on the main thread and re-reading it per event would be
/// wasteful anyway, so frames and ids are cached and refreshed when the display configuration
/// changes. Lookup is then a handful of rect containment checks.
final class DisplayResolver {
    static let shared = DisplayResolver()

    private struct Entry {
        let frame: CGRect
        let id: Int
    }
    private var entries: [Entry] = []

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// The `displays` row id for the screen containing `location`, or 0 when it matches none
    /// (a point can briefly fall outside every frame while displays are being rearranged).
    func displayID(at location: CGPoint) -> Int {
        for entry in entries where entry.frame.contains(location) { return entry.id }
        return DisplayTarget.unknownID
    }

    /// Re-read the screen list and ensure each has a `displays` row.
    ///
    /// `NSScreen` must be read on the main thread, but resolving each screen's row id touches
    /// SQLite — which at launch means waiting behind the schema migration. Read the screens here
    /// and do the lookups in the background, so nothing on the main thread waits on the database.
    /// Until the ids land, pointer events attribute to the unknown screen rather than blocking.
    func refresh() {
        let described = NSScreen.screens.map { (frame: Self.eventFrame(of: $0), descriptor: Self.describe($0)) }
        DispatchQueue.global(qos: .utility).async {
            let resolved = described.map {
                Entry(frame: $0.frame, id: EventStore.shared.displayID(for: $0.descriptor))
            }
            DispatchQueue.main.async { self.entries = resolved }
        }
    }

    /// Screen frames are bottom-left origin in Cocoa, but CGEvent locations are top-left origin
    /// relative to the primary display — flip into event space once, at cache time.
    private static func eventFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        let f = screen.frame
        return CGRect(x: f.origin.x,
                      y: primary.frame.maxY - f.maxY,
                      width: f.width,
                      height: f.height)
    }

    private static func describe(_ screen: NSScreen) -> DisplayDescriptor {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
        // The display UUID survives unplug/replug and reboots; the CGDirectDisplayID does not.
        var key = ""
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            key = CFUUIDCreateString(nil, uuid) as String
        }
        let name = screen.localizedName
        if key.isEmpty { key = "\(name)|\(isBuiltIn ? 1 : 0)" }
        return DisplayDescriptor(key: key, name: name, isBuiltIn: isBuiltIn)
    }
}
