import Foundation
import Darwin

public struct SessionLease: Codable {
    public let token: String
    public let owner: Int32
    public var heartbeat: TimeInterval
    public let bootSession: String
    public init(token: String, owner: Int32 = getpid(), heartbeat: TimeInterval = ProcessInfo.processInfo.systemUptime, bootSession: String = BootSession.id) {
        self.token = token; self.owner = owner; self.heartbeat = heartbeat; self.bootSession = bootSession
    }
    public func expired(now: TimeInterval, bootSession: String, ownerAlive: Bool) -> Bool {
        !ownerAlive || self.bootSession != bootSession || now < heartbeat || now - heartbeat > 35
    }
}

public struct RuntimeStatus: Codable {
    public let mode: WorkspaceMode
    public let zowieHz: Double?
    public let dellHz: Double?
    public let protected: Bool
    public let value: UInt16?
    public let readError: String?
}

public struct RuntimeEvent: Codable {
    public let date: Date
    public let event: String
    public let detail: String
}

/// Called on the application's serial worker actor. Synchronous display transactions
/// stay off the UI thread; the independent CLI watchdog can recover a dead/hung owner.
public struct RuntimeController {
    public let diagnostics: Diagnostics
    public var root: URL { diagnostics.root }
    public var baselineURL: URL { root.appendingPathComponent("baseline.json") }
    public var profileURL: URL { root.appendingPathComponent("calibration.json") }
    public var leaseURL: URL { root.appendingPathComponent("session-lease.json") }
    public var logURL: URL { root.appendingPathComponent("events.jsonl") }
    public init(root: URL, executable: URL) { diagnostics = Diagnostics(root: root, executable: executable) }

    public func log(_ event: String, _ detail: String) {
        // Keep error logging available even when display configuration is invalid.
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 2_000_000 {
                let previous = root.appendingPathComponent("events.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: logURL, to: previous)
            }
            try diagnostics.append(RuntimeEvent(date: Date(), event: event, detail: detail), to: logURL)
        } catch { /* Logging failure must not prevent screen recovery. */ }
    }

    public func initialize(seed: URL? = nil) throws -> CalibrationProfile {
        let lock = try WorkspaceLock(root: root); defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: diagnostics.recoveryURL.path) {
            if let lease = try? JSON.load(SessionLease.self, leaseURL), lease.owner != getpid(),
               !lease.expired(now: ProcessInfo.processInfo.systemUptime, bootSession: BootSession.id, ownerAlive: kill(lease.owner, 0) == 0) {
                throw BridgeError("別のInputBridgeがディスプレイを管理しています。")
            }
            try diagnostics.recover()
            try? FileManager.default.removeItem(at: leaseURL)
        }
        let config: Configuration
        if FileManager.default.fileExists(atPath: diagnostics.configURL.path) { config = try diagnostics.configuration() }
        else { config = try diagnostics.configure() }
        _ = try Displays.resolve(config.dell)
        _ = try Displays.resolve(config.zowie)
        if !FileManager.default.fileExists(atPath: baselineURL.path) { try JSON.save(Recovery(config: config), baselineURL) }
        var profile = CalibrationProfile(config: config)
        if let existing = try? JSON.load(CalibrationProfile.self, profileURL), existing.matches(config) { profile = existing }
        else if let seed, let initial = try? JSON.load(CalibrationProfile.self, seed), initial.matches(config) { profile = initial }
        try JSON.save(profile, profileURL)
        log("launch", "Display configuration loaded")
        return profile
    }

    public func refreshConfiguration() throws -> CalibrationProfile {
        let lock = try WorkspaceLock(root: root); defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: diagnostics.recoveryURL.path) { try diagnostics.recover() }
        try? FileManager.default.removeItem(at: leaseURL)
        let config = try diagnostics.configure()
        try JSON.save(Recovery(config: config), baselineURL)
        let profile: CalibrationProfile
        if let previous = try? JSON.load(CalibrationProfile.self, profileURL), previous.matches(config) { profile = previous }
        else { profile = CalibrationProfile(config: config) }
        try JSON.save(profile, profileURL)
        log("configuration", "Current dual-display arrangement saved")
        return profile
    }

    public func status(readInput: Bool = true) throws -> RuntimeStatus {
        let config = try diagnostics.configuration()
        let displays = try Displays.list()
        guard let zowie = displays.first(where: { config.zowie.matches($0.identity) }) else {
            throw BridgeError("保護対象のZOWIEが見つかりません。配線を確認してください。")
        }
        let dell = displays.first(where: { config.dell.matches($0.identity) })
        let sourceProtected = zowie.active && zowie.main && zowie.mirrorOf == 0
        let owned = FileManager.default.fileExists(atPath: diagnostics.recoveryURL.path)
        let mode: WorkspaceMode
        if !sourceProtected { mode = .unavailable }
        else if let dell, dell.inMirrorSet, dell.mirrorOf == zowie.id { mode = .mirrored }
        else if let dell, dell.active { mode = .dual }
        else if owned { mode = .single }
        else { mode = .unavailable }
        var value: UInt16?, readError: String?
        if readInput {
            do {
                let reading = try diagnostics.readDell(config: config)
                value = reading.valid ? reading.current : nil
                readError = reading.error
            } catch { readError = error.localizedDescription }
        }
        return RuntimeStatus(mode: mode, zowieHz: zowie.mode?.refreshRate, dellHz: dell?.mode?.refreshRate, protected: sourceProtected, value: value, readError: readError)
    }

    public func heartbeat() throws {
        guard let lease = try? JSON.load(SessionLease.self, leaseURL), lease.owner == getpid(),
              let recovery = try? JSON.load(Recovery.self, diagnostics.recoveryURL), recovery.token == lease.token else { return }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("session-\(lease.token).ready").path) else {
            throw BridgeError("復旧監視のプロセスが停止しました。Dellを復旧してください。")
        }
        var updated = lease; updated.heartbeat = ProcessInfo.processInfo.systemUptime
        try JSON.save(updated, leaseURL)
    }

    private func arm(_ saved: Recovery) throws {
        try JSON.save(saved, diagnostics.recoveryURL)
        try JSON.save(SessionLease(token: saved.token), leaseURL)
        let watchdog = Process()
        watchdog.executableURL = diagnostics.executable
        watchdog.arguments = ["_session-watchdog", "--workspace", root.path, "--token", saved.token, "--owner", String(getpid())]
        watchdog.standardInput = FileHandle.nullDevice; watchdog.standardOutput = FileHandle.nullDevice; watchdog.standardError = FileHandle.nullDevice
        do { try watchdog.run() } catch {
            try? FileManager.default.removeItem(at: diagnostics.recoveryURL)
            try? FileManager.default.removeItem(at: leaseURL)
            throw error
        }
        let ready = root.appendingPathComponent("session-\(saved.token).ready")
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: ready.path) && watchdog.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard FileManager.default.fileExists(atPath: ready.path) else { throw BridgeError("復旧プロセスを準備できなかったため切替を中止しました。") }
    }

    public func switchToSingle(strategy: HideStrategy) throws -> RuntimeStatus {
        let lock = try WorkspaceLock(root: root); defer { withExtendedLifetime(lock) {} }
        let config = try diagnostics.configuration()
        if FileManager.default.fileExists(atPath: diagnostics.recoveryURL.path) {
            let state = try status(readInput: false)
            let expected: WorkspaceMode = strategy == .disable ? .single : .mirrored
            if state.mode == expected { return state }
            try diagnostics.recover()
        }
        let saved = try Recovery(config: config)
        try JSON.save(saved, baselineURL)
        try arm(saved)
        do {
            if strategy == .disable { try Displays.setDellEnabled(false, config: config) }
            else { try Displays.mirrorDell(config: config) }
            Thread.sleep(forTimeInterval: 1)
            let zowie = try Displays.resolve(config.zowie)
            guard zowie.active, zowie.main, zowie.mirrorOf == 0 else { throw BridgeError("ZOWIEの表示状態が変化したため復旧します。") }
            try Displays.restoreProtected(saved)
            Thread.sleep(forTimeInterval: 0.4)
            try Safety.checkProtected(saved.zowie, try Displays.resolve(config.zowie))
            let state = try status(readInput: false)
            guard state.mode == (strategy == .disable ? .single : .mirrored) else { throw BridgeError("Dellの切替を確認できなかったため復旧します。") }
            try heartbeat()
            log("single", strategy.rawValue)
            return state
        } catch {
            let original = error.localizedDescription
            do { try diagnostics.recover(); try? FileManager.default.removeItem(at: leaseURL) }
            catch { log("recovery-error", error.localizedDescription); throw BridgeError("\(original) 復旧にも失敗しました。DellのUSB-Cを抜き差ししてください。") }
            throw BridgeError(original)
        }
    }

    public func restoreDual() throws -> RuntimeStatus {
        let lock = try WorkspaceLock(root: root); defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: diagnostics.recoveryURL.path) {
            try diagnostics.recover()
        } else if FileManager.default.fileExists(atPath: baselineURL.path) {
            let saved = try JSON.load(Recovery.self, baselineURL)
            if (try? diagnostics.verifyRestored(saved)) == nil {
                // Persist recovery before a multi-step restore so a crash retains the baseline.
                try arm(saved)
                try diagnostics.recover()
            }
        } else { throw BridgeError("保存したデュアル構成がありません。接続情報を再取得してください。") }
        try? FileManager.default.removeItem(at: leaseURL)
        log("dual", "Saved arrangement restored")
        return try status(readInput: false)
    }

    public func saveStrategy(_ strategy: HideStrategy) throws -> CalibrationProfile {
        let lock = try WorkspaceLock(root: root); defer { withExtendedLifetime(lock) {} }
        let config = try diagnostics.configuration()
        let profile = CalibrationProfile(config: config, strategy: strategy)
        try JSON.save(profile, profileURL)
        return profile
    }

    public func calibrate(_ source: InputSource) throws -> CalibrationProfile {
        let lock = try WorkspaceLock(root: root); defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: diagnostics.recoveryURL.path) { try diagnostics.recover(); try? FileManager.default.removeItem(at: leaseURL) }
        let config = try diagnostics.configuration()
        var profile = (try? JSON.load(CalibrationProfile.self, profileURL)) ?? CalibrationProfile(config: config)
        guard profile.matches(config) else { throw BridgeError("ディスプレイの識別情報が変わりました。接続情報を再取得してください。") }
        profile.invalidate(source)
        try JSON.save(profile, profileURL)
        let snapshot = try Recovery(config: config)
        try JSON.save(snapshot, baselineURL)
        let run = UUID().uuidString
        var sequence = ReadingStability()
        for _ in 0..<8 {
            let sample = try diagnostics.observe(label: source.rawValue, run: run)
            sequence.ingest(sample.reading?.valid == true ? sample.reading?.current : nil)
            if sequence.failed { throw BridgeError("Dellから入力状態を取得できませんでした。DDC/CIの設定を確認してください。") }
            if sequence.stableValue != nil { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard let value = sequence.stableValue else { throw BridgeError("入力値が安定しません。切替完了後に再登録してください。") }
        // Reject a duplicate before doing the temporary display change.
        var proposed = profile; try proposed.register(source, value: value, verified: false)
        let result = try diagnostics.test(mode: profile.strategy.rawValue, label: source.rawValue, seconds: 10)
        var hiddenSequence = ReadingStability()
        for sample in result.readings { hiddenSequence.ingest(sample.reading?.valid == true ? sample.reading?.current : nil) }
        guard result.restored, result.mutationObserved, result.error == nil, result.ddcReadable,
              result.protectedUnchanged || result.protectedTimingAdjusted == true,
              hiddenSequence.stableValue == value else {
            throw BridgeError("非表示中の通信または復帰を確認できませんでした。\(result.error ?? "別の非表示方法を試すか、手動切替を使用してください。")")
        }
        try profile.register(source, value: value, verified: true)
        try JSON.save(profile, profileURL)
        log("calibration", "\(source.rawValue) = \(String(format: "0x%04X", value)), \(profile.strategy.rawValue) verified")
        return profile
    }

    public func watchSession(token: String, owner: Int32) throws {
        guard owner > 1, let initial = try? JSON.load(SessionLease.self, leaseURL), initial.owner == owner, initial.token == token,
              try JSON.load(Recovery.self, diagnostics.recoveryURL).token == token else { throw BridgeError("Invalid session recovery lease") }
        let ready = root.appendingPathComponent("session-\(token).ready")
        try Data().write(to: ready, options: .atomic)
        defer { try? FileManager.default.removeItem(at: ready) }
        while true {
            guard let saved = try? JSON.load(Recovery.self, diagnostics.recoveryURL), saved.token == token else { return }
            let current = try? JSON.load(SessionLease.self, leaseURL)
            // A changed token means a new controller owns its own recovery process.
            if let current, current.token != token || current.owner != owner { return }
            let alive = kill(owner, 0) == 0 || errno == EPERM
            if current == nil || current!.expired(now: ProcessInfo.processInfo.systemUptime, bootSession: BootSession.id, ownerAlive: alive) {
                do { try diagnostics.recover(); try? FileManager.default.removeItem(at: leaseURL); log("watchdog-recovery", "Display arrangement restored after owner stopped responding") }
                catch { log("watchdog-error", error.localizedDescription); throw error }
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
