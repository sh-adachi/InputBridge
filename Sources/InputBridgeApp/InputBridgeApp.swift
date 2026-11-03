import AppKit
import SwiftUI
import Combine
import Carbon
import BridgeCore

@main
struct InputBridgeApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var model: AppModel!
    private var subscription: AnyCancellable?
    private var approvedTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }),
           let url = existing.bundleURL {
            // A Dock tile can point to another copy of this bundle. Send the open
            // request to the running copy so its reopen handler shows settings.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { NSLog("InputBridge reopen failed: %@", error.localizedDescription) }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        installMenu()
        model = AppModel()
        model.showSettings = { [weak self] in self?.showPreferences() }
        model.onReady = { [weak self] in
            guard let self else { return }
            if !launchedAtLogin || !self.model.preferences.welcomed { self.showPreferences() }
        }
        model.onQuitComplete = { [weak self] success in
            guard let self else { return }
            self.approvedTermination = success
            NSApp.reply(toApplicationShouldTerminate: success)
            if !success {
                self.showPreferences()
                let alert = NSAlert()
                alert.messageText = "Dellの復旧を確認できませんでした"
                alert.informativeText = "\(self.model.errorMessage ?? "DellのUSB-C接続を確認してください。")\n\n終了しても保存した構成は残り、次回起動時に復旧を試みます。"
                alert.addButton(withTitle: "アプリを開いたままにする")
                alert.addButton(withTitle: "復旧せず終了")
                if alert.runModal() == .alertSecondButtonReturn { self.approvedTermination = true; NSApp.terminate(nil) }
            }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "InputBridge")
            button.image?.isTemplate = true
            button.target = self; button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("InputBridgeStatus")
            button.setAccessibilityLabel("InputBridge")
        }
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 455)
        let hosting = NSHostingController(rootView: MenuContent(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                self.statusItem?.button?.toolTip = "InputBridge — \(model.mode.title)"
            }
        }
        model.start()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "InputBridgeについて", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let displayMenu = appMenu.addItem(withTitle: "画面切替メニュー", action: #selector(togglePopover), keyEquivalent: "m")
        displayMenu.keyEquivalentModifierMask = [.command, .shift]
        displayMenu.target = self
        appMenu.addItem(withTitle: "設定…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "InputBridgeを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); popover.contentViewController?.view.window?.makeKey() }
    }

    @objc func showPreferences() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "InputBridge 設定"
            window.identifier = NSUserInterfaceItemIdentifier("InputBridgeSettings")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsContent(model: model))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "Mac miniと2台のディスプレイのために。\nMIT License · AppleSiliconDDC by @waydabber\n\nディスプレイの設定操作はDellだけに限定しています。")])
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedTermination || model == nil { return .terminateNow }
        if model.busy { model.errorMessage = "操作が完了してから終了してください。"; return .terminateCancel }
        model.prepareToQuit()
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model != nil { showPreferences() }
        return true
    }
}
