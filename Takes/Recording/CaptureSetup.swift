import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// State of the capture bar: what to record and with which inputs.
@Observable
final class CaptureSetup {
    var mode: CaptureKind = .display
    private(set) var displays: [SCDisplay] = []
    var selectedDisplayID: CGDirectDisplayID?
    private(set) var windows: [SCWindow] = []
    var selectedWindow: SCWindow?
    var windowThumbnails: [CGWindowID: NSImage] = [:]
    /// Selected area: display plus rect in that display's points (top-left origin).
    var area: (displayID: CGDirectDisplayID, rect: CGRect)?
    var loadError: String?

    var microphones: [AVCaptureDevice] = []
    var cameras: [AVCaptureDevice] = []

    @MainActor
    func refresh() async {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified).devices
        cameras = CameraCapture.devices()
        do {
            let content = try await ShareableContent.fetch()
            displays = content.displays
            windows = ShareableContent.pickableWindows(content)
            if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                selectedDisplayID = mouseScreen?.displayID ?? displays.first?.displayID
            }
            loadError = nil
        } catch {
            loadError = "无法获取屏幕内容，请检查屏幕录制权限。"
        }
    }

    @MainActor
    func loadThumbnails() async {
        let config = SCStreamConfiguration()
        config.width = 480
        config.height = 300
        config.showsCursor = false
        config.scalesToFit = true
        for w in windows where windowThumbnails[w.windowID] == nil {
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let aspect = w.frame.width / max(w.frame.height, 1)
            config.width = Int(min(480, 300 * aspect))
            config.height = Int(min(300, 480 / aspect))
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                windowThumbnails[w.windowID] = NSImage(cgImage: image, size: .zero)
            }
        }
    }

    var target: CaptureTarget? {
        switch mode {
        case .display:
            return displays.first { $0.displayID == selectedDisplayID }.map(CaptureTarget.display)
        case .window:
            return selectedWindow.map(CaptureTarget.window)
        case .area:
            guard let area, let d = displays.first(where: { $0.displayID == area.displayID }) else { return nil }
            return .area(d, area.rect)
        }
    }

    var targetSummary: String {
        switch mode {
        case .display:
            guard let id = selectedDisplayID else { return "选择屏幕" }
            return NSScreen.screen(for: id)?.localizedName ?? "屏幕"
        case .window:
            guard let w = selectedWindow else { return "点击选择窗口" }
            return w.owningApplication?.applicationName ?? w.title ?? "窗口"
        case .area:
            guard let a = area else { return "拖拽选择区域" }
            return "\(Int(a.rect.width)) × \(Int(a.rect.height))"
        }
    }
}

extension AVCaptureDevice: @retroactive Identifiable {
    public var id: String { uniqueID }
}
