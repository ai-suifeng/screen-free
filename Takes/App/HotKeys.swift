import Carbon
import AppKit

/// System-wide shortcuts via Carbon hot keys, which need no extra permission.
final class HotKeys {
    static let shared = HotKeys()

    struct Shortcut {
        let keyCode: UInt32
        let display: String
    }

    static let record = Shortcut(keyCode: UInt32(kVK_ANSI_R), display: "⌥⌘R")
    static let pause = Shortcut(keyCode: UInt32(kVK_ANSI_P), display: "⌥⌘P")
    static let redo = Shortcut(keyCode: UInt32(kVK_ANSI_Z), display: "⌥⌘Z")
    static let draw = Shortcut(keyCode: UInt32(kVK_ANSI_D), display: "⌥⌘D")

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        installIfNeeded()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54414B53), id: id) // 'TAKS'
        RegisterEventHotKey(shortcut.keyCode, UInt32(cmdKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
