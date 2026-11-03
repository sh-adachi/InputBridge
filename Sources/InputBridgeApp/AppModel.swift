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
}

actor DisplayWorker {
    let controller: RuntimeController
    init(root: URL, executable: URL) { controller = RuntimeController(root: root, executable: executable) }
    func initialize(seed: URL?) throws -> CalibrationProfile { try controller.initialize(seed: seed) }
    func status(readInput: Bool = true) throws -> RuntimeStatus { try controller.status(readInput: readInput) }
    func single(_ strategy: HideStrategy) throws -> RuntimeStatus { try controller.switchToSingle(strategy: strategy) }
    func dual() throws -> RuntimeStatus { try controller.restoreDual() }
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
    @Published var shortcutError: String?
    let root: URL
    let worker: DisplayWorker
    var showSettings: (() -> Void)?
    var onReady: (() -> Void)?
    var onQuitComplete: ((Bool) -> Void)?
    private let preferencesURL: URL
    private let hotkeys = HotKeyManager()
    private var monitorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var consensus = InputConsensus()
    private var nextRead: TimeInterval = 0
    private var resumeAt: TimeInterval = 0
    private var observerTokens: [NSObjectProtocol] = []
    private var quitting = false

    init() {
        if let override = ProcessInfo.processInfo.environment["INPUTBRIDGE_DATA_DIR"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InputBridge", isDirectory: true)
        }
        preferencesURL = root.appendingPathComponent("preferences.json")
        preferences = (try? JSON.load(Preferences.self, preferencesURL)) ?? Preferences()
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/inputbridge")
        worker = DisplayWorker(root: root, executable: cli)
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
        if preferences.automatic && ProcessInfo.processInfo.systemUptime < resumeAt { return "画面の接続が安定するまで待機中" }
        if preferences.automatic { return "Dell本体の入力操作に追従します" }
        if automaticReady { return "手動操作を優先しています" }
        return "USB-CとHDMIを登録すると利用できます"
    }

    func start() {
        installNotifications()
        updateHotkeys()
        Task {
            do {
                profile = try await worker.initialize(seed: Bundle.main.url(forResource: "InitialCalibration", withExtension: "json"))
                apply(try await worker.status())
                initialized = true
                if !automaticReady { preferences.automatic = false }
                resumeAt = ProcessInfo.processInfo.systemUptime + 10
                consensus.reset(until: resumeAt)
                notice = "メニューバーから画面を切り替えられます。"
            } catch { present(error) }
            busy = false; activity = ""
            startMonitoring()
            onReady?()
            if !preferences.welcomed { preferences.welcomed = true; persist() }
        }
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
            nextRead = ProcessInfo.processInfo.systemUptime + (newStatus.readError == nil ? 5 : 15)
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
            errorMessage = "ZOWIEを有効なメイン画面にしてから再試行してください。"
        } else if detail.contains("Another diagnostic") {
            errorMessage = "別の操作が実行中です。少し待ってから再試行してください。"
        } else { errorMessage = "操作を完了できませんでした。診断画面で詳細を確認できます。" }
        if changed { Task { await worker.log("error", detail) } }
    }

    private func disableAutomatic() {
        preferences.automatic = false
        consensus.reset()
        persist()
    }

    func setAutomatic(_ enabled: Bool) {
        guard !busy else { return }
        if enabled {
            guard automaticReady else { settings(.automation); return }
            errorMessage = nil; errorDetail = nil
            resumeAt = ProcessInfo.processInfo.systemUptime + 2
            consensus.reset(until: resumeAt)
        } else { consensus.reset() }
        preferences.automatic = enabled
        persist()
        Task { await worker.log("automatic", enabled ? "enabled" : "disabled") }
    }

    private func perform(_ title: String, manual: Bool = true, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !quitting else { return }
        if manual { disableAutomatic() }
        busy = true; activity = title; dismissError(); notice = nil
        // Display notifications caused by our own transaction should only reset fresh samples.
        resumeAt = max(resumeAt, ProcessInfo.processInfo.systemUptime + (manual ? 10 : 15))
        consensus.reset(until: resumeAt)
        Task {
            do {
                try await operation()
                apply(try await worker.status())
            } catch {
                preferences.automatic = false; persist()
                if let stored = try? await worker.profile() { profile = stored }
                if let current = try? await worker.status(readInput: false) { apply(current, readInput: false) }
                present(error)
            }
            busy = false; activity = ""
        }
    }

    func single() {
        guard initialized else { settings(.diagnostics); return }
        perform("Dellを非表示にしています…") { self.apply(try await self.worker.single(self.strategy), readInput: false); self.notice = "ZOWIEのみで作業できます。" }
    }
    func dual() {
        perform("デュアル構成に戻しています…") { self.apply(try await self.worker.dual(), readInput: false); self.initialized = true; self.notice = "元の配置に戻しました。" }
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
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                do { try await self.worker.heartbeat() } catch {
                    if !self.busy, !self.sleeping { self.stopAutomatic("復旧監視を確認できなかったため、デュアル構成へ戻しました。") }
                    else { self.present(error) }
                }
            }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard !self.busy, !self.sleeping, !self.quitting, self.initialized else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= self.resumeAt else { continue }
                let readInput = self.preferences.automatic || now >= self.nextRead
                do {
                    let current = try await self.worker.status(readInput: readInput)
                    // An input callback/manual action may have started while this read was running.
                    guard !self.busy, !self.sleeping, !self.quitting else { continue }
                    self.apply(current, readInput: readInput)
                    guard self.preferences.automatic, readInput, let profile = self.profile else { continue }
                    guard current.protected, current.mode != .unavailable else { self.stopAutomatic("ZOWIEの表示またはDellの接続状態が変わったため、自動切替を停止しました。"); continue }
                    let decision = self.consensus.ingest(value: current.value, profile: profile, at: ProcessInfo.processInfo.systemUptime)
                    switch decision {
                    case .wait: break
                    case .unreadable: self.stopAutomatic("Dellの入力を読み取れなくなったため、自動切替を停止しました。")
                    case .unknown: self.stopAutomatic("未登録の入力値が続いたため、自動切替を停止しました。入力を再登録してください。")
                    case .input(let source):
                        let needsSwitch = source == .usbC ? current.mode != .dual : current.mode == .dual
                        if needsSwitch {
                            self.consensus.didSwitch(at: ProcessInfo.processInfo.systemUptime)
                            self.perform("入力に合わせて切り替えています…", manual: false) {
                                if source == .usbC { self.apply(try await self.worker.dual(), readInput: false) }
                                else { self.apply(try await self.worker.single(profile.strategy), readInput: false) }
                            }
                        }
                    }
                } catch {
                    if self.preferences.automatic { self.stopAutomatic("接続状態を確認できなくなったため、自動切替を停止しました。") }
                    else { self.present(error) }
                }
            }
        }
    }

    private func stopAutomatic(_ reason: String) {
        disableAutomatic()
        perform("デュアル構成へ復旧しています…", manual: false) {
            self.apply(try await self.worker.dual(), readInput: false)
            self.errorMessage = reason; self.errorDetail = nil
            await self.worker.log("automatic-stopped", reason)
        }
    }

    private func installNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        observerTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.consensus.reset() }
        })
        observerTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resumeAt = max(self.resumeAt, ProcessInfo.processInfo.systemUptime + 10)
                self.consensus.reset(until: self.resumeAt)
                await self.worker.log("display-change", "Waiting for displays to settle")
            }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.loginStatus = SMAppService.mainApp.status }
        })
    }
    private func didWake() {
        sleeping = false
        resumeAt = ProcessInfo.processInfo.systemUptime + 10
        consensus.reset(until: resumeAt)
        guard !busy, initialized else { return }
        perform("スリープ復帰後の画面を確認しています…", manual: false) {
            self.apply(try await self.worker.dual(), readInput: false)
            self.resumeAt = ProcessInfo.processInfo.systemUptime + 10
            self.consensus.reset(until: self.resumeAt)
        }
    }

    func prepareToQuit() {
        guard !quitting else { return }
        guard !busy else { errorMessage = "操作が完了してから終了してください。"; onQuitComplete?(false); return }
        quitting = true; busy = true; activity = "元の構成へ戻して終了しています…"
        // Quitting pauses the worker, but the user's automatic-mode preference
        // must survive relaunch/login. Manual display actions still turn it off.
        consensus.reset()
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
