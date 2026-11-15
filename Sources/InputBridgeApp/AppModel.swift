import AppKit
import SwiftUI
import ServiceManagement
import BridgeCore

enum ShortcutPreset: String, Codable, CaseIterable {
    case controlOptionCommand, controlOption, optionCommand
    var title: String {
        switch self { case .controlOptionCommand: return "⌃⌥⌘"; case .controlOption: return "⌃⌥"; case .optionCommand: return "⌥⌘" }
    }
}

struct Preferences: Codable {
    var automatic = false
    var shortcuts = true
    var shortcutPreset: ShortcutPreset = .controlOptionCommand
    var welcomed = false
    var automaticMainDisplay = false

    init() {}
    private enum CodingKeys: String, CodingKey { case automatic, shortcuts, shortcutPreset, welcomed, automaticMainDisplay }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        shortcuts = try values.decodeIfPresent(Bool.self, forKey: .shortcuts) ?? true
        shortcutPreset = try values.decodeIfPresent(ShortcutPreset.self, forKey: .shortcutPreset) ?? .controlOptionCommand
        welcomed = try values.decodeIfPresent(Bool.self, forKey: .welcomed) ?? false
        automaticMainDisplay = try values.decodeIfPresent(Bool.self, forKey: .automaticMainDisplay) ?? false
    }
}

protocol DisplayWorking: Actor {
    func initialize(seed: URL?) throws -> CalibrationProfile
    func status(readInput: Bool) async throws -> RuntimeStatus
    func single(_ strategy: HideStrategy) throws -> RuntimeStatus
    func dual() throws -> RuntimeStatus
    func mainDisplay(_ target: MainDisplay) throws -> RuntimeStatus
    func mainAvailability(dellInput: UInt16?) throws -> MainAvailability
    func registerMainInput() throws -> CalibrationProfile
    func configure() throws -> CalibrationProfile
    func calibrate(_ input: InputSource) throws -> CalibrationProfile
    func strategy(_ strategy: HideStrategy) throws -> CalibrationProfile
    func heartbeat() throws
    func profile() throws -> CalibrationProfile
    func log(_ event: String, _ detail: String)
}

actor DisplayWorker: DisplayWorking {
    let controller: RuntimeController
    init(root: URL, executable: URL) { controller = RuntimeController(root: root, executable: executable) }
    func initialize(seed: URL?) throws -> CalibrationProfile { try controller.initialize(seed: seed) }
    func status(readInput: Bool = true) throws -> RuntimeStatus { try controller.status(readInput: readInput) }
    func single(_ strategy: HideStrategy) throws -> RuntimeStatus { try controller.switchToSingle(strategy: strategy) }
    func dual() throws -> RuntimeStatus { try controller.restoreDual() }
    func mainDisplay(_ target: MainDisplay) throws -> RuntimeStatus { try controller.setMainDisplay(target) }
    func mainAvailability(dellInput: UInt16?) throws -> MainAvailability { try controller.mainAvailability(dellInput: dellInput) }
    func registerMainInput() throws -> CalibrationProfile { try controller.registerMainInput() }
    func configure() throws -> CalibrationProfile { try controller.refreshConfiguration() }
    func calibrate(_ input: InputSource) throws -> CalibrationProfile { try controller.calibrate(input) }
    func strategy(_ strategy: HideStrategy) throws -> CalibrationProfile { try controller.saveStrategy(strategy) }
    func heartbeat() throws { try controller.heartbeat() }
    func profile() throws -> CalibrationProfile { try JSON.load(CalibrationProfile.self, controller.profileURL) }
    func log(_ event: String, _ detail: String) { controller.log(event, detail) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status: RuntimeStatus?
    @Published var profile: CalibrationProfile?
    @Published var preferences: Preferences
    @Published var busy = true
    @Published var activity = "ディスプレイを確認中…"
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published var notice: String?
    @Published var sleeping = false
    @Published var initialized = false
    @Published var selectedTab: SettingsTab = .general
    @Published var loginStatus: SMAppService.Status = SMAppService.mainApp.status
    @Published var lastValue: UInt16?
    @Published var lastRead: Date?
    @Published private(set) var mainAvailability: MainAvailability?
    @Published var shortcutError: String?
    let root: URL
    let worker: any DisplayWorking
    var showSettings: (() -> Void)?
    var onReady: (() -> Void)?
    var onQuitComplete: ((Bool) -> Void)?
    private let preferencesURL: URL
    private let hotkeys = HotKeyManager()
    private var monitorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var consensus = InputConsensus()
    private var mainConsensus = MainDisplayConsensus()
    private var nextMainCheck: TimeInterval = 0
    private var nextRead: TimeInterval = 0
    private var resumeAt: TimeInterval = 0
    private var observerTokens: [NSObjectProtocol] = []
    private var quitting = false
    private let now: () -> TimeInterval
    private(set) var operationTask: Task<Void, Never>?
    private(set) var recoveryPending = false
    @Published private(set) var automaticPauseReason: String?
    private var retryDelay: TimeInterval = 15
    private var readGeneration = 0
    private var wakeGeneration = 0

    init(root suppliedRoot: URL? = nil, worker: (any DisplayWorking)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        if let suppliedRoot { root = suppliedRoot }
        else if let override = ProcessInfo.processInfo.environment["INPUTBRIDGE_DATA_DIR"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InputBridge", isDirectory: true)
        }
        preferencesURL = root.appendingPathComponent("preferences.json")
        preferences = (try? JSON.load(Preferences.self, preferencesURL)) ?? Preferences()
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/inputbridge")
        self.worker = worker ?? DisplayWorker(root: root, executable: cli)
        self.now = now
    }

    var mode: WorkspaceMode { status?.mode ?? .unavailable }
    var automaticReady: Bool { initialized && profile?.ready == true }
    var inputTitle: String {
        guard let lastValue else { return "入力状態を確認中" }
        return profile?.source(for: lastValue)?.title ?? "未登録の入力"
    }
    var strategy: HideStrategy { profile?.strategy ?? .disable }
    var shortcutPrefix: String { preferences.shortcutPreset.title }
    var automaticDescription: String {
        if sleeping { return "スリープ中は監視を休止します" }
        if preferences.automatic && !initialized { return "自動切替オンを保持して接続を待っています" }
        if preferences.automatic && !automaticReady { return "オンを保持中です。入力の登録を確認してください" }
        if preferences.automatic, let automaticPauseReason { return automaticPauseReason }
        if preferences.automatic && now() < resumeAt { return "オンを保持して画面の接続が安定するまで待機中" }
        if preferences.automatic { return "Dell本体の入力操作に追従します" }
        if automaticReady { return "自動切替はオフです" }
        return "USB-CとHDMIを登録すると利用できます"
    }

    func start() {
        installNotifications()
        updateHotkeys()
        Task {
            await initializeRuntime()
            startMonitoring()
            onReady?()
            if !preferences.welcomed { preferences.welcomed = true; persist() }
        }
    }

    func initializeRuntime() async {
        busy = true
        let generation = readGeneration
        do {
            profile = try await worker.initialize(seed: Bundle.main.url(forResource: "InitialCalibration", withExtension: "json"))
            let current = try await worker.status(readInput: true)
            initialized = true
            if !sleeping, generation == readGeneration { apply(current) }
            resumeAt = max(resumeAt, now() + 10)
            consensus.reset(until: resumeAt)
            mainConsensus.reset()
            nextMainCheck = 0
            retryDelay = 15
            notice = "メニューバーから画面を切り替えられます。"
        } catch {
            if !sleeping, generation == readGeneration {
                present(error)
                deferRetry("オンを保持して接続を再確認しています")
            }
        }
        busy = false; activity = ""
    }

    private func persist() {
        do { try JSON.save(preferences, preferencesURL) }
        catch { errorMessage = "設定を保存できませんでした。保存先のアクセス権を確認してください。"; errorDetail = error.localizedDescription }
    }

    private func apply(_ newStatus: RuntimeStatus, readInput: Bool = true) {
        status = newStatus
        if readInput {
            lastValue = newStatus.value
            lastRead = Date()
            nextRead = now() + (newStatus.readError == nil ? 5 : 15)
        }
    }

    func settings(_ tab: SettingsTab = .general) { selectedTab = tab; showSettings?() }
    func dismissError() { errorMessage = nil; errorDetail = nil }
    private func present(_ error: Error) {
        let detail = error.localizedDescription
        let changed = errorDetail != detail
        errorDetail = detail
        if detail.range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) != nil { errorMessage = detail }
        else if detail.contains("identity") || detail.contains("UUID") || detail.contains("identities") {
            errorMessage = "ディスプレイの識別情報を確認できません。「接続情報を再取得」を実行してください。"
        } else if detail.contains("absent") || detail.contains("unavailable") || detail.contains("Display") {
            errorMessage = "Dellの復帰を確認できませんでした。USB-Cを抜き差ししてから「Dellを復旧」を実行してください。"
        } else if detail.contains("main display") || detail.contains("ZOWIE") {
            errorMessage = "ZOWIEの接続と表示状態を確認してから再試行してください。"
        } else if detail.contains("Another diagnostic") {
            errorMessage = "別の操作が実行中です。少し待ってから再試行してください。"
        } else { errorMessage = "操作を完了できませんでした。診断画面で詳細を確認できます。" }
        if changed { Task { await worker.log("error", detail) } }
    }

    func setAutomatic(_ enabled: Bool) {
        guard !busy else { return }
        if enabled {
            guard automaticReady else { settings(.automation); return }
            errorMessage = nil; errorDetail = nil
            resumeAt = now() + 2
            consensus.reset(until: resumeAt)
            mainConsensus.reset()
            nextMainCheck = 0
        } else { consensus.reset() }
        preferences.automatic = enabled
        automaticPauseReason = nil
        retryDelay = 15
        readGeneration += 1
        persist()
        Task { await worker.log("automatic", enabled ? "enabled" : "disabled") }
    }

    func setAutomaticMainDisplay(_ enabled: Bool) {
        guard !busy else { return }
        perform("メイン画面の自動切替を設定しています…", manual: false) {
            if enabled, self.profile?.zowieMacInput?.verified != true {
                self.profile = try await self.worker.registerMainInput()
            }
            self.preferences.automaticMainDisplay = enabled
            self.persist()
            self.nextMainCheck = 0
            self.mainAvailability = nil
            self.notice = enabled ? "Dellを優先し、使用できないときは確認できたZOWIEへ切り替えます。" : "保存したメイン画面を使用します。"
        }
    }

    func registerMainInput() {
        perform("ZOWIEのMac入力を登録しています…", manual: false) {
            self.profile = try await self.worker.registerMainInput()
            self.mainAvailability = nil
            self.nextMainCheck = 0
            self.notice = "ZOWIEのMac入力と電源状態を登録しました。"
        }
    }

    @discardableResult
    private func perform(_ title: String, manual: Bool = true, operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard !busy, !quitting else { return nil }
        busy = true; activity = title; dismissError(); notice = nil
        readGeneration += 1
        // Display notifications caused by our own transaction should only reset fresh samples.
        resumeAt = max(resumeAt, now() + (manual ? 30 : 15))
        if manual, preferences.automatic { automaticPauseReason = "オンを保持して手動操作を30秒間優先します" }
        consensus.reset(until: resumeAt)
        mainConsensus.reset()
        nextMainCheck = 0
        let generation = wakeGeneration
        let task = Task {
            do {
                try await operation()
                // The operation can span sleep; never consume its old input result.
                if !sleeping, generation == wakeGeneration {
                    let current = try await worker.status(readInput: true)
                    if !sleeping, generation == wakeGeneration { apply(current) }
                }
            } catch {
                if let stored = try? await worker.profile() { profile = stored }
                if !sleeping, generation == wakeGeneration {
                    recoveryPending = true
                    present(error)
                    deferRetry("オンを保持して画面の復旧を再試行します")
                }
            }
            busy = false; activity = ""
        }
        operationTask = task
        return task
    }

    func single() {
        guard initialized else { settings(.diagnostics); return }
        perform("Dellを非表示にしています…") { self.apply(try await self.worker.single(self.strategy), readInput: false); self.notice = "ZOWIEのみで作業できます。" }
    }
    func dual() {
        perform("デュアル構成に戻しています…") {
            self.apply(try await self.worker.dual(), readInput: false)
            if self.preferences.automaticMainDisplay {
                let current = try await self.worker.status(readInput: true)
                let available = try await self.worker.mainAvailability(dellInput: current.value)
                if let target = available.preferred { self.apply(try await self.worker.mainDisplay(target), readInput: false) }
            }
            self.initialized = true; self.notice = "元の配置に戻しました。"
        }
    }
    func configure() {
        perform("接続情報と現在の配置を保存しています…") {
            self.profile = try await self.worker.configure(); self.initialized = true
            self.notice = "このデュアル構成を保存しました。"
        }
    }
    func changeStrategy(_ value: HideStrategy) {
        guard value != strategy else { return }
        perform("非表示方法を変更しています…") {
            _ = try await self.worker.dual()
            self.profile = try await self.worker.strategy(value)
            self.notice = "非表示方法を変更しました。入力を再登録してください。"
        }
    }
    func calibrate(_ source: InputSource) {
        perform("\(source.title)の通信と復帰を確認しています…") {
            self.profile = try await self.worker.calibrate(source)
            self.notice = "\(source.title)の登録が完了しました。"
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            if loginStatus == .requiresApproval { notice = "システム設定の「ログイン項目」でInputBridgeを許可してください。" }
        } catch { loginStatus = SMAppService.mainApp.status; present(error) }
    }

    func setShortcuts(enabled: Bool? = nil, preset: ShortcutPreset? = nil) {
        let previous = preferences
        preferences.shortcuts = enabled ?? preferences.shortcuts
        preferences.shortcutPreset = preset ?? preferences.shortcutPreset
        do {
            try hotkeys.configure(enabled: preferences.shortcuts, preset: preferences.shortcutPreset)
            shortcutError = nil; persist()
        } catch {
            preferences = previous
            try? hotkeys.configure(enabled: previous.shortcuts, preset: previous.shortcutPreset)
            shortcutError = "ショートカットが他のアプリと競合しています。別の修飾キーを選択してください。"
            Task { await worker.log("shortcut-error", error.localizedDescription) }
        }
    }
    private func updateHotkeys() {
        hotkeys.onAction = { [weak self] id in
            guard let self else { return }
            Task { await self.worker.log("shortcut", "Action \(id)") }
            switch id { case 1: self.single(); case 2, 3: self.dual(); default: break }
        }
        setShortcuts()
    }

    private func startMonitoring() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                do { try await self.worker.heartbeat() } catch {
                    guard !self.busy, !self.sleeping, !self.quitting,
                          !self.recoveryPending, self.now() >= self.resumeAt else { continue }
                    self.recoveryPending = true
                    self.present(error)
                    self.deferRetry("オンを保持して復旧監視を再確認しています")
                }
            }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self else { return }
                await self.pollOnce()
            }
        }
    }

    // This schedules a retry; it never changes the user's saved on/off choice.
    private func deferRetry(_ reason: String) {
        let changed = automaticPauseReason != reason
        if preferences.automatic { automaticPauseReason = reason }
        resumeAt = max(resumeAt, now() + retryDelay)
        retryDelay = min(retryDelay * 2, 60)
        readGeneration += 1
        consensus.reset(until: resumeAt)
        mainConsensus.reset()
        nextMainCheck = 0
        if changed { Task { await worker.log("automatic-waiting", reason) } }
    }

    func pollOnce() async {
        guard !busy, !sleeping, !quitting, now() >= resumeAt else { return }
        if !initialized { await initializeRuntime(); return }
        if recoveryPending { await recoverWhenReady(); return }
        let readInput = preferences.automatic || now() >= nextRead
        let generation = readGeneration
        do {
            let current = try await worker.status(readInput: readInput)
            // Sleep, screen changes and manual operations invalidate in-flight reads.
            guard !busy, !sleeping, !quitting, generation == readGeneration else { return }
            apply(current, readInput: readInput)
            guard preferences.automatic, readInput, let profile, profile.ready else { return }
            if preferences.automaticMainDisplay, now() >= nextMainCheck {
                let availability = try await worker.mainAvailability(dellInput: current.value)
                guard !busy, !sleeping, !quitting, generation == readGeneration else { return }
                mainAvailability = availability
                nextMainCheck = now() + 5
                if let target = mainConsensus.ingest(availability.preferred, at: now()),
                   current.mode == .dual, current.mainDisplay != target {
                    let task = perform("使用できる画面をメインにしています…", manual: false) {
                        _ = try await self.worker.mainDisplay(target)
                    }
                    await task?.value
                    return
                }
            }
            if preferences.automaticMainDisplay, let available = mainAvailability {
                // Keep monitoring the usable screen without re-enabling or restoring
                // an off/unreachable monitor merely because it disappeared from Quartz.
                if available.zowie == .available,
                   [.poweredOff, .disconnected, .unknown].contains(available.dell) { return }
                if available.dell == .available, available.zowie != .available { return }
            }
            guard current.protected, current.mode != .unavailable else {
                recoveryPending = true
                deferRetry("オンを保持してディスプレイの再接続を待っています")
                return
            }
            switch consensus.ingest(value: current.value, profile: profile, at: now()) {
            case .wait: break
            case .unreadable:
                // Power-off may also remove DDC. Allow the independent main-display
                // checks to confirm the usable fallback before restoring a layout.
                if preferences.automaticMainDisplay, current.mode == .dual,
                   let target = mainAvailability?.preferred, target != current.mainDisplay { return }
                recoveryPending = true
                deferRetry("オンを保持してDellの入力通信を再確認しています")
            case .unknown:
                if preferences.automaticMainDisplay, current.mode == .dual,
                   let target = mainAvailability?.preferred, target != current.mainDisplay { return }
                recoveryPending = true
                deferRetry("オンを保持中です。未登録の入力を再確認しています")
            case .input(let source):
                automaticPauseReason = nil
                retryDelay = 15
                dismissError()
                if preferences.automaticMainDisplay {
                    guard mainAvailability?.preferred != nil,
                          source != .hdmi || mainAvailability?.zowie == .available else {
                        deferRetry("オンを保持してMacで使用できる画面を待っています")
                        return
                    }
                }
                let needsSwitch = source == .usbC ? current.mode != .dual : current.mode == .dual
                if needsSwitch {
                    consensus.didSwitch(at: now())
                    let task = perform("入力に合わせて切り替えています…", manual: false) {
                        if source == .usbC {
                            if current.mode != .dual { _ = try await self.worker.dual() }
                            if self.preferences.automaticMainDisplay {
                                let restored = try await self.worker.status(readInput: true)
                                let available = try await self.worker.mainAvailability(dellInput: restored.value)
                                self.mainAvailability = available
                                if let target = available.preferred { _ = try await self.worker.mainDisplay(target) }
                            }
                        }
                        else { _ = try await self.worker.single(profile.strategy) }
                    }
                    await task?.value
                }
            }
        } catch {
            guard !busy, !sleeping, !quitting, generation == readGeneration else { return }
            present(error)
            if preferences.automatic {
                recoveryPending = true
                deferRetry("オンを保持して接続状態を再確認しています")
            }
        }
    }

    private func recoverWhenReady() async {
        busy = true; activity = "接続が安定した画面を復旧しています…"
        let generation = wakeGeneration
        do {
            let current = try await worker.dual()
            if !sleeping, !quitting, generation == wakeGeneration {
                apply(current, readInput: false)
                recoveryPending = false
                // Require fresh input readings after the recovery transaction settles.
                resumeAt = max(resumeAt, now() + 10)
                consensus.reset(until: resumeAt)
                mainConsensus.reset()
                nextMainCheck = 0
                await worker.log("automatic-recovered", "Saved on/off preference retained; fresh input readings required")
            }
        } catch {
            if !sleeping, !quitting, generation == wakeGeneration {
                present(error)
                deferRetry("オンを保持して画面の復旧を再試行します")
            }
        }
        busy = false; activity = ""
    }

    private func installNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.didSleep() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.didWake() }
            })
        }
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.loginStatus = SMAppService.mainApp.status }
        })
    }
    func didSleep() {
        sleeping = true
        readGeneration += 1; wakeGeneration += 1
        consensus.reset()
        mainConsensus.reset()
        nextMainCheck = 0
        lastValue = nil
        mainAvailability = nil
        Task { await worker.log("sleep", "Monitoring paused; saved on/off preference retained") }
    }

    func didWake() {
        sleeping = false
        readGeneration += 1; wakeGeneration += 1
        recoveryPending = true
        resumeAt = max(resumeAt, now() + 20)
        consensus.reset(until: resumeAt)
        mainConsensus.reset()
        nextMainCheck = 0
        lastValue = nil
        mainAvailability = nil
        if preferences.automatic { automaticPauseReason = "オンを保持してスリープ復帰後の接続を待っています" }
        Task { await worker.log("wake", "Waiting before recovery; saved on/off preference retained") }
    }

    func screenParametersChanged() {
        readGeneration += 1
        resumeAt = max(resumeAt, now() + 10)
        consensus.reset(until: resumeAt)
        mainConsensus.reset()
        nextMainCheck = 0
        Task { await worker.log("display-change", "Waiting for displays to settle") }
    }

    func prepareToQuit() {
        guard !quitting else { return }
        guard !busy else { errorMessage = "操作が完了してから終了してください。"; onQuitComplete?(false); return }
        quitting = true; busy = true; activity = "元の構成へ戻して終了しています…"
        // Quitting pauses the worker, but the user's automatic-mode preference
        // must survive relaunch/login and temporary failures.
        consensus.reset()
        mainConsensus.reset()
        nextMainCheck = 0
        Task {
            do {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery.json").path) { _ = try await worker.dual() }
                monitorTask?.cancel(); heartbeatTask?.cancel(); hotkeys.unregister()
                await worker.log("quit", "Dual display arrangement restored")
                onQuitComplete?(true)
            } catch { quitting = false; busy = false; activity = ""; present(error); settings(.diagnostics); onQuitComplete?(false) }
        }
    }

    func openLogs() {
        let path = root.appendingPathComponent("events.jsonl")
        if FileManager.default.fileExists(atPath: path.path) { NSWorkspace.shared.open(path) }
        else { NSWorkspace.shared.open(root) }
    }
    func openDisplaySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
}
