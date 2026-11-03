import Foundation
import BridgeCore
import Darwin
import MachO

let help = """
InputBridge — S2725QC / ZOWIE 安全診断 CLI (macOS 13+, Apple Silicon)
  inventory                          接続情報のみ表示
  configure                          DellとZOWIEの実機IDを保存（画面変更なし）
  sample --label usb-c|hdmi           現在の本体入力を読み取り記録
         [--count 5] [--interval 2]
  watch [--seconds 60] [--interval 2] 読み取り専用の監視（画面変更なし）
  probe-zowie [--count 3]            ZOWIEの0x60を読み取り（画面変更なし）
              [--interval 2]        Dell校正とは別ファイルへ保存
  test --mode disable|mirror          Dellを一時変更しDDC確認後に復元
       --label usb-c|hdmi [--seconds 10]
  recover                            保存した構成へ復旧
  evaluate                           測定結果と未確認の条件を表示
全コマンド: [--workspace PATH]        保存先（既定: ./Diagnostics）
入力切替はDell本体で行います。SetVCPは送信しません。
testは画面構成を一時変更します。ZOWIEをメイン画面にしてください。
復元できない構成ではDellのUSB-C抜き差しが必要になる場合があります。
"""

do {
    var args = Array(CommandLine.arguments.dropFirst())
    let command = args.isEmpty ? "help" : args.removeFirst()
    if ["help", "--help", "-h"].contains(command) { print(help); exit(0) }
    var options: [String: String] = [:]
    while !args.isEmpty {
        guard args.count >= 2, args[0].hasPrefix("--"), options[args[0]] == nil else { throw BridgeError("Invalid/duplicate option. Use --help") }
        let key = args.removeFirst(); options[key] = args.removeFirst()
    }
    let permitted: [String: Set<String>] = ["inventory": [], "configure": [], "sample": ["--label", "--count", "--interval"], "watch": ["--seconds", "--interval"], "probe-zowie": ["--count", "--interval"], "test": ["--mode", "--label", "--seconds"], "recover": [], "evaluate": [], "_watchdog": ["--token", "--seconds"], "_session-watchdog": ["--token", "--owner"]]
    guard let allowed = permitted[command], Set(options.keys).subtracting(allowed.union(["--workspace"])).isEmpty else { throw BridgeError("Unknown command/option. Use --help") }
    let root = URL(fileURLWithPath: options["--workspace"] ?? "Diagnostics", isDirectory: true).standardizedFileURL
    // Bundle.main.executableURL can point at the GUI executable when this CLI lives
    // in Contents/MacOS. Resolve the actual running image, including PATH launches.
    var pathSize: UInt32 = 0
    _NSGetExecutablePath(nil, &pathSize)
    var executablePath = [CChar](repeating: 0, count: Int(pathSize))
    guard _NSGetExecutablePath(&executablePath, &pathSize) == 0 else { throw BridgeError("Cannot resolve executable path") }
    let executable = URL(fileURLWithPath: String(cString: executablePath)).standardizedFileURL.resolvingSymlinksInPath()
    let diagnostics = Diagnostics(root: root, executable: executable)
    func integer(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let n = Int(options[key] ?? String(value)), range.contains(n) else { throw BridgeError("Invalid \(key): allowed \(range)") }
        return n
    }
    func label() throws -> String {
        guard let label = options["--label"], ["usb-c", "hdmi"].contains(label) else { throw BridgeError("--label usb-c|hdmi required: use the physical input shown in Dell OSD") }
        return label
    }
    if command == "_watchdog" || command == "_session-watchdog" {
        // Survive Ctrl-C/terminal closure of the diagnostic parent. No elevated helper or daemon.
        _ = setsid()
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        guard let token = options["--token"] else { throw BridgeError("Token required") }
        if command == "_watchdog" { try diagnostics.watchdog(token: token, seconds: integer("--seconds", default: 22, range: 1...45)) }
        else {
            let owner = try integer("--owner", default: 0, range: 2...Int(Int32.max))
            try RuntimeController(root: root, executable: executable).watchSession(token: token, owner: Int32(owner))
        }
        exit(0)
    }
    let lock = try WorkspaceLock(root: root)
    defer { withExtendedLifetime(lock) {} }
    switch command {
    case "inventory": print(try JSON.string(diagnostics.inventory()))
    case "configure": print(try JSON.string(diagnostics.configure()))
    case "probe-zowie":
        let count = try integer("--count", default: 3, range: 1...60)
        let interval = try integer("--interval", default: 2, range: 1...10), run = UUID().uuidString
        var valid = true
        for index in 0..<count {
            let observation = try diagnostics.probeZowie(run: run)
            print(try JSON.string(observation)); valid = valid && observation.reading?.valid == true
            if index + 1 < count { Thread.sleep(forTimeInterval: Double(interval)) }
        }
        if !valid { exit(2) }
    case "sample":
        let input = try label(), count = try integer("--count", default: 5, range: 3...60)
        let interval = try integer("--interval", default: 2, range: 1...10), run = UUID().uuidString
        let config = try diagnostics.configuration()
        let dell = try Displays.resolve(config.dell), zowie = try Displays.resolve(config.zowie)
        try Safety.preflight(dell: dell, zowie: zowie)
        guard dell.active && !dell.inMirrorSet else { throw BridgeError("Restore extended layout before calibration") }
        var valid = true
        for index in 0..<count {
            let observation = try diagnostics.observe(label: input, run: run)
            print(try JSON.string(observation)); valid = valid && observation.reading?.valid == true
            if index + 1 < count { Thread.sleep(forTimeInterval: Double(interval)) }
        }
        if !valid { exit(2) }
    case "watch":
        let seconds = try integer("--seconds", default: 60, range: 1...86400)
        let interval = try integer("--interval", default: 2, range: 1...30), run = UUID().uuidString
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        repeat {
            print(try JSON.string(diagnostics.observe(label: "unknown", phase: "watch", run: run)))
            Thread.sleep(forTimeInterval: Double(interval))
        } while ProcessInfo.processInfo.systemUptime < deadline
    case "test":
        let result = try diagnostics.test(mode: options["--mode"] ?? "", label: label(), seconds: integer("--seconds", default: 10, range: 5...30))
        print(try JSON.string(result))
        if result.error != nil || !result.restored || !result.ddcReadable || (!result.protectedUnchanged && result.protectedTimingAdjusted != true) || !result.mutationObserved { exit(2) }
    case "recover": try diagnostics.recover(); print("復旧を確認しました（保留中の復旧がなければ変更なし）。")
    case "evaluate": print(try JSON.string(diagnostics.evaluate()))
    default: throw BridgeError("Unknown command")
    }
} catch {
    FileHandle.standardError.write(Data("InputBridge: \(error.localizedDescription)\n".utf8))
    exit(1)
}
