import SwiftUI
import AppKit
import ServiceManagement
import BridgeCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, automation, shortcuts, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self { case .general: return "一般"; case .automation: return "自動切替"; case .shortcuts: return "ショートカット"; case .diagnostics: return "診断とログ" }
    }
    var symbol: String {
        switch self { case .general: return "display.2"; case .automation: return "arrow.triangle.2.circlepath"; case .shortcuts: return "keyboard"; case .diagnostics: return "waveform.path.ecg" }
    }
}

struct DisplayDiagram: View {
    let mode: WorkspaceMode
    var compact = false
    var body: some View {
        HStack(alignment: .bottom, spacing: compact ? 22 : 38) {
            screen(name: "DELL", active: mode == .dual || mode == .mirrored, main: false)
            screen(name: "ZOWIE", active: true, main: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.title)
    }
    private func screen(name: String, active: Bool, main: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(active ? Color.blue.opacity(main ? 0.16 : 0.09) : Color.secondary.opacity(0.06))
                RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.blue.opacity(0.65) : Color.secondary.opacity(0.3), lineWidth: 1.5)
                if main { Image(systemName: "lock.fill").font(.system(size: compact ? 15 : 22)).foregroundColor(.blue) }
                else { Image(systemName: mode == .mirrored ? "rectangle.on.rectangle" : (active ? "checkmark" : "minus")).foregroundColor(active ? .blue : .secondary) }
            }
            .frame(width: compact ? 84 : 124, height: compact ? 50 : 73)
            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: compact ? 24 : 34, height: 3)
            Text(name).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.5).foregroundColor(.secondary)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "display.2").font(.system(size: 19, weight: .medium)).foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("InputBridge").font(.system(size: 15, weight: .semibold))
                    Text("いつものディスプレイ構成へ").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Button { model.settings() } label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain).help("設定を開く").accessibilityLabel("設定を開く")
            }
            VStack(spacing: 12) {
                DisplayDiagram(mode: model.mode, compact: true)
                Text(model.mode.title).font(.system(size: 17, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(model.status?.protected == true ? Color.green : Color.orange).frame(width: 5, height: 5)
                    Text(model.status?.protected == true ? "ZOWIEを保護中" : "接続を確認してください")
                    if let hz = model.status?.zowieHz { Text("· \(Int(hz.rounded())) Hz") }
                }.font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.vertical, 15).frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                modeButton("ZOWIEのみ", symbol: "display", suffix: "1", selected: model.mode == .single || model.mode == .mirrored, action: model.single)
                    .accessibilityIdentifier("single-display")
                modeButton("デュアル", symbol: "display.2", suffix: "2", selected: model.mode == .dual, action: model.dual)
                    .accessibilityIdentifier("dual-display")
            }.disabled(model.busy || !model.initialized)

            VStack(alignment: .leading, spacing: 5) {
                Toggle("入力に合わせて自動切替", isOn: Binding(get: { model.preferences.automatic }, set: model.setAutomatic))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(model.busy || !model.automaticReady)
                HStack(alignment: .top) {
                    Text(model.automaticDescription).font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    if !model.automaticReady { Button("入力を登録") { model.settings(.automation) }.buttonStyle(.link).font(.system(size: 10)) }
                }
            }

            if model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.activity).font(.system(size: 11)).foregroundColor(.secondary) }
            } else if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            HStack {
                Button { model.dual() } label: { Label("Dellを復旧", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("recover-display")
                Spacer()
                Button("設定") { model.settings() }.buttonStyle(.plain)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).padding(.leading, 10).help("元の構成へ戻して終了").accessibilityLabel("InputBridgeを終了")
            }.font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(18).frame(width: 380)
        .font(.system(size: 13)).tint(.blue)
    }
    private func modeButton(_ title: String, symbol: String, suffix: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                if model.preferences.shortcuts { Text(model.shortcutPrefix + suffix).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(selected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.blue.opacity(0.45) : Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain).foregroundColor(selected ? .blue : .primary)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3) }
            }
            content
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.12)))
    }
}

struct SettingsContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: "display.2").font(.system(size: 22)).foregroundColor(.blue)
                    Text("InputBridge").font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }.padding(.top, 24).padding(.bottom, 26).padding(.horizontal, 15)
                ForEach(SettingsTab.allCases) { tab in
                    Button { model.selectedTab = tab } label: {
                        Label(tab.title, systemImage: tab.symbol).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(model.selectedTab == tab ? Color.blue.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundColor(model.selectedTab == tab ? .blue : .primary)
                    }.buttonStyle(.plain).accessibilityIdentifier("tab-\(tab.rawValue)")
                }
                Spacer()
                Label("ZOWIEを保護", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundColor(.secondary).padding(14)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · 無料 / MIT").font(.system(size: 9)).foregroundColor(.secondary).padding(.horizontal, 14).padding(.bottom, 18)
            }
            .padding(.horizontal, 10).frame(width: 180).background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.selectedTab.title).font(.system(size: 25, weight: .bold))
                        Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary).lineSpacing(3)
                    }.padding(.bottom, 3)
                    feedback
                    switch model.selectedTab {
                    case .general: general
                    case .automation: automation
                    case .shortcuts: shortcuts
                    case .diagnostics: diagnostics
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity)
        }
        .frame(width: 790, height: 650).font(.system(size: 12)).tint(.blue)
    }
    private var subtitle: String {
        switch model.selectedTab {
        case .general: return "Dellの作業領域を切り替え、元の配置へ戻します。"
        case .automation: return "Dell本体のUSB-C / HDMI切替に、Macの構成を合わせます。"
        case .shortcuts: return "ほかのアプリを使用中でも、すぐに切り替えられます。"
        case .diagnostics: return "接続の確認、復旧、操作ログをまとめています。"
        }
    }
    @ViewBuilder private var feedback: some View {
        if model.busy {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.activity).font(.system(size: 12)) }
                .padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        } else if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack { Button("Dellを復旧", action: model.dual); Button("ディスプレイ設定", action: model.openDisplaySettings) }.controlSize(.small)
                }
                Spacer(minLength: 0)
                Button(action: model.dismissError) { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("エラー表示を閉じる")
            }.padding(13).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        } else if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
    private var general: some View {
        VStack(spacing: 18) {
            SettingsCard("現在の構成") {
                DisplayDiagram(mode: model.mode).padding(.vertical, 10)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.mode.title).font(.system(size: 16, weight: .semibold))
                        Text("保存した配置で、ZOWIEがメイン画面").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let hz = model.status?.zowieHz { Text("ZOWIE \(Int(hz.rounded())) Hz").font(.system(size: 10, weight: .medium)).padding(7).background(Color.green.opacity(0.09), in: Capsule()) }
                }
                Divider()
                HStack(spacing: 10) {
                    Button(action: model.single) { Label("ZOWIEのみ", systemImage: "display").frame(maxWidth: .infinity) }
                        .accessibilityIdentifier("settings-single")
                    Button(action: model.dual) { Label("デュアルに戻す", systemImage: "display.2").frame(maxWidth: .infinity) }
                        .accessibilityIdentifier("settings-dual")
                }.buttonStyle(.bordered).controlSize(.large).disabled(model.busy || !model.initialized)
            }
            SettingsCard("起動", subtitle: "終了時は保存したデュアル構成へ戻します。") {
                Toggle("ログイン時にInputBridgeを起動", isOn: Binding(get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval }, set: model.setLogin))
                    .toggleStyle(.switch).controlSize(.small)
                if model.loginStatus == .requiresApproval {
                    Button("ログイン項目の設定を開く") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                }
            }
            Text("本体の入力は変更しません。USB-C専用で使う場合は、手動切替だけで利用できます。")
                .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var automation: some View {
        VStack(spacing: 18) {
            SettingsCard("自動切替", subtitle: model.automaticDescription) {
                Toggle("入力に合わせて自動切替する", isOn: Binding(get: { model.preferences.automatic }, set: model.setAutomatic))
                    .toggleStyle(.switch).disabled(!model.automaticReady || model.busy)
                HStack(spacing: 8) {
                    Label("USB-C → デュアル", systemImage: "display.2")
                    Spacer()
                    Label(model.strategy == .mirror ? "HDMI → ZOWIEのみ（複製）" : "HDMI → ZOWIEのみ", systemImage: "display")
                }.font(.system(size: 10)).foregroundColor(.secondary)
                statusRow("現在のDellの入力", value: model.inputTitle)
            }
            SettingsCard("入力を登録", subtitle: "Dell本体を対象の入力に切り替えてから登録します。約10秒間Dellのみを非表示にして、通信と元の配置への復帰を確認します。") {
                calibrationRow(.usbC, point: model.profile?.usbC)
                Divider()
                calibrationRow(.hdmi, point: model.profile?.hdmi)
                Text("HDMIはSwitch 2を接続している端子で登録してください。異なる値と通信継続が確認できた場合に、自動切替を利用できます。")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineSpacing(3)
            }
            SettingsCard("Dellの非表示方法", subtitle: "Switchの電源オフから戻す用途には「ZOWIEをDellに複製」を推奨します。方法を変更すると入力の再登録が必要です。") {
                Picker("方法", selection: Binding(get: { model.strategy }, set: model.changeStrategy)) {
                    ForEach(HideStrategy.allCases, id: \.self) { strategy in Text(strategy.title).tag(strategy) }
                }.labelsHidden().disabled(model.busy || !model.initialized)
                Text(model.strategy == .mirror
                     ? "USB-Cの映像信号を残し、Macの作業領域を1つにします。Dell本体がUSB-Cへ戻ると元のデュアル構成に復帰します。"
                     : "無効化はUSB-Cの映像信号も止めるため、Switchを切ってもDellがHDMIのまま戻らない場合があります。")
                    .font(.system(size: 10)).foregroundColor(model.strategy == .mirror ? .secondary : .orange).lineSpacing(3)
            }
            Text("手動操作すると自動切替はオフになります。スリープ復帰後はデュアルへ戻し、接続が安定してから新しい入力値で再判定します。")
                .font(.system(size: 10)).foregroundColor(.secondary).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func calibrationRow(_ input: InputSource, point: CalibrationPoint?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: input == .usbC ? "cable.connector" : "tv").font(.system(size: 18)).foregroundColor(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(input.title).font(.system(size: 12, weight: .medium))
                if let point { Text("\(point.verified ? "登録済み" : "再確認が必要") · \(String(format: "0x%04X", point.value))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
                else { Text("未登録").font(.system(size: 10)).foregroundColor(.secondary) }
            }
            Spacer()
            if point?.verified == true { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).accessibilityLabel("検証済み") }
            Button(point == nil ? "\(input.title)を登録" : "再登録") { model.calibrate(input) }.controlSize(.small).disabled(model.busy || !model.initialized)
                .accessibilityIdentifier("calibrate-\(input.rawValue)")
        }.padding(.vertical, 3)
    }
    private var shortcuts: some View {
        VStack(spacing: 18) {
            SettingsCard("キーボードショートカット", subtitle: "修飾キーと数字キーを同時に押します。アクセシビリティへのアクセス許可は不要です。") {
                Toggle("グローバルショートカットを使う", isOn: Binding(get: { model.preferences.shortcuts }, set: { model.setShortcuts(enabled: $0) })).toggleStyle(.switch)
                Picker("修飾キー", selection: Binding(get: { model.preferences.shortcutPreset }, set: { model.setShortcuts(preset: $0) })) {
                    ForEach(ShortcutPreset.allCases, id: \.self) { preset in Text(preset.title).tag(preset) }
                }.disabled(!model.preferences.shortcuts)
                Divider()
                shortcutRow("ZOWIEのみ", suffix: "1")
                shortcutRow("デュアルに戻す", suffix: "2")
                shortcutRow("Dellを復旧", suffix: "0")
                if let error = model.shortcutError { Text(error).font(.system(size: 11)).foregroundColor(.orange) }
            }
            Text("ほかのアプリと重なる場合は修飾キーを変更してください。画面の切替中は連続した操作を受け付けません。")
                .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func shortcutRow(_ title: String, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(model.shortcutPrefix + suffix).font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        }.opacity(model.preferences.shortcuts ? 1 : 0.45)
    }
    private var diagnostics: some View {
        VStack(spacing: 18) {
            SettingsCard("ディスプレイ") {
                statusRow("ZOWIE XL2546K", value: model.status?.protected == true ? "メイン画面 · 保護中" : "接続・メイン画面を確認")
                statusRow("Dell S2725QC", value: model.mode == .dual ? "拡張表示" : model.mode == .single ? "非表示" : model.mode == .mirrored ? "ZOWIEの複製" : "未確認")
                statusRow("Dellの入力", value: model.inputTitle)
                if let value = model.lastValue { statusRow("入力値", value: String(format: "0x%04X", value)) }
                if let date = model.lastRead { HStack { Text("最終確認"); Spacer(); Text(date, style: .time) }.foregroundColor(.secondary).font(.system(size: 10)) }
                Divider()
                Button("接続情報を再取得して現在の配置を保存", action: model.configure).disabled(model.busy)
                    .accessibilityIdentifier("refresh-configuration")
                Text("配線や画面の配置を変更したときに使用します。Dellが非表示なら、先に保存したデュアル構成へ戻します。")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineSpacing(3)
            }
            SettingsCard("手動復旧", subtitle: "保存したDellの解像度・周波数・位置へ戻します。戻らない場合はDellをUSB-C入力にして、USB-Cケーブルを抜き差ししてください。") {
                HStack { Button("Dellを復旧", action: model.dual).disabled(model.busy); Button("ディスプレイ設定", action: model.openDisplaySettings) }
            }
            SettingsCard("ログ", subtitle: "エラーと切替履歴はこのMacに保存されます。") {
                HStack { Button("操作ログを開く", action: model.openLogs); Button("保存フォルダを開く") { NSWorkspace.shared.open(model.root) } }
                if let detail = model.errorDetail {
                    Text(detail).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("無効化はmacOSの内部APIを使用しています。OS更新後に動作が変わった場合は、再登録または手動復旧を使用してください。")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineSpacing(3)
            }
        }
    }
    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title); Spacer(minLength: 12); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
}
