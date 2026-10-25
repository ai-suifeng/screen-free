import Foundation
import Observation
import AppKit

enum HighlightTrigger: String, CaseIterable, Codable {
    case fn, option, controlOption

    var label: String {
        switch self {
        case .fn: "Fn (🌐)"
        case .option: "⌥ Option"
        case .controlOption: "⌃⌥"
        }
    }

    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let f = flags.intersection([.function, .option, .control, .command, .shift])
        switch self {
        case .fn: return f.contains(.function) && !f.contains(.command)
        case .option: return f == .option
        case .controlOption: return f.contains(.control) && f.contains(.option)
        }
    }
}

struct ExcludedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    /// Where exports go; nil = the 导出 folder inside the library.
    var exportFolder: URL? { didSet { defaults.set(exportFolder?.path, forKey: "exportFolder") } }
    var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
    var countdown: Int { didSet { defaults.set(countdown, forKey: "countdown") } }
    var recordMic: Bool { didSet { defaults.set(recordMic, forKey: "recordMic") } }
    var micDeviceID: String? { didSet { defaults.set(micDeviceID, forKey: "micDeviceID") } }
    var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    var recordCamera: Bool { didSet { defaults.set(recordCamera, forKey: "recordCamera") } }
    var cameraDeviceID: String? { didSet { defaults.set(cameraDeviceID, forKey: "cameraDeviceID") } }
    var showGhostOnResume: Bool { didSet { defaults.set(showGhostOnResume, forKey: "showGhostOnResume") } }

    var highlightTrigger: HighlightTrigger { didSet { defaults.set(highlightTrigger.rawValue, forKey: "highlightTrigger") } }
    var highlightKind: Annotation.Kind { didSet { defaults.set(highlightKind.rawValue, forKey: "highlightKind") } }
    var highlightColor: RGBA { didSet { save(highlightColor, "highlightColor") } }
    var stepNumbers: Bool { didSet { defaults.set(stepNumbers, forKey: "stepNumbers") } }

    var excludedApps: [ExcludedApp] { didSet { save(excludedApps, "excludedApps") } }
    var hideNotifications: Bool { didSet { defaults.set(hideNotifications, forKey: "hideNotifications") } }
    var recordAllKeys: Bool { didSet { defaults.set(recordAllKeys, forKey: "recordAllKeys") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    static let suggestedExclusions: [ExcludedApp] = [
        ExcludedApp(bundleID: "com.tencent.xinWeChat", name: "微信"),
        ExcludedApp(bundleID: "com.alibaba.DingTalkMac", name: "钉钉"),
        ExcludedApp(bundleID: "com.tencent.qq", name: "QQ"),
        ExcludedApp(bundleID: "com.apple.MobileSMS", name: "信息"),
        ExcludedApp(bundleID: "com.1password.1password", name: "1Password"),
        ExcludedApp(bundleID: "com.apple.Passwords", name: "密码"),
    ]

    private init() {
        let d = UserDefaults.standard
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        saveFolder = d.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0) } ?? movies.appendingPathComponent("Takes")
        exportFolder = d.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0) }
        fps = d.object(forKey: "fps") as? Int ?? 60
        countdown = d.object(forKey: "countdown") as? Int ?? 3
        recordMic = d.object(forKey: "recordMic") as? Bool ?? true
        micDeviceID = d.string(forKey: "micDeviceID")
        recordSystemAudio = d.object(forKey: "recordSystemAudio") as? Bool ?? true
        recordCamera = d.object(forKey: "recordCamera") as? Bool ?? false
        cameraDeviceID = d.string(forKey: "cameraDeviceID")
        showGhostOnResume = d.object(forKey: "showGhostOnResume") as? Bool ?? true
        highlightTrigger = d.string(forKey: "highlightTrigger").flatMap(HighlightTrigger.init) ?? .fn
        highlightKind = d.string(forKey: "highlightKind").flatMap(Annotation.Kind.init) ?? .box
        highlightColor = Self.load(RGBA.self, "highlightColor", d) ?? .red
        stepNumbers = d.object(forKey: "stepNumbers") as? Bool ?? false
        excludedApps = Self.load([ExcludedApp].self, "excludedApps", d) ?? Self.suggestedExclusions
        hideNotifications = d.object(forKey: "hideNotifications") as? Bool ?? true
        recordAllKeys = d.object(forKey: "recordAllKeys") as? Bool ?? false
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")

        // Debug launch flag. Kept out of the stored settings: assigning an @Observable property runs didSet even in init.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--library"), i + 1 < args.count {
            libraryOverride = URL(fileURLWithPath: args[i + 1])
        }
    }

    @ObservationIgnored private(set) var libraryOverride: URL?

    /// Where recordings are read and written; `saveFolder` unless a debug override is active.
    var libraryFolder: URL { libraryOverride ?? saveFolder }
    var skipsOnboarding: Bool { hasCompletedOnboarding || libraryOverride != nil }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
