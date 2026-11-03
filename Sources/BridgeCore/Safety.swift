import Foundation
import Darwin

public enum BootSession {
    public static var id: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}

public struct Configuration: Codable {
    public let schema: Int
    public let dell: DisplayIdentity
    public let zowie: DisplayIdentity
    public let ddc: DDCDevice
    public init(dell: DisplayIdentity, zowie: DisplayIdentity, ddc: DDCDevice) throws {
        schema = 1; self.dell = dell; self.zowie = zowie; self.ddc = ddc
        try validate()
    }
    public func validate() throws {
        guard schema == 1, dell.uuid != zowie.uuid,
              UUID(uuidString: dell.uuid) != nil, UUID(uuidString: zowie.uuid) != nil,
              dell.vendor == 0x10ac, dell.product == 0xa272, dell.name == "DELL S2725QC",
              zowie.vendor == 0x09d1, zowie.product == 0x7f59, zowie.name == "ZOWIE XL LCD",
              dell.serial != 0, zowie.serial != 0,
              ddc.manufacturer == "DEL", ddc.name == dell.name,
              ddc.numericSerial == Int64(dell.serial), !ddc.serial.isEmpty, !ddc.edid.isEmpty else {
            throw BridgeError("Untrusted/unsupported monitor identities. Only Dell S2725QC can be changed; ZOWIE XL LCD is protected.")
        }
    }
}

public enum Safety {
    public static func preflight(dell: DisplayState, zowie: DisplayState) throws {
        guard dell.id != zowie.id, !dell.builtin, !zowie.builtin,
              zowie.active, zowie.main, zowie.mirrorOf == 0, !zowie.inMirrorSet else {
            throw BridgeError("ZOWIE must be the active, independent main display. No changes applied.")
        }
    }
    public static func checkProtected(_ before: DisplayState, _ after: DisplayState) throws {
        guard before.identity.matches(after.identity), after.active, after.main, after.mirrorOf == 0,
              before.x == after.x, before.y == after.y, before.rotation == after.rotation,
              let old = before.mode, let new = after.mode, old.equivalent(to: new) else {
            throw BridgeError("Protected ZOWIE changed unexpectedly; restore required")
        }
    }
}

public struct Recovery: Codable {
    public let token: String
    public let created: Date
    public let bootSession: String?
    public let configuration: Configuration
    public let dell: DisplayState
    public let zowie: DisplayState
    public init(config: Configuration) throws {
        try config.validate()
        token = UUID().uuidString; created = Date(); configuration = config; bootSession = BootSession.id
        dell = try Displays.resolve(config.dell); zowie = try Displays.resolve(config.zowie)
        try Safety.preflight(dell: dell, zowie: zowie)
        guard dell.active, !dell.inMirrorSet, dell.rotation == 0, dell.mode != nil else {
            throw BridgeError("Start tests with Dell enabled, extended, and unrotated")
        }
    }
}
