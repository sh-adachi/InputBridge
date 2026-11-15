import XCTest
@testable import BridgeCore

final class MainDisplayTests: XCTestCase {
    func testAvailabilityRequiresKnownMacInputAndPowerOn() {
        XCTAssertEqual(MonitorAvailability.classify(online: true, input: 0x1b1b, macInput: 0x1b1b, power: 1), .available)
        XCTAssertEqual(MonitorAvailability.classify(online: true, input: 0x1b11, macInput: 0x1b1b, power: 1), .otherInput)
        XCTAssertEqual(MonitorAvailability.classify(online: true, input: 0x1b1b, macInput: 0x1b1b, power: 4), .poweredOff)
        XCTAssertEqual(MonitorAvailability.classify(online: false, input: 0x1b1b, macInput: 0x1b1b, power: 1), .disconnected)
        XCTAssertEqual(MonitorAvailability.classify(online: true, input: nil, macInput: 0x1b1b, power: 1), .unknown)
        XCTAssertEqual(MonitorAvailability.classify(online: true, input: 0x1b1b, macInput: 0x1b1b, power: nil), .unknown)
        XCTAssertEqual(MonitorAvailability.classify(online: true, input: 0x11, macInput: nil, power: 1), .unknown)
        XCTAssertEqual(MainAvailability(dell: .available, zowie: .available).preferred, .dell)
        XCTAssertEqual(MainAvailability(dell: .unknown, zowie: .available).preferred, .zowie)
        XCTAssertNil(MainAvailability(dell: .unknown, zowie: .otherInput).preferred)
    }

    func testMainConsensusRequiresFreshAgreementAndNeverSelectsUnknownDestination() {
        var consensus = MainDisplayConsensus()
        XCTAssertNil(consensus.ingest(.dell, at: 0))
        XCTAssertNil(consensus.ingest(.dell, at: 5))
        XCTAssertNil(consensus.ingest(nil, at: 10))
        XCTAssertNil(consensus.ingest(.zowie, at: 15))
        XCTAssertNil(consensus.ingest(.zowie, at: 20))
        XCTAssertEqual(consensus.ingest(.zowie, at: 25), .zowie)
        consensus.reset()
        XCTAssertNil(consensus.ingest(.dell, at: 30))
        XCTAssertNil(consensus.ingest(.dell, at: 60), "Do not retain samples across a long pause")
    }

    func testPowerReplyMustMatchRequestedFeatureAndChecksum() {
        var power: [UInt8] = [0x6e, 0x88, 2, 0, 0xd6, 0, 0, 5, 0, 1, 0]
        power[10] = power.prefix(10).reduce(0x50, ^)
        XCTAssertNil(VCPReading.validate(raw: power, transportOK: true, feature: 0xd6))
        XCTAssertNotNil(VCPReading.validate(raw: power, transportOK: true), "A power reply is not an input reply")
        power[10] ^= 1
        XCTAssertNotNil(VCPReading.validate(raw: power, transportOK: true, feature: 0xd6))
    }

    private func display(dell: Bool, x: Int32, y: Int32 = 0, main: Bool, active: Bool = true,
                         mirror: UInt32 = 0, hz: Double = 240) -> DisplayState {
        let identity = DisplayIdentity(uuid: dell ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222",
                                       vendor: dell ? 0x10ac : 0x09d1, product: dell ? 0xa272 : 0x7f59, serial: dell ? 123 : 456,
                                       name: dell ? "DELL S2725QC" : "ZOWIE XL LCD", location: dell ? "dell" : "zowie")
        let mode = try! JSONDecoder().decode(Mode.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1, "width": 1920, "height": 1080, "pixelWidth": dell ? 3840 : 1920,
            "pixelHeight": dell ? 2160 : 1080, "refreshRate": hz, "flags": 0
        ]))
        return DisplayState(id: dell ? 1 : 3, identity: identity, active: active, online: true, builtin: false, main: main,
                            mirrorOf: mirror, inMirrorSet: mirror != 0, x: x, y: y, rotation: 0, mode: mode)
    }

    func testDellMainPreservesRelativeLogicalLayoutWithVerticalOffset() throws {
        let dell = display(dell: true, x: -1920, y: -200, main: false, hz: 120)
        let zowie = display(dell: false, x: 0, main: true)
        let layout = try Displays.mainDisplayLayout(.dell, dell: dell, zowie: zowie)
        XCTAssertEqual(layout, [DisplayPlacement(id: 3, x: 1920, y: 200), DisplayPlacement(id: 1, x: 0, y: 0)])
    }

    func testZowieMainRestoresRelativeLogicalLayout() throws {
        let dell = display(dell: true, x: 0, main: true, hz: 120)
        let zowie = display(dell: false, x: 1920, y: 200, main: false)
        let layout = try Displays.mainDisplayLayout(.zowie, dell: dell, zowie: zowie)
        XCTAssertEqual(layout, [DisplayPlacement(id: 1, x: -1920, y: -200), DisplayPlacement(id: 3, x: 0, y: 0)])
    }

    func testHiddenMirroredOrAmbiguousDisplaysCannotChangeMain() {
        let zowie = display(dell: false, x: 0, main: true)
        XCTAssertThrowsError(try Displays.mainDisplayLayout(.dell, dell: display(dell: true, x: -1920, main: false, active: false), zowie: zowie))
        XCTAssertThrowsError(try Displays.mainDisplayLayout(.dell, dell: display(dell: true, x: -1920, main: false, mirror: 3), zowie: zowie))
        XCTAssertThrowsError(try Displays.mainDisplayLayout(.dell, dell: display(dell: true, x: -1920, main: true), zowie: zowie))
        XCTAssertThrowsError(try Displays.mainDisplayLayout(.dell, dell: display(dell: true, x: -1920, main: false), zowie: display(dell: false, x: 0, main: false)))
    }

    func testCoordinateOverflowIsRejectedBeforeAnyTransaction() {
        let dell = display(dell: true, x: Int32.min, main: false)
        let zowie = display(dell: false, x: Int32.max, main: true)
        XCTAssertThrowsError(try Displays.mainDisplayLayout(.dell, dell: dell, zowie: zowie))
    }

    func testDellMainIsAllowedForSnapshotButNotForHidingWithoutPromotion() throws {
        let dell = display(dell: true, x: 0, main: true)
        let zowie = display(dell: false, x: 1920, main: false)
        XCTAssertNoThrow(try Safety.preflight(dell: dell, zowie: zowie, requireZowieMain: false))
        XCTAssertThrowsError(try Safety.preflight(dell: dell, zowie: zowie))
    }

    func testIntentionalMainChangeStillRequiresZowieActiveAndAtSavedTiming() throws {
        let before = display(dell: false, x: 0, main: true)
        let after = display(dell: false, x: 1920, main: false)
        XCTAssertThrowsError(try Safety.checkProtected(before, after))
        XCTAssertNoThrow(try Safety.checkProtected(before, after, allowOriginChange: true))
        XCTAssertThrowsError(try Safety.checkProtected(before, display(dell: false, x: 1920, main: false, active: false), allowOriginChange: true))
        XCTAssertThrowsError(try Safety.checkProtected(before, display(dell: false, x: 1920, main: false, mirror: 1), allowOriginChange: true))
        XCTAssertThrowsError(try Safety.checkProtected(before, display(dell: false, x: 1920, main: false, hz: 120), allowOriginChange: true))
        XCTAssertNoThrow(try Safety.checkProtected(after, after), "Recovery must accept the saved ZOWIE secondary state")
    }
}
