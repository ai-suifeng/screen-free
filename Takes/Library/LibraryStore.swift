import AVFoundation
import AppKit
import Observation

struct LibraryItem: Identifiable, Hashable {
    var bundle: ProjectBundle
    var meta: ProjectMeta
    /// Text recognized on screen during the recording, for content search.
    var screenText: String = ""
    var sizeBytes: Int64 = 0

    var id: UUID { meta.id }
}

@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var items: [LibraryItem] = []
    private(set) var isLoading = false
    /// Bundle currently being recorded, hidden from recovery.
    var activeRecording: URL?

    var allTags: [String] {
        Array(Set(items.flatMap(\.meta.tags))).sorted()
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    func reload() {
        let root = AppSettings.shared.libraryFolder
        let active = activeRecording
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loaded = await Self.scan(root, skipping: active)
            await MainActor.run {
                self.items = loaded
                self.isLoading = false
            }
        }
    }

    private static func scan(_ root: URL, skipping active: URL?) async -> [LibraryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [LibraryItem] = []
        for url in urls where url.pathExtension == "takes" && url.standardizedFileURL != active?.standardizedFileURL {
            let bundle = ProjectBundle(url: url)
            guard var meta = try? bundle.readMeta() else { continue }
            if meta.status == .recording {
                meta = await recover(bundle, meta)
            }
            if !fm.fileExists(atPath: bundle.thumbnailURL.path) {
                await Thumbnailer.generate(for: bundle)
            }
            var item = LibraryItem(bundle: bundle, meta: meta, sizeBytes: folderSize(url))
            if let data = try? Data(contentsOf: bundle.ocrURL),
               let index = try? JSONDecoder().decode(ScreenTextIndex.self, from: data) {
                item.screenText = index.text
            }
            result.append(item)
        }
        return result.sorted { $0.meta.createdAt > $1.meta.createdAt }
    }

    /// Rebuilds the take list of a project whose recording never finished (crash, power loss).
    private static func recover(_ bundle: ProjectBundle, _ meta: ProjectMeta) async -> ProjectMeta {
        var meta = meta
        let known = Set(meta.segments.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bundle.segmentsDir.path)) ?? []
        for file in files.sorted() where file.hasPrefix("take-") && !known.contains(file) {
            let asset = AVURLAsset(url: bundle.segmentURL(file))
            guard let duration = try? await asset.load(.duration), duration.seconds > 0.1,
                  let index = Int(file.dropFirst(5).prefix(3)) else { continue }
            let camera = "camera-" + file.dropFirst(5)
            let hasCamera = FileManager.default.fileExists(atPath: bundle.segmentURL(camera).path)
            meta.segments.append(SegmentInfo(index: index - 1, file: file, cameraFile: hasCamera ? camera : nil,
                                              duration: duration.seconds))
        }
        meta.segments.sort { $0.index < $1.index }
        meta.status = .recovered
        try? bundle.writeMeta(meta)
        return meta
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Mutations

    func update(_ id: UUID, _ change: (inout ProjectMeta) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i].meta)
        try? items[i].bundle.writeMeta(items[i].meta)
    }

    func trash(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            try? FileManager.default.trashItem(at: item.bundle.url, resultingItemURL: nil)
        }
        items.removeAll { ids.contains($0.id) }
    }

    /// Removes recordings from disk for good (not via the Trash).
    func deletePermanently(_ ids: Set<UUID>, includingExports: Bool) {
        let fm = FileManager.default
        for item in items where ids.contains(item.id) {
            if includingExports {
                for path in item.meta.exportedFiles { try? fm.removeItem(atPath: path) }
            }
            try? fm.removeItem(at: item.bundle.url)
            ThumbnailCache.shared.invalidate(item.bundle)
        }
        items.removeAll { ids.contains($0.id) }
    }

    func setScreenText(_ text: String, for url: URL) {
        guard let i = items.firstIndex(where: { $0.bundle.url == url }) else { return }
        items[i].screenText = text
    }

    func item(for url: URL) -> LibraryItem? {
        items.first { $0.bundle.url.standardizedFileURL == url.standardizedFileURL }
    }
}

enum Thumbnailer {
    static func generate(for bundle: ProjectBundle) async {
        guard let meta = try? bundle.readMeta(), let first = meta.segments.first else { return }
        let asset = AVURLAsset(url: bundle.segmentURL(first.file))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let time = CMTime(seconds: min(1.0, first.duration / 2), preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: bundle.thumbnailURL)
    }
}
