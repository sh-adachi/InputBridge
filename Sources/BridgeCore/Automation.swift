import Foundation

public enum InputSource: String, Codable, CaseIterable {
    case usbC = "usb-c", hdmi
    public var title: String { self == .usbC ? "USB-C" : "HDMI" }
}

public enum HideStrategy: String, Codable, CaseIterable {
    case disable, mirror
    public var title: String { self == .disable ? "Dellを無効化" : "ZOWIEをDellに複製" }
}

public enum WorkspaceMode: String, Codable {
    case dual, single, mirrored, unavailable
    public var title: String {
        switch self {
        case .dual: return "デュアルディスプレイ"
        case .single: return "ZOWIEのみ"
        case .mirrored: return "ZOWIEのみ（複製）"
        case .unavailable: return "接続を確認してください"
        }
    }
}

public struct CalibrationPoint: Codable, Equatable {
    public let value: UInt16
    public let verified: Bool
    public let date: Date
    public init(value: UInt16, verified: Bool, date: Date = Date()) {
        self.value = value; self.verified = verified; self.date = date
    }
}

public struct CalibrationProfile: Codable {
    public let schema: Int
    public let dellUUID: String
    public let zowieUUID: String
    public let dellSerial: String
    public let edid: String
    public let osVersion: String?
    public var strategy: HideStrategy
    public var usbC: CalibrationPoint?
    public var hdmi: CalibrationPoint?

    public init(config: Configuration, strategy: HideStrategy = .disable) {
        schema = 1; dellUUID = config.dell.uuid; zowieUUID = config.zowie.uuid
        dellSerial = config.ddc.serial; edid = config.ddc.edid; self.strategy = strategy
        osVersion = Self.currentOSVersion
    }
    public static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    public func matches(_ config: Configuration) -> Bool {
        schema == 1 && osVersion == Self.currentOSVersion && dellUUID == config.dell.uuid && zowieUUID == config.zowie.uuid && dellSerial == config.ddc.serial && edid == config.ddc.edid
    }
    public var ready: Bool {
        guard schema == 1, let usbC, let hdmi else { return false }
        return usbC.verified && hdmi.verified && usbC.value != hdmi.value
    }
    public func source(for value: UInt16) -> InputSource? {
        if usbC?.value == value { return .usbC }
        if hdmi?.value == value { return .hdmi }
        return nil
    }
    public mutating func register(_ source: InputSource, value: UInt16, verified: Bool) throws {
        let other = source == .usbC ? hdmi : usbC
        guard other?.value != value else { throw BridgeError("USB-CとHDMIで同じ値が返りました。本体の入力を確認して再登録してください。") }
        let point = CalibrationPoint(value: value, verified: verified)
        if source == .usbC { usbC = point } else { hdmi = point }
    }
    public mutating func invalidate(_ source: InputSource) {
        if source == .usbC, let point = usbC { usbC = CalibrationPoint(value: point.value, verified: false, date: point.date) }
        if source == .hdmi, let point = hdmi { hdmi = CalibrationPoint(value: point.value, verified: false, date: point.date) }
    }
}

public enum ConsensusDecision: Equatable {
    case wait, input(InputSource), unreadable, unknown(UInt16)
}

/// A null/busy DDC reply clears the valid streak; three failed reads abort the
/// measurement. Calibration needs three consecutive identical, validated values.
public struct ReadingStability {
    private var value: UInt16?
    private var count = 0
    private var failures = 0
    public private(set) var failed = false
    public init() {}
    public var stableValue: UInt16? { !failed && count >= 3 ? value : nil }
    public mutating func ingest(_ next: UInt16?) {
        guard !failed else { return }
        guard let next else {
            value = nil; count = 0; failures += 1
            if failures >= 3 { failed = true }
            return
        }
        failures = 0
        if next == value { count += 1 } else { value = next; count = 1 }
    }
}

/// Pure decision logic: never infers HDMI from a failed read, and never retains
/// samples across long pauses, source changes, manual overrides, or sleep.
public struct InputConsensus {
    private var lastValue: UInt16?
    private var consecutive = 0
    private var failures = 0
    private var lastSample: TimeInterval?
    private var earliestAction: TimeInterval = 0
    public init() {}
    public mutating func reset(until: TimeInterval = 0) {
        lastValue = nil; consecutive = 0; failures = 0; lastSample = nil; earliestAction = until
    }
    public mutating func didSwitch(at time: TimeInterval) { reset(until: time + 15) }
    public mutating func ingest(value: UInt16?, profile: CalibrationProfile, at time: TimeInterval) -> ConsensusDecision {
        guard profile.ready else { reset(); return .wait }
        if let previous = lastSample, time - previous > 8 || time < previous {
            // A slow helper timeout plus the poll interval can itself exceed 8s.
            // Keep failed-read counts so repeated timeouts still stop automation.
            lastValue = nil; consecutive = 0
        }
        lastSample = time
        guard let value else {
            lastValue = nil; consecutive = 0; failures += 1
            return failures >= 3 ? .unreadable : .wait
        }
        failures = 0
        if lastValue == value { consecutive += 1 } else { lastValue = value; consecutive = 1 }
        guard consecutive >= 3, time >= earliestAction else { return .wait }
        guard let source = profile.source(for: value) else { return .unknown(value) }
        return .input(source)
    }
}
