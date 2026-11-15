import XCTest
@testable import BridgeCore
@testable import InputBridgeApp

private actor StubDisplayWorker: DisplayWorking {
    private var calibration: CalibrationProfile
    private var value: UInt16? = 0x1b1b
    private var mode: WorkspaceMode = .dual
    private var main: MainDisplay = .zowie
    private var dualMain: MainDisplay = .zowie
    private var dellPower: UInt16? = 1
    private var zowiePower: UInt16? = 1
    private var zowieInput: UInt16? = 0x11
    private var initializationFailures = 0
    private var restorationFailures = 0
    private var suspendNextRead = false
    private var pendingRead: CheckedContinuation<RuntimeStatus, Error>?
    private var readWaiter: CheckedContinuation<Void, Never>?
    private(set) var initializations = 0
    private(set) var restorations = 0
    private(set) var singleSwitches = 0
    private(set) var mainSwitches = 0

    init(ready: Bool = true) throws {
        let dell = DisplayIdentity(uuid: "11111111-1111-4111-8111-111111111111", vendor: 0x10ac, product: 0xa272, serial: 123, name: "DELL S2725QC", location: "dell")
        let zowie = DisplayIdentity(uuid: "22222222-2222-4222-8222-222222222222", vendor: 0x09d1, product: 0x7f59, serial: 456, name: "ZOWIE XL LCD", location: "zowie")
        let device = DDCDevice(manufacturer: "DEL", name: dell.name, serial: "TestSerial", numericSerial: 123, edid: "TestEDID", location: "dell", upstream: "DP", downstream: "DP", serviceAvailable: true)
        calibration = CalibrationProfile(config: try Configuration(dell: dell, zowie: zowie, ddc: device), strategy: .mirror)
        try calibration.register(.usbC, value: 0x1b1b, verified: true)
        try calibration.register(.hdmi, value: 0x1b11, verified: ready)
    }

    func setInput(_ value: UInt16?) { self.value = value }
    func setDellPower(_ value: UInt16?) { dellPower = value }
    func setZowiePower(_ value: UInt16?) { zowiePower = value }
    func failInitialization() { initializationFailures += 1 }
    func failRestoration() { restorationFailures += 1 }
    func suspendRead() { suspendNextRead = true }
    func waitForRead() async {
        if pendingRead != nil { return }
        await withCheckedContinuation { readWaiter = $0 }
    }
    func completeRead(failing: Bool = false) {
        let pending = pendingRead; pendingRead = nil
        if failing { pending?.resume(throwing: BridgeError("Temporary connection failure")) }
        else { pending?.resume(returning: state(readInput: true)) }
    }

    private func state(readInput: Bool) -> RuntimeStatus {
        RuntimeStatus(mode: mode, zowieHz: 240, dellHz: 120, protected: true,
                      value: readInput ? value : nil, readError: readInput && value == nil ? "Temporary DDC failure" : nil, mainDisplay: main)
    }
    func initialize(seed: URL?) throws -> CalibrationProfile {
        initializations += 1
        if initializationFailures > 0 { initializationFailures -= 1; throw BridgeError("Display absent during launch") }
        return calibration
    }
    func status(readInput: Bool) async throws -> RuntimeStatus {
        if suspendNextRead {
            suspendNextRead = false
            return try await withCheckedThrowingContinuation {
                pendingRead = $0
                readWaiter?.resume(); readWaiter = nil
            }
        }
        return state(readInput: readInput)
    }
    func single(_ strategy: HideStrategy) throws -> RuntimeStatus {
        singleSwitches += 1
        mode = strategy == .mirror ? .mirrored : .single
        main = .zowie
        return state(readInput: false)
    }
    func dual() throws -> RuntimeStatus {
        restorations += 1
        if restorationFailures > 0 { restorationFailures -= 1; throw BridgeError("Commit display transaction: CGError 1014") }
        mode = .dual
        main = dualMain
        return state(readInput: false)
    }
    func mainDisplay(_ target: MainDisplay) throws -> RuntimeStatus {
        mainSwitches += 1; main = target; dualMain = target
        return state(readInput: false)
    }
    func registerMainInput() throws -> CalibrationProfile {
        calibration.zowieMacInput = CalibrationPoint(value: 0x11, verified: true)
        return calibration
    }
    func mainAvailability(dellInput: UInt16?) throws -> MainAvailability {
        MainAvailability(dell: .classify(online: true, input: dellInput, macInput: 0x1b1b, power: dellPower),
                         zowie: .classify(online: true, input: zowieInput, macInput: 0x11, power: zowiePower))
    }
    func configure() throws -> CalibrationProfile { calibration }
    func calibrate(_ input: InputSource) throws -> CalibrationProfile { calibration }
    func strategy(_ strategy: HideStrategy) throws -> CalibrationProfile { calibration.strategy = strategy; return calibration }
    func heartbeat() throws {}
    func profile() throws -> CalibrationProfile { calibration }
    func log(_ event: String, _ detail: String) {}
}

@MainActor
private final class TestClock { var time: TimeInterval = 0 }

@MainActor
final class AutomaticPreferenceTests: XCTestCase {
    private var root: URL!

    private func model(worker: StubDisplayWorker, clock: TestClock) throws -> AppModel {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var saved = Preferences(); saved.automatic = true; saved.welcomed = true
        try JSON.save(saved, root.appendingPathComponent("preferences.json"))
        addTeardownBlock { [root = root!] in try? FileManager.default.removeItem(at: root) }
        return AppModel(root: root, worker: worker, now: { clock.time })
    }

    private func savedAutomatic() throws -> Bool {
        try JSON.load(Preferences.self, root.appendingPathComponent("preferences.json")).automatic
    }

    func testWakeWaitsForDisplaysAndRetriesWithoutDisablingSavedPreference() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        model.didSleep()
        clock.time = 100; model.didWake()
        await worker.failRestoration()
        await model.pollOnce()
        var restorations = await worker.restorations
        XCTAssertEqual(restorations, 0, "Do not reconfigure displays immediately on wake")
        clock.time = 120; await model.pollOnce()
        XCTAssertTrue(model.recoveryPending)
        XCTAssertTrue(model.preferences.automatic)
        XCTAssertTrue(try savedAutomatic())
        clock.time = 134; await model.pollOnce()
        restorations = await worker.restorations
        XCTAssertEqual(restorations, 1, "A transient failure must wait before retrying")
        clock.time = 135; await model.pollOnce()
        XCTAssertFalse(model.recoveryPending)
        for time in [145.0, 147, 149] { clock.time = time; await model.pollOnce() }
        XCTAssertNil(model.automaticPauseReason)
        XCTAssertTrue(try savedAutomatic())
        XCTAssertEqual(model.mode, .dual)
    }

    func testRepeatedDDCFailuresPauseThenResumeAfterFreshKnownInput() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        await worker.setInput(nil)
        for time in [10.0, 12, 14] { clock.time = time; await model.pollOnce() }
        XCTAssertTrue(model.preferences.automatic)
        XCTAssertTrue(try savedAutomatic())
        XCTAssertTrue(model.recoveryPending)
        var switches = await worker.singleSwitches
        XCTAssertEqual(switches, 0, "Failed DDC reads must not select HDMI")
        clock.time = 29; await model.pollOnce()
        await worker.setInput(0x1b11)
        for time in [39.0, 41] { clock.time = time; await model.pollOnce() }
        switches = await worker.singleSwitches
        XCTAssertEqual(switches, 0, "Require three fresh known readings after recovery")
        clock.time = 43; await model.pollOnce()
        switches = await worker.singleSwitches
        XCTAssertEqual(switches, 1)
        XCTAssertNil(model.automaticPauseReason)
        XCTAssertTrue(try savedAutomatic())
    }

    func testSleepDiscardsAnInFlightHDMIRead() async throws {
        try await assertSleepDiscardsRead(failing: false)
    }

    func testSleepDiscardsAnInFlightReadError() async throws {
        try await assertSleepDiscardsRead(failing: true)
    }

    private func assertSleepDiscardsRead(failing: Bool) async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        await worker.setInput(0x1b11)
        for time in [10.0, 12] { clock.time = time; await model.pollOnce() }
        await worker.suspendRead()
        clock.time = 14
        let pending = Task { await model.pollOnce() }
        await worker.waitForRead()
        model.didSleep()
        await worker.completeRead(failing: failing)
        await pending.value
        let switches = await worker.singleSwitches
        XCTAssertEqual(switches, 0)
        XCTAssertTrue(model.sleeping)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(try savedAutomatic())
    }

    func testExplicitOffRemainsOffThroughWakeFailureAndRecovery() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        model.setAutomatic(false)
        model.didSleep(); clock.time = 100; model.didWake()
        await worker.failRestoration()
        clock.time = 120; await model.pollOnce()
        clock.time = 135; await model.pollOnce()
        await worker.setInput(0x1b11)
        for time in [145.0, 151, 157] { clock.time = time; await model.pollOnce() }
        let switches = await worker.singleSwitches
        XCTAssertEqual(switches, 0)
        XCTAssertFalse(model.preferences.automatic)
        XCTAssertFalse(try savedAutomatic())
    }

    func testManualActionKeepsOnAndAllowsAutomaticSwitchAfterHold() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        await worker.setInput(0x1b11)
        model.dual()
        await model.operationTask?.value
        XCTAssertTrue(model.preferences.automatic)
        XCTAssertTrue(try savedAutomatic())
        clock.time = 29; await model.pollOnce()
        var switches = await worker.singleSwitches
        XCTAssertEqual(switches, 0)
        for time in [30.0, 32, 34] { clock.time = time; await model.pollOnce() }
        switches = await worker.singleSwitches
        XCTAssertEqual(switches, 1)
    }

    func testUnverifiedCalibrationKeepsOnWithoutSwitchingAndCanBeTurnedOff() async throws {
        let worker = try StubDisplayWorker(ready: false), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        await worker.setInput(0x1b11)
        for time in [10.0, 12, 14] { clock.time = time; await model.pollOnce() }
        let switches = await worker.singleSwitches
        XCTAssertEqual(switches, 0)
        XCTAssertTrue(model.preferences.automatic)
        XCTAssertFalse(model.automaticReady)
        XCTAssertTrue(try savedAutomatic())
        model.setAutomatic(false)
        XCTAssertFalse(try savedAutomatic())
    }

    func testLaunchConnectionFailureRetriesWithSavedOnPreference() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await worker.failInitialization()
        await model.initializeRuntime()
        XCTAssertFalse(model.initialized)
        XCTAssertTrue(try savedAutomatic())
        clock.time = 15; await model.pollOnce()
        let initializations = await worker.initializations
        XCTAssertEqual(initializations, 2)
        XCTAssertTrue(model.initialized)
        XCTAssertTrue(model.preferences.automatic)
    }

    func testOldPreferencesRetainAutomaticOnWithNewMainOptionDefaultOff() throws {
        let old = Data(#"{"automatic":true,"shortcuts":true,"shortcutPreset":"controlOptionCommand","welcomed":true}"#.utf8)
        let restored = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertTrue(restored.automatic)
        XCTAssertFalse(restored.automaticMainDisplay)
        XCTAssertTrue(restored.welcomed)
    }

    func testMainDisplayFollowsUSBCAndHDMIWithoutChangingOnPreference() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        model.setAutomaticMainDisplay(true)
        await model.operationTask?.value
        for time in [15.0, 17, 19, 21, 23, 25, 27] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .dell)
        XCTAssertEqual(model.mode, .dual)
        await worker.setInput(0x1b11)
        for time in [42.0, 44, 46] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .zowie)
        XCTAssertEqual(model.mode, .mirrored)
        await worker.setInput(0x1b1b)
        for time in [61.0, 63, 65] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .dell)
        XCTAssertEqual(model.mode, .dual)
        XCTAssertTrue(try savedAutomatic())
        let preferences = try JSON.load(Preferences.self, root.appendingPathComponent("preferences.json"))
        XCTAssertTrue(preferences.automaticMainDisplay)
    }

    func testMainDisplayStaysUnchangedWhenNewOptionIsOff() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        for time in [10.0, 12, 14] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .zowie)
        let changes = await worker.mainSwitches
        XCTAssertEqual(changes, 0)
    }

    func testDellPowerOffFallsBackToZowieThenReturnsToPreferredDell() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        model.setAutomaticMainDisplay(true); await model.operationTask?.value
        for time in [15.0, 21, 27] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .dell)
        await worker.setDellPower(4)
        for time in [42.0, 48, 54] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.mainAvailability?.dell, .poweredOff)
        XCTAssertEqual(model.status?.mainDisplay, .zowie)
        await worker.setDellPower(1)
        for time in [69.0, 75, 81] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .dell)
        XCTAssertTrue(try savedAutomatic())
    }

    func testMissingDellDDCStillAllowsConfirmedZowieFallback() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        model.setAutomaticMainDisplay(true); await model.operationTask?.value
        for time in [15.0, 17, 19, 21, 23, 25, 27] { clock.time = time; await model.pollOnce() }
        await worker.setInput(nil); await worker.setDellPower(nil)
        for time in [42.0, 44, 46, 48, 50, 52, 54] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.mainAvailability?.dell, .unknown)
        XCTAssertEqual(model.status?.mainDisplay, .zowie)
        let singleSwitches = await worker.singleSwitches
        XCTAssertEqual(singleSwitches, 0, "Unknown DDC must not be interpreted as HDMI")
        XCTAssertTrue(try savedAutomatic())
        let restorations = await worker.restorations
        for time in [69.0, 71, 73, 75, 77, 79, 81, 83, 85, 87] { clock.time = time; await model.pollOnce() }
        let laterRestorations = await worker.restorations
        XCTAssertEqual(laterRestorations, restorations, "Do not repeatedly restore an unreachable display")
        XCTAssertEqual(model.status?.mainDisplay, .zowie)
    }

    func testUnavailableZowieDoesNotPreventSwitchToConfirmedDell() async throws {
        let worker = try StubDisplayWorker(), clock = TestClock()
        let model = try model(worker: worker, clock: clock)
        await model.initializeRuntime()
        model.setAutomaticMainDisplay(true); await model.operationTask?.value
        await worker.setZowiePower(4)
        for time in [15.0, 21, 27] { clock.time = time; await model.pollOnce() }
        XCTAssertEqual(model.status?.mainDisplay, .dell)
        XCTAssertEqual(model.mainAvailability?.zowie, .poweredOff)
        XCTAssertFalse(model.recoveryPending)
    }
}
