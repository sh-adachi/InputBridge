import Foundation
import CoreGraphics
import ColorSync
import DisplayBridge

public struct DisplayIdentity: Codable, Equatable {
    public let uuid: String
    public let vendor: UInt32
    public let product: UInt32
    public let serial: UInt32
    public let name: String
    public let location: String

    public func matches(_ other: DisplayIdentity) -> Bool {
        uuid == other.uuid && vendor == other.vendor && product == other.product && serial == other.serial && name == other.name
    }
}

public struct Mode: Codable, Equatable {
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let flags: UInt32

    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID; width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate; flags = mode.ioFlags
    }
    public func equivalent(to other: Mode) -> Bool {
        // The OS may move the default-mode bit (0x4) when another screen is disabled.
        width == other.width && height == other.height && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight && abs(refreshRate - other.refreshRate) < 0.1 && (flags & ~UInt32(4)) == (other.flags & ~UInt32(4))
    }
}

public struct DisplayState: Codable, Equatable {
    public let id: UInt32
    public let identity: DisplayIdentity
    public let active: Bool
    public let online: Bool
    public let builtin: Bool
    public let main: Bool
    public let mirrorOf: UInt32
    public let inMirrorSet: Bool
    public let x: Int32
    public let y: Int32
    public let rotation: Double
    public let mode: Mode?
    public var enabled: Bool { active || inMirrorSet }
}

public enum Displays {
    public static var enableAvailable: Bool { IBEnableAvailable() }
    public static func list() throws -> [DisplayState] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count), "List displays")
        return ids.prefix(Int(count)).map(state)
    }

    public static func state(_ id: CGDirectDisplayID) -> DisplayState {
        let info = IBCopyDisplayInfo(id) as? [String: Any] ?? [:]
        let names = info["DisplayProductName"] as? [String: String] ?? [:]
        let name = names["en_US"] ?? names.values.sorted().first ?? "Unknown"
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        let identity = DisplayIdentity(uuid: uuid, vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), name: name, location: info["IODisplayLocation"] as? String ?? "")
        let bounds = CGDisplayBounds(id)
        return DisplayState(id: id, identity: identity, active: CGDisplayIsActive(id) != 0, online: CGDisplayIsOnline(id) != 0, builtin: CGDisplayIsBuiltin(id) != 0, main: CGDisplayIsMain(id) != 0, mirrorOf: CGDisplayMirrorsDisplay(id), inMirrorSet: CGDisplayIsInMirrorSet(id) != 0, x: Int32(bounds.origin.x), y: Int32(bounds.origin.y), rotation: CGDisplayRotation(id), mode: CGDisplayCopyDisplayMode(id).map(Mode.init))
    }

    public static func resolve(_ identity: DisplayIdentity) throws -> DisplayState {
        let found = try list().filter { identity.matches($0.identity) }
        if found.count == 1 { return found[0] }
        // A disabled screen may disappear from the online list. Never fall back by index/name.
        guard let uuid = CFUUIDCreateFromString(nil, identity.uuid as CFString) else { throw BridgeError("Invalid UUID") }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        guard id != 0 else { throw BridgeError("Display absent: \(identity.name). Reconnect Dell USB-C if necessary.") }
        let current = state(id)
        guard identity.matches(current.identity) else { throw BridgeError("Display identity changed; re-run configure") }
        return current
    }

    public static func check(_ result: CGError, _ operation: String) throws {
        guard result == .success else { throw BridgeError("\(operation): CGError \(result.rawValue)") }
    }

    static func transaction(_ work: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "Begin display transaction")
        guard let config else { throw BridgeError("Missing display transaction") }
        do { try work(config) } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        // Session-only changes. Never write a permanent display configuration.
        try check(CGCompleteDisplayConfiguration(config, .forSession), "Commit display transaction")
    }

    public static func setDellEnabled(_ enabled: Bool, config: Configuration) throws {
        try config.validate()
        let dell = try resolve(config.dell)
        let zowie = try resolve(config.zowie)
        try Safety.preflight(dell: dell, zowie: zowie)
        try transaction { ref in try check(IBConfigureEnabled(ref, dell.id, enabled), "Dell enabled=\(enabled)") }
    }

    public static func mirrorDell(config: Configuration) throws {
        try config.validate()
        let dell = try resolve(config.dell)
        let zowie = try resolve(config.zowie)
        try Safety.preflight(dell: dell, zowie: zowie)
        guard dell.enabled else { throw BridgeError("Enable Dell before testing mirroring") }
        try transaction { ref in try check(CGConfigureDisplayMirrorOfDisplay(ref, dell.id, zowie.id), "Mirror Dell to ZOWIE") }
    }

    public static func restore(_ snapshot: Recovery) throws {
        try snapshot.configuration.validate()
        let zowie = try resolve(snapshot.configuration.zowie)
        try restoreProtected(snapshot)
        let dell: DisplayState
        do { dell = try resolve(snapshot.configuration.dell) }
        catch {
            // Same-session recovery may need the just-disabled contextual ID: Quartz removes
            // it from its UUID map. This path ONLY enables, never disables any display.
            // Refuse an ID that is now online or belongs to the protected screen.
            let previousID = snapshot.dell.id
            guard let boot = snapshot.bootSession, !boot.isEmpty, boot == BootSession.id,
                  previousID != zowie.id, !(try list()).contains(where: { $0.id == previousID }) else { throw error }
            try transaction { ref in try check(IBConfigureEnabled(ref, previousID, true), "Re-enable saved Dell ID") }
            Thread.sleep(forTimeInterval: 2)
            dell = try resolve(snapshot.configuration.dell)
        }
        // Recovery is allowed even if macOS unexpectedly changed ZOWIE. Only enable Dell.
        guard dell.id != zowie.id else { throw BridgeError("Recovery identities collide") }
        if !dell.enabled {
            try transaction { ref in try check(IBConfigureEnabled(ref, dell.id, true), "Re-enable Dell") }
            Thread.sleep(forTimeInterval: 1)
        }
        let target = try resolve(snapshot.configuration.dell)
        let modes = CGDisplayCopyAllDisplayModes(target.id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
        guard let saved = snapshot.dell.mode,
              let mode = modes.first(where: { Mode($0).equivalent(to: saved) && $0.ioDisplayModeID == saved.id }) ?? modes.first(where: { Mode($0).equivalent(to: saved) }) else {
            throw BridgeError("Dell enabled, but saved display mode unavailable. Use System Settings > Displays.")
        }
        try transaction { ref in
            try check(CGConfigureDisplayMirrorOfDisplay(ref, target.id, kCGNullDirectDisplay), "Unmirror Dell")
            try check(CGConfigureDisplayWithDisplayMode(ref, target.id, mode, nil), "Restore Dell mode")
            try check(CGConfigureDisplayOrigin(ref, target.id, snapshot.dell.x, snapshot.dell.y), "Restore Dell position")
            // A mirror set may cause the OS to change the source's timing. Restore the saved
            // source mode if necessary, but never call enabled=false for this protected display.
            if let savedZowie = snapshot.zowie.mode, zowie.mode?.equivalent(to: savedZowie) != true {
                let sourceModes = CGDisplayCopyAllDisplayModes(zowie.id, nil) as? [CGDisplayMode] ?? []
                if let sourceMode = sourceModes.first(where: { Mode($0).equivalent(to: savedZowie) }) {
                    try check(CGConfigureDisplayWithDisplayMode(ref, zowie.id, sourceMode, nil), "Restore protected display timing")
                }
            }
        }
        try restoreProtected(snapshot)
    }

    public static func restoreProtected(_ snapshot: Recovery) throws {
        try snapshot.configuration.validate()
        let zowie = try resolve(snapshot.configuration.zowie)
        guard let saved = snapshot.zowie.mode else { throw BridgeError("Missing protected display mode") }
        if zowie.mode?.equivalent(to: saved) == true { return }
        let modes = CGDisplayCopyAllDisplayModes(zowie.id, nil) as? [CGDisplayMode] ?? []
        guard let mode = modes.first(where: { Mode($0).equivalent(to: saved) }) else { throw BridgeError("Saved ZOWIE timing unavailable") }
        try transaction { ref in
            try check(CGConfigureDisplayWithDisplayMode(ref, zowie.id, mode, nil), "Restore protected ZOWIE timing")
        }
    }
}
