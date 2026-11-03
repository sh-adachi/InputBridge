import Foundation
import Darwin

public struct Inventory: Codable {
    public let displays: [DisplayState]
    public let ddcDevices: [DDCDevice]
    public let disableAPIAvailable: Bool
}
public struct Observation: Codable {
    public let date: Date
    public let run: String
    public let label: String
    public let phase: String
    public let reading: VCPReading?
    public let error: String?
}
public struct Experiment: Codable {
    public let date: Date
    public let mode: String
    public let label: String
    public let mutationObserved: Bool
    public let protectedUnchanged: Bool
    public let protectedTimingAdjusted: Bool?
    public let ddcReadable: Bool
    public let restored: Bool
    public let error: String?
    public let before: Recovery
    public let during: [DisplayState]
    public let readings: [Observation]
}
public struct Feasibility: Codable {
    public let calibrated: Bool
    public let usbCValue: UInt16?
    public let hdmiValue: UInt16?
    public let disableCandidate: Bool
    public let mirrorCandidate: Bool
    public let reasons: [String]
}

public struct Diagnostics {
    public let root: URL
    public let executable: URL
    public let helper: URL
    public var configURL: URL { root.appendingPathComponent("config.json") }
    public var recoveryURL: URL { root.appendingPathComponent("recovery.json") }
    public var observationURL: URL { root.appendingPathComponent("observations.jsonl") }
    public var experimentsURL: URL { root.appendingPathComponent("experiments.jsonl") }
    public var zowieProbeURL: URL { root.appendingPathComponent("zowie-probes.jsonl") }
    public init(root: URL, executable: URL) {
        self.root = root.standardizedFileURL
        self.executable = executable.standardizedFileURL
        helper = executable.deletingLastPathComponent().appendingPathComponent("inputbridge-ddc")
    }
    public func inventory() throws -> Inventory {
        Inventory(displays: try Displays.list(), ddcDevices: try Subprocess.decoded([DDCDevice].self, executable: helper, args: ["detect"]), disableAPIAvailable: Displays.enableAvailable)
    }
    public func configuration() throws -> Configuration {
        let config = try JSON.load(Configuration.self, configURL)
        try config.validate()
        return config
    }
    public func configure() throws -> Configuration {
        guard !FileManager.default.fileExists(atPath: recoveryURL.path) else { throw BridgeError("Pending recovery exists. Run recover first.") }
        let inventory = try inventory()
        let dells = inventory.displays.filter { $0.identity.vendor == 0x10ac && $0.identity.name == "DELL S2725QC" }
        let zowies = inventory.displays.filter { $0.identity.vendor == 0x09d1 && $0.identity.name == "ZOWIE XL LCD" }
        guard dells.count == 1, zowies.count == 1 else { throw BridgeError("Exactly one S2725QC and one ZOWIE XL LCD required") }
        let dell = dells[0], zowie = zowies[0]
        try Safety.preflight(dell: dell, zowie: zowie)
        let devices = inventory.ddcDevices.filter { $0.manufacturer == "DEL" && $0.name == dell.identity.name && $0.numericSerial == Int64(dell.identity.serial) && $0.location == dell.identity.location }
        guard devices.count == 1 else { throw BridgeError("Cannot uniquely map Dell DDC service to its display") }
        let config = try Configuration(dell: dell.identity, zowie: zowie.identity, ddc: devices[0])
        try JSON.save(config, configURL)
        return config
    }
    public func observe(label: String, phase: String = "extended", run: String) throws -> Observation {
        let config = try configuration()
        let observation: Observation
        do {
            let reading = try readDell(config: config)
            observation = Observation(date: Date(), run: run, label: label, phase: phase, reading: reading, error: reading.error)
        } catch {
            observation = Observation(date: Date(), run: run, label: label, phase: phase, reading: nil, error: error.localizedDescription)
        }
        try append(observation, to: observationURL)
        return observation
    }
    public func readDell(config: Configuration? = nil) throws -> VCPReading {
        let config = try config ?? configuration()
        try config.validate()
        let reading = try Subprocess.decoded(VCPReading.self, executable: helper, args: ["getvcp", "0x60", "--serial", config.ddc.serial, config.ddc.edid])
        guard reading.device.manufacturer == "DEL", reading.device.name == config.dell.name,
              reading.device.numericSerial == Int64(config.dell.serial),
              reading.device.serial == config.ddc.serial, reading.device.edid == config.ddc.edid else { throw BridgeError("DDC helper identity mismatch") }
        return reading
    }
    public func probeZowie(run: String) throws -> Observation {
        let config = try configuration()
        let observation: Observation
        do {
            let display = try Displays.resolve(config.zowie)
            let devices = try Subprocess.decoded([DDCDevice].self, executable: helper, args: ["detect"])
            let matches = devices.filter { $0.manufacturer == "BNQ" && $0.name == config.zowie.name && $0.numericSerial == Int64(config.zowie.serial) && $0.location == display.identity.location }
            guard matches.count == 1, let target = matches.first, !target.serial.isEmpty, !target.edid.isEmpty else { throw BridgeError("Cannot uniquely map protected ZOWIE to its read-only DDC service") }
            let reading = try Subprocess.decoded(VCPReading.self, executable: helper, args: ["getvcp-zowie", "0x60", "--serial", target.serial, target.edid])
            guard reading.device == target else { throw BridgeError("ZOWIE probe identity mismatch") }
            observation = Observation(date: Date(), run: run, label: "zowie-connection", phase: "probe-zowie", reading: reading, error: reading.error)
        } catch {
            observation = Observation(date: Date(), run: run, label: "zowie-connection", phase: "probe-zowie", reading: nil, error: error.localizedDescription)
        }
        // Never feed another monitor's input value into Dell calibration/evaluation.
        try append(observation, to: zowieProbeURL)
        return observation
    }
    public func append<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value); data.append(0x0a)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError("Cannot open diagnostic log") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
    }
    public func lines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: url).split(separator: 0x0a).map { try decoder.decode(type, from: Data($0)) }
    }
    public func evaluate() throws -> Feasibility {
        let observations = try lines(Observation.self, from: observationURL)
        func stable(_ label: String) -> UInt16? {
            let selected = observations.filter { $0.label == label && $0.phase == "extended" }
            guard let latest = selected.last else { return nil }
            let batch = selected.filter { $0.run == latest.run }
            var sequence = ReadingStability()
            for sample in batch { sequence.ingest(sample.reading?.valid == true && sample.error == nil ? sample.reading?.current : nil) }
            return sequence.stableValue
        }
        let usb = stable("usb-c"), hdmi = stable("hdmi")
        let calibrated = usb != nil && hdmi != nil && usb != hdmi
        let experiments = try lines(Experiment.self, from: experimentsURL)
        func candidate(_ mode: String) -> Bool {
            ["usb-c", "hdmi"].allSatisfy { label in
                guard let test = experiments.last(where: { $0.mode == mode && $0.label == label }),
                      test.mutationObserved, (test.protectedUnchanged || test.protectedTimingAdjusted == true), test.restored, test.ddcReadable, test.error == nil,
                      !test.readings.isEmpty else { return false }
                let expected = label == "usb-c" ? usb : hdmi
                var sequence = ReadingStability()
                for sample in test.readings { sequence.ingest(sample.reading?.valid == true && sample.error == nil ? sample.reading?.current : nil) }
                return expected != nil && sequence.stableValue == expected
            }
        }
        var reasons: [String] = []
        if !calibrated { reasons.append("Need >=3 stable, distinct USB-C and HDMI readings. DDC failure is never treated as HDMI.") }
        if !candidate("disable") { reasons.append("Disable + DDC + restore not yet verified under both physical inputs.") }
        if !candidate("mirror") { reasons.append("Mirror + DDC + source timing preservation + restore not yet verified under both physical inputs.") }
        reasons.append("A full OSD USB-C→HDMI→USB-C cycle, sleep/wake, and reconnect tests are still required before unattended automation.")
        return Feasibility(calibrated: calibrated, usbCValue: usb, hdmiValue: hdmi, disableCandidate: calibrated && candidate("disable"), mirrorCandidate: calibrated && candidate("mirror"), reasons: reasons)
    }
    public func recover() throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        let saved = try JSON.load(Recovery.self, recoveryURL)
        let devices = try Subprocess.decoded([DDCDevice].self, executable: helper, args: ["detect"])
        guard devices.contains(where: { $0.manufacturer == "DEL" && $0.name == saved.configuration.ddc.name && $0.serial == saved.configuration.ddc.serial && $0.edid == saved.configuration.ddc.edid }) else {
            try Displays.restoreProtected(saved)
            throw BridgeError("Dell DDC identity unavailable; ZOWIE timing restored. Reconnect Dell USB-C.")
        }
        try Displays.restore(saved)
        Thread.sleep(forTimeInterval: 2)
        try verifyRestored(saved)
        try JSON.save(saved, root.appendingPathComponent("last-recovery.json"))
        try FileManager.default.removeItem(at: recoveryURL)
    }
    public func verifyRestored(_ saved: Recovery) throws {
        let dell = try Displays.resolve(saved.configuration.dell)
        try Safety.checkProtected(saved.zowie, try Displays.resolve(saved.configuration.zowie))
        guard dell.active, !dell.inMirrorSet, dell.x == saved.dell.x, dell.y == saved.dell.y,
              let old = saved.dell.mode, let current = dell.mode, old.equivalent(to: current) else {
            throw BridgeError("Dell layout restoration not verified. Recovery file retained; reconnect Dell USB-C or use Displays settings.")
        }
    }
    public func test(mode: String, label: String, seconds: Int) throws -> Experiment {
        guard ["disable", "mirror"].contains(mode), ["usb-c", "hdmi"].contains(label), (5...30).contains(seconds) else { throw BridgeError("Invalid test options") }
        guard !FileManager.default.fileExists(atPath: recoveryURL.path) else { throw BridgeError("Pending recovery. Run recover first") }
        let config = try configuration(), saved = try Recovery(config: config)
        try JSON.save(saved, recoveryURL)
        let watchdog = Process()
        watchdog.executableURL = executable
        watchdog.arguments = ["_watchdog", "--workspace", root.path, "--token", saved.token, "--seconds", String(seconds + 12)]
        watchdog.standardInput = FileHandle.nullDevice; watchdog.standardOutput = FileHandle.nullDevice; watchdog.standardError = FileHandle.nullDevice
        do { try watchdog.run() } catch { try FileManager.default.removeItem(at: recoveryURL); throw error }
        let ready = root.appendingPathComponent("watchdog-\(saved.token).ready")
        let waitUntil = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: ready.path) && watchdog.isRunning && ProcessInfo.processInfo.systemUptime < waitUntil { Thread.sleep(forTimeInterval: 0.02) }
        guard FileManager.default.fileExists(atPath: ready.path) else { throw BridgeError("Watchdog not ready; no changes made. Run recover.") }
        defer { try? FileManager.default.removeItem(at: ready) }
        var observed = false, protected = false, restored = false, timingAdjusted = false
        var during: [DisplayState] = [], readings: [Observation] = []
        var failure: String?
        var sequence = ReadingStability()
        do {
            if mode == "disable" { try Displays.setDellEnabled(false, config: config) }
            else { try Displays.mirrorDell(config: config) }
            Thread.sleep(forTimeInterval: 2)
            during = try Displays.list()
            let currentZowie = try Displays.resolve(config.zowie)
            // Never tolerate loss of the protected display. Some OS versions reset only its
            // refresh rate on disable; record and repair that timing before continuing.
            guard currentZowie.active, currentZowie.main, currentZowie.mirrorOf == 0 else { throw BridgeError("Protected ZOWIE lost active/main status") }
            guard let protectedMode = saved.zowie.mode else { throw BridgeError("Missing protected display mode") }
            timingAdjusted = currentZowie.mode?.equivalent(to: protectedMode) != true
            if timingAdjusted { try Displays.restoreProtected(saved); Thread.sleep(forTimeInterval: 1) }
            try Safety.checkProtected(saved.zowie, try Displays.resolve(config.zowie))
            protected = true
            if mode == "disable" { observed = !during.contains { $0.identity.matches(config.dell) && $0.enabled } }
            else { let dell = try Displays.resolve(config.dell); let zowie = try Displays.resolve(config.zowie); observed = dell.inMirrorSet && dell.mirrorOf == zowie.id }
            guard observed else { throw BridgeError("Requested display change was not observed") }
            let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds - 2)
            repeat {
                let sample = try observe(label: label, phase: mode, run: saved.token)
                readings.append(sample)
                sequence.ingest(sample.reading?.valid == true && sample.error == nil ? sample.reading?.current : nil)
                try Safety.checkProtected(saved.zowie, try Displays.resolve(config.zowie))
                if sequence.failed || sequence.stableValue != nil { break }
                Thread.sleep(forTimeInterval: 1)
            } while ProcessInfo.processInfo.systemUptime < deadline
        } catch { failure = error.localizedDescription }
        do { try recover(); restored = true } catch { failure = [failure, "Recovery failed: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: "; ") }
        let result = Experiment(date: Date(), mode: mode, label: label, mutationObserved: observed, protectedUnchanged: protected && !timingAdjusted, protectedTimingAdjusted: timingAdjusted, ddcReadable: sequence.stableValue != nil, restored: restored, error: failure, before: saved, during: during, readings: readings)
        try append(result, to: experimentsURL)
        return result
    }
    public func watchdog(token: String, seconds: Int) throws {
        guard (1...45).contains(seconds) else { throw BridgeError("Invalid watchdog deadline") }
        guard try JSON.load(Recovery.self, recoveryURL).token == token else { throw BridgeError("Watchdog token mismatch") }
        let ready = root.appendingPathComponent("watchdog-\(token).ready")
        try Data().write(to: ready, options: .atomic)
        defer { try? FileManager.default.removeItem(at: ready) }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let current = try? JSON.load(Recovery.self, recoveryURL), current.token == token else { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let current = try? JSON.load(Recovery.self, recoveryURL), current.token == token else { return }
        do { try recover() } catch {
            try append(Observation(date: Date(), run: token, label: "unknown", phase: "watchdog-recovery", reading: nil, error: error.localizedDescription), to: observationURL)
            throw error
        }
    }
}

public final class WorkspaceLock {
    private let fd: Int32
    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fd = open(root.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError("Cannot create workspace lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw BridgeError("Another diagnostic operation is running") }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
