import XCTest
@testable import BridgeCore

final class AutomationTests: XCTestCase {
    private func configuration() throws -> Configuration {
        let dell = DisplayIdentity(uuid: "11111111-1111-4111-8111-111111111111", vendor: 0x10ac, product: 0xa272, serial: 123, name: "DELL S2725QC", location: "dell")
        let zowie = DisplayIdentity(uuid: "22222222-2222-4222-8222-222222222222", vendor: 0x09d1, product: 0x7f59, serial: 456, name: "ZOWIE XL LCD", location: "zowie")
        return try Configuration(dell: dell, zowie: zowie, ddc: DDCDevice(manufacturer: "DEL", name: dell.name, serial: "DellSerial", numericSerial: 123, edid: "DellEDID", location: "dell", upstream: "DP", downstream: "DP", serviceAvailable: true))
    }
    private func profile() throws -> CalibrationProfile {
        var profile = CalibrationProfile(config: try configuration())
        try profile.register(.usbC, value: 0x1b1b, verified: true)
        try profile.register(.hdmi, value: 0x1111, verified: true)
        return profile
    }
    func testCalibrationRejectsSameInputValueAndUnverifiedPoints() throws {
        var p = CalibrationProfile(config: try configuration())
        try p.register(.usbC, value: 0x1b1b, verified: true)
        XCTAssertFalse(p.ready)
        XCTAssertThrowsError(try p.register(.hdmi, value: 0x1b1b, verified: true))
        try p.register(.hdmi, value: 0x1111, verified: false)
        XCTAssertFalse(p.ready)
        try p.register(.hdmi, value: 0x1111, verified: true)
        XCTAssertTrue(p.ready)
        XCTAssertEqual(p.source(for: 0x1b1b), .usbC)
        XCTAssertNil(p.source(for: 0x001b))
    }
    func testRequiresThreeConsecutiveReadsAndResetsOnChange() throws {
        let p = try profile(); var monitor = InputConsensus()
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 0), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 2), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: 4), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: 6), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: 8), .input(.usbC))
    }
    func testFailedReadNeverMeansHDMIAndUnknownStopsOnlyAfterRepeatedReads() throws {
        let p = try profile(); var monitor = InputConsensus()
        XCTAssertEqual(monitor.ingest(value: nil, profile: p, at: 0), .wait)
        XCTAssertEqual(monitor.ingest(value: nil, profile: p, at: 2), .wait)
        XCTAssertEqual(monitor.ingest(value: nil, profile: p, at: 4), .unreadable)
        monitor.reset()
        XCTAssertEqual(monitor.ingest(value: 0xabcd, profile: p, at: 6), .wait)
        XCTAssertEqual(monitor.ingest(value: 0xabcd, profile: p, at: 8), .wait)
        XCTAssertEqual(monitor.ingest(value: 0xabcd, profile: p, at: 10), .unknown(0xabcd))
    }
    func testSleepGapAndManualResetDiscardEarlierSamples() throws {
        let p = try profile(); var monitor = InputConsensus()
        _ = monitor.ingest(value: 0x1111, profile: p, at: 0)
        _ = monitor.ingest(value: 0x1111, profile: p, at: 2)
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 50), .wait)
        monitor.reset(until: 60)
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 52), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 54), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 56), .wait)
        XCTAssertEqual(monitor.ingest(value: 0x1111, profile: p, at: 60), .input(.hdmi))
    }
    func testMinimumSwitchInterval() throws {
        let p = try profile(); var monitor = InputConsensus()
        monitor.didSwitch(at: 10)
        for time in [12.0, 14, 16, 18, 20, 22, 24] { XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: time), .wait) }
        XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: 26), .input(.usbC))
    }
    func testMissingHDMICalibrationDisablesDecisions() throws {
        var p = CalibrationProfile(config: try configuration())
        try p.register(.usbC, value: 0x1b1b, verified: true)
        var monitor = InputConsensus()
        for time in [0.0, 2, 4, 6, 8] { XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: time), .wait) }
    }
    func testLeaseDetectsDeadOwnerHangAndReboot() {
        let lease = SessionLease(token: "token", owner: 123, heartbeat: 100, bootSession: "boot")
        XCTAssertFalse(lease.expired(now: 110, bootSession: "boot", ownerAlive: true))
        XCTAssertTrue(lease.expired(now: 110, bootSession: "boot", ownerAlive: false))
        XCTAssertTrue(lease.expired(now: 140, bootSession: "boot", ownerAlive: true))
        XCTAssertTrue(lease.expired(now: 110, bootSession: "next-boot", ownerAlive: true))
        XCTAssertTrue(lease.expired(now: 90, bootSession: "boot", ownerAlive: true))
    }
    func testBusyReplyRequiresFreshConsecutiveValuesAndPersistentFailureAborts() {
        var sequence = ReadingStability()
        sequence.ingest(0x1b1b); sequence.ingest(nil); sequence.ingest(0x1b1b); sequence.ingest(0x1b1b)
        XCTAssertNil(sequence.stableValue)
        sequence.ingest(0x1b1b)
        XCTAssertEqual(sequence.stableValue, 0x1b1b)
        sequence.ingest(nil)
        XCTAssertNil(sequence.stableValue)
        sequence.ingest(nil); sequence.ingest(nil)
        XCTAssertTrue(sequence.failed)
        for _ in 0..<5 { sequence.ingest(0x1111) }
        XCTAssertNil(sequence.stableValue)
    }
    func testRepeatedSlowTimeoutsStillStopAutomation() throws {
        let p = try profile(); var monitor = InputConsensus()
        XCTAssertEqual(monitor.ingest(value: nil, profile: p, at: 0), .wait)
        XCTAssertEqual(monitor.ingest(value: nil, profile: p, at: 9), .wait)
        XCTAssertEqual(monitor.ingest(value: nil, profile: p, at: 18), .unreadable)
    }
    func testRecheckingAnInputInvalidatesPreviousVerificationUntilSuccess() throws {
        var p = try profile()
        XCTAssertTrue(p.ready)
        p.invalidate(.usbC)
        XCTAssertFalse(p.ready)
        XCTAssertEqual(p.usbC?.value, 0x1b1b)
        XCTAssertEqual(p.usbC?.verified, false)
        try p.register(.usbC, value: 0x1b1b, verified: true)
        XCTAssertTrue(p.ready)
    }
    func testMeasuredDellHDMIValueAndUSBCShareHighByteButRemainDistinct() throws {
        var p = CalibrationProfile(config: try configuration())
        try p.register(.usbC, value: 0x1b1b, verified: true)
        try p.register(.hdmi, value: 0x1b11, verified: true)
        XCTAssertTrue(p.ready)
        var monitor = InputConsensus()
        _ = monitor.ingest(value: 0x1b11, profile: p, at: 0)
        _ = monitor.ingest(value: 0x1b11, profile: p, at: 2)
        XCTAssertEqual(monitor.ingest(value: 0x1b11, profile: p, at: 4), .input(.hdmi))
        monitor.reset()
        _ = monitor.ingest(value: 0x1b1b, profile: p, at: 6)
        _ = monitor.ingest(value: 0x1b1b, profile: p, at: 8)
        XCTAssertEqual(monitor.ingest(value: 0x1b1b, profile: p, at: 10), .input(.usbC))
    }
}
