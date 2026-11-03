import Carbon
import AppKit
import Foundation
import BridgeCore

final class HotKeyManager {
    var onAction: (@MainActor (UInt32) -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var lastAction: (id: UInt32, time: TimeInterval)?

    func configure(enabled: Bool, preset: ShortcutPreset) throws {
        unregister()
        guard enabled else { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard status == noErr, key.signature == 0x49425247 else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
                let id = key.id
                DispatchQueue.main.async { manager.fire(id) }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { throw BridgeError("Hotkey event handler: \(result)") }
        }
        let modifiers: UInt32
        switch preset {
        case .controlOptionCommand: modifiers = UInt32(controlKey | optionKey | cmdKey)
        case .controlOption: modifiers = UInt32(controlKey | optionKey)
        case .optionCommand: modifiers = UInt32(optionKey | cmdKey)
        }
        for (id, key) in [(UInt32(1), UInt32(kVK_ANSI_1)), (2, UInt32(kVK_ANSI_2)), (3, UInt32(kVK_ANSI_0))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x49425247, id: id), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            guard result == noErr, let reference else { unregister(); throw BridgeError("Global shortcut \(id) unavailable: \(result)") }
            references.append(reference)
        }
        // Local key events can bypass Carbon when a window receives accessibility
        // keyboard input. Keep the app's own windows consistent with global hotkeys.
        let required: NSEvent.ModifierFlags
        switch preset {
        case .controlOptionCommand: required = [.control, .option, .command]
        case .controlOption: required = [.control, .option]
        case .optionCommand: required = [.option, .command]
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.intersection([.control, .option, .command, .shift]) == required,
                  let id = [UInt16(kVK_ANSI_1): UInt32(1), UInt16(kVK_ANSI_2): UInt32(2), UInt16(kVK_ANSI_0): UInt32(3)][event.keyCode] else { return event }
            DispatchQueue.main.async { self.fire(id) }
            return nil
        }
    }
    @MainActor private func fire(_ id: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastAction?.id != id || now - (lastAction?.time ?? 0) > 0.4 else { return }
        lastAction = (id, now); onAction?(id)
    }
    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
}
