import AppKit

/// Menu bar icon. Plain AppKit: SwiftUI's MenuBarExtra re-renders on every animation frame
/// of other windows (the recording HUD), which starves the main thread.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private var timer: Timer?
    private var lastTitle = ""

    init(model: AppModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        update()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func update() {
        let session = model.session
        let recording = session.phase == .recording || session.phase == .paused
        let symbol = !recording ? "record.circle" : (session.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
        let title = recording ? " " + formatDuration(session.elapsed) : ""
        guard title + symbol != lastTitle else { return }
        lastTitle = title + symbol
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Takes")
        item.button?.imagePosition = .imageLeading
        item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let session = model.session
        if session.isActive {
            if session.phase == .paused {
                add(menu, "继续录制", "p") { session.resume() }
                add(menu, "删除上一段", "z") { session.redoTake() }
            } else {
                add(menu, "暂停", "p") { session.pause() }
                add(menu, "重录这一段", "z") { session.redoTake() }
            }
            add(menu, "标注工具", "d") { self.model.annotations.toggleDrawing() }
            add(menu, "结束录制", "r") { session.stop() }
            menu.addItem(.separator())
            add(menu, "放弃本次录制", nil) { session.discard() }
        } else {
            add(menu, "新录制…", "r") { self.model.showCaptureBar() }
            add(menu, "打开资料库", nil) { self.model.openLibrary() }
        }
        menu.addItem(.separator())
        add(menu, "设置…", nil) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        add(menu, "检查更新…", nil) {
            Task { @MainActor in await Updater.shared.check(userInitiated: true) }
        }
        add(menu, "退出 Takes", nil) { NSApp.terminate(nil) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ key: String?, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, action: action)
        if let key {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = [.command, .option]
        }
        menu.addItem(item)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
