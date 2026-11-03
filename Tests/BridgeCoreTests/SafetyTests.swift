import XCTest
@testable import BridgeCore

final class SafetyTests: XCTestCase {
    func identity(dell: Bool) -> DisplayIdentity {
        DisplayIdentity(uuid: dell ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222", vendor: dell ? 0x10ac : 0x09d1, product: dell ? 0xa272 : 0x7f59, serial: dell ? 123 : 456, name: dell ? "DELL S2725QC" : "ZOWIE XL LCD", location: dell ? "dell" : "zowie")
    }
    func device() -> DDCDevice {
        DDCDevice(manufacturer: "DEL", name: "DELL S2725QC", serial: "DellSerial", numericSerial: 123, edid: "DellEDID", location: "dell", upstream: "DP", downstream: "DP", serviceAvailable: true)
    }
    func raw(_ value: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x6e, 0x88, 2, 0, 0x60, 0, 0x1b, 0x1b, UInt8(value >> 8), UInt8(value & 255), 0]
        bytes[10] = bytes.prefix(10).reduce(0x50, ^)
        return bytes
    }
    func testInvalidAndUnsupportedDDCRepliesRejected() {
        XCTAssertNotNil(VCPReading.validate(raw: [UInt8](repeating: 0, count: 11), transportOK: true))
        XCTAssertNotNil(VCPReading.validate(raw: [], transportOK: false))
        var raw: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x60, 0, 0, 0x1b, 0, 0x1b, 0]
        raw[10] = raw.prefix(10).reduce(0x50, ^)
        XCTAssertNil(VCPReading.validate(raw: raw, transportOK: true))
        raw[3] = 1
        raw[10] = raw.prefix(10).reduce(0x50, ^)
        XCTAssertNotNil(VCPReading.validate(raw: raw, transportOK: true))
    }

    func testChecksumAndI2CFailureCannotBecomeInputValues() {
        let good = raw(0x1b1b)
        XCTAssertEqual(VCPReading(device: device(), raw: good, transportOK: true).current, 0x1b1b)
        var bad = good; bad[10] ^= 1
        XCTAssertNil(VCPReading(device: device(), raw: bad, transportOK: true).current)
        XCTAssertNil(VCPReading(device: device(), raw: good, transportOK: false).current)
    }

    func testZowieCannotBeConfiguredAsTarget() throws {
        XCTAssertNoThrow(try Configuration(dell: identity(dell: true), zowie: identity(dell: false), ddc: device()))
        XCTAssertThrowsError(try Configuration(dell: identity(dell: false), zowie: identity(dell: true), ddc: device()))
        XCTAssertThrowsError(try Configuration(dell: identity(dell: true), zowie: identity(dell: true), ddc: device()))
        var wrong = device(); wrong.numericSerial = 0
        XCTAssertThrowsError(try Configuration(dell: identity(dell: true), zowie: identity(dell: false), ddc: wrong))
    }

    func testProtectedDisplayMustBeActiveIndependentAndMain() throws {
        func display(_ dell: Bool, active: Bool = true, main: Bool = false, mirror: UInt32 = 0) -> DisplayState {
            DisplayState(id: dell ? 1 : 3, identity: identity(dell: dell), active: active, online: true, builtin: false, main: main, mirrorOf: mirror, inMirrorSet: mirror != 0, x: 0, y: 0, rotation: 0, mode: nil)
        }
        let dell = display(true)
        XCTAssertNoThrow(try Safety.preflight(dell: dell, zowie: display(false, main: true)))
        XCTAssertThrowsError(try Safety.preflight(dell: dell, zowie: display(false, active: false, main: true)))
        XCTAssertThrowsError(try Safety.preflight(dell: dell, zowie: display(false)))
        XCTAssertThrowsError(try Safety.preflight(dell: dell, zowie: display(false, main: true, mirror: 1)))
        XCTAssertThrowsError(try Safety.preflight(dell: dell, zowie: dell))
    }

    func testCalibrationRequiresDistinctStableBatchesAndFailuresInvalidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(root: root, executable: URL(fileURLWithPath: "/unused"))
        func batch(_ label: String, _ values: [UInt16?]) throws {
            let run = UUID().uuidString
            for value in values {
                let reading = value.map { VCPReading(device: device(), raw: raw($0), transportOK: true) }
                try diagnostics.append(Observation(date: Date(), run: run, label: label, phase: "extended", reading: reading, error: value == nil ? "timeout" : nil), to: diagnostics.observationURL)
            }
        }
        try batch("usb-c", [0x1b1b, 0x1b1b, 0x1b1b])
        XCTAssertFalse(try diagnostics.evaluate().calibrated)
        try batch("hdmi", [0x1b1b, 0x1b1b, 0x1b1b])
        XCTAssertFalse(try diagnostics.evaluate().calibrated)
        try batch("hdmi", [0x1111, 0x1111, 0x1111])
        XCTAssertTrue(try diagnostics.evaluate().calibrated)
        XCTAssertFalse(try diagnostics.evaluate().disableCandidate)
        try batch("hdmi", [0x1111, nil, 0x1111])
        XCTAssertFalse(try diagnostics.evaluate().calibrated)
    }

    func testWorkspaceRejectsConcurrentOperations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try WorkspaceLock(root: root)
        try withExtendedLifetime(first) { XCTAssertThrowsError(try WorkspaceLock(root: root)) }
    }

    func testZowieProbeCannotSupplyDellHDMICalibration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(root: root, executable: URL(fileURLWithPath: "/unused"))
        let run = UUID().uuidString
        for _ in 0..<3 {
            let usb = VCPReading(device: device(), raw: raw(0x1b1b), transportOK: true)
            try diagnostics.append(Observation(date: Date(), run: run, label: "usb-c", phase: "extended", reading: usb, error: nil), to: diagnostics.observationURL)
            var zowie = device(); zowie.manufacturer = "BNQ"; zowie.name = "ZOWIE XL LCD"
            let hdmi = VCPReading(device: zowie, raw: raw(0x1111), transportOK: true)
            try diagnostics.append(Observation(date: Date(), run: run, label: "zowie-connection", phase: "probe-zowie", reading: hdmi, error: nil), to: diagnostics.zowieProbeURL)
        }
        let result = try diagnostics.evaluate()
        XCTAssertEqual(result.usbCValue, 0x1b1b)
        XCTAssertNil(result.hdmiValue)
        XCTAssertFalse(result.calibrated)
        XCTAssertFalse(result.disableCandidate)
    }

    func testHangingHelperHasDeadline() {
        XCTAssertThrowsError(try Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05))
    }
}
