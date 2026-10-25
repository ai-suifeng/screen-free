import AVFoundation
import AppKit
import ApplicationServices
import Observation

@Observable
final class Permissions {
    static let shared = Permissions()

    enum State { case granted, denied, unknown }

    private(set) var screen: State = .unknown
    private(set) var accessibility: State = .unknown
    private(set) var microphone: State = .unknown
    private(set) var camera: State = .unknown

    var canRecord: Bool { screen == .granted }

    private init() { refresh() }

    func refresh() {
        screen = CGPreflightScreenCaptureAccess() ? .granted : .denied
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        microphone = Self.state(for: .audio)
        camera = Self.state(for: .video)
    }

    private static func state(for type: AVMediaType) -> State {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            open("Privacy_ScreenCapture")
        }
        refresh()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("Privacy_Accessibility")
        }
        refresh()
    }

    func requestMicrophone() { request(.audio, pane: "Privacy_Microphone") }
    func requestCamera() { request(.video, pane: "Privacy_Camera") }

    private func request(_ type: AVMediaType, pane: String) {
        if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
            AVCaptureDevice.requestAccess(for: type) { _ in
                DispatchQueue.main.async { self.refresh() }
            }
        } else {
            open(pane)
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
