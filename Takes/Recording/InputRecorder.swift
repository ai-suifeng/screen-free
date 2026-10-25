import AppKit

/// Captures mouse position, clicks and shortcut keys system-wide.
/// Callbacks arrive on the main thread with timestamps in system uptime seconds,
/// which matches the host clock used by ScreenCaptureKit sample buffers.
final class InputRecorder {
    struct Click {
        var time: TimeInterval
        /// CG global coordinates.
        var location: CGPoint
        var right: Bool
        var flags: NSEvent.ModifierFlags
    }

    var onMove: ((TimeInterval, CGPoint) -> Void)?
    var onClick: ((Click) -> Void)?
    var onMouseUp: ((TimeInterval, CGPoint) -> Void)?
    var onKey: ((TimeInterval, String) -> Void)?
    var onFrontApp: ((String) -> Void)?

    var recordAllKeys = false

    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastLocation: CGPoint?
    private var appObserver: NSObjectProtocol?

    func start() {
        stop()
        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: { [weak self] e in self?.handleMouse(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.handleKey(e) }) {
            monitors.append(m)
        }
        // 60 Hz position sampling gives a steadier track than raw mouseMoved events.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let name = app.localizedName, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.onFrontApp?(name)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            onFrontApp?(front)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        lastLocation = nil
    }

    private func sample() {
        let p = NSEvent.mouseLocation.cocoaToCG
        if let last = lastLocation, abs(last.x - p.x) < 0.25, abs(last.y - p.y) < 0.25 { return }
        lastLocation = p
        onMove?(ProcessInfo.processInfo.systemUptime, p)
    }

    private func handleMouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation.cocoaToCG
        switch e.type {
        case .leftMouseUp:
            onMouseUp?(e.timestamp, p)
        default:
            onClick?(Click(time: e.timestamp, location: p, right: e.type == .rightMouseDown, flags: e.modifierFlags))
        }
    }

    private func handleKey(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let isShortcut = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard isShortcut || recordAllKeys else { return }
        onKey?(e.timestamp, KeyFormatter.describe(e))
    }
}

enum KeyFormatter {
    static func describe(_ e: NSEvent) -> String {
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyName(e)
        return s
    }

    private static func keyName(_ e: NSEvent) -> String {
        switch e.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "esc"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        default:
            let chars = e.charactersIgnoringModifiers ?? ""
            return chars.uppercased()
        }
    }
}
