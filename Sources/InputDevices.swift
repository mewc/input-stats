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
    private var cache: [CacheKey: Int] = [:]
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

    /// The `devices` row id for the device behind `event`. Cheap on the hot path: one private
    /// call pair plus a dictionary hit; only a never-seen sender touches IORegistry and SQLite.
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
        let descriptor = Self.describe(sender: sender, role: role)
        let id = EventStore.shared.deviceID(for: descriptor)
        cache[key] = id
        return id
    }

    private func softwareDevice(role: InputDevice.Role) -> Int {
        if let id = softwareIDs[role] { return id }
        let id = EventStore.shared.deviceID(for: .software(role: role))
        softwareIDs[role] = id
        return id
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
