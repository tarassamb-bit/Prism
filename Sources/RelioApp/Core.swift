import Foundation
import AVFoundation
import AppKit
import CSQLite
import Darwin.Mach

struct MediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var path: String
    var kind: String
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var thumbnail: String? = nil
    var hasAudio: Bool? = nil
    var note: String = ""
    var priority: Int = 50
    var created: Date = .now
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct EditSegment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var mediaID: UUID
    var start: Double = 0
    var duration: Double
    var caption: String = ""
    var isMuted: Bool? = false
    var captionStart: Double? = 0
    var captionDuration: Double? = nil
    var fitToFrame: Bool? = nil
    var captions: [TimedCaption]? = nil
    var cropZoom: Double? = 1.08
    /// Horizontal crop center as a fraction of the available pan range (0 = left, 0.5 = center, 1 = right).
    var cropPosition: Double? = 0.5
    /// Time-stamped horizontal framing positions; nil means the path has not been analyzed yet.
    var cropKeyframes: [CropKeyframe]? = nil
    /// Tracker algorithm version used to create cropKeyframes; old paths are regenerated on next preview/export.
    var cropTrackingVersion: Int? = nil
    /// On-device word timings, relative to this Short, used to keep trims from clipping speech.
    var speechWords: [TimedSpeechWord]? = nil

    var suggestedTitle: String? = nil
    var selectionReason: String? = nil
    var captionNotice: String? = nil
    var captionStyle: CaptionStyle? = nil

    private enum CodingKeys: String, CodingKey {
        case id, mediaID, start, duration, caption, isMuted, captionStart, captionDuration
        case fitToFrame, captions, cropZoom, cropPosition, cropKeyframes, cropTrackingVersion, speechWords, suggestedTitle, selectionReason, captionNotice, captionStyle
    }

    init(id: UUID = UUID(), mediaID: UUID, start: Double = 0, duration: Double, caption: String = "",
         isMuted: Bool? = false, captionStart: Double? = 0, captionDuration: Double? = nil,
         fitToFrame: Bool? = nil, captions: [TimedCaption]? = nil, cropZoom: Double? = 1.08,
         cropPosition: Double? = 0.5, cropKeyframes: [CropKeyframe]? = nil, cropTrackingVersion: Int? = nil, speechWords: [TimedSpeechWord]? = nil,
         suggestedTitle: String? = nil, selectionReason: String? = nil, captionNotice: String? = nil, captionStyle: CaptionStyle? = nil) {
        self.id = id; self.mediaID = mediaID; self.start = start; self.duration = duration; self.caption = caption
        self.isMuted = isMuted; self.captionStart = captionStart; self.captionDuration = captionDuration
        self.fitToFrame = fitToFrame; self.captions = captions; self.cropZoom = cropZoom; self.cropPosition = cropPosition
        self.cropKeyframes = cropKeyframes
        self.cropTrackingVersion = cropTrackingVersion
        self.speechWords = speechWords
        self.suggestedTitle = suggestedTitle; self.selectionReason = selectionReason; self.captionNotice = captionNotice
        self.captionStyle = captionStyle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mediaID = try values.decode(UUID.self, forKey: .mediaID)
        start = try values.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try values.decode(Double.self, forKey: .duration)
        caption = try values.decodeIfPresent(String.self, forKey: .caption) ?? ""
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        captionStart = try values.decodeIfPresent(Double.self, forKey: .captionStart) ?? 0
        captionDuration = try values.decodeIfPresent(Double.self, forKey: .captionDuration)
        fitToFrame = try values.decodeIfPresent(Bool.self, forKey: .fitToFrame)
        captions = try values.decodeIfPresent([TimedCaption].self, forKey: .captions)
        cropZoom = try values.decodeIfPresent(Double.self, forKey: .cropZoom) ?? 1.08
        cropPosition = try values.decodeIfPresent(Double.self, forKey: .cropPosition) ?? 0.5
        cropKeyframes = try values.decodeIfPresent([CropKeyframe].self, forKey: .cropKeyframes)
        cropTrackingVersion = try values.decodeIfPresent(Int.self, forKey: .cropTrackingVersion)
        speechWords = try values.decodeIfPresent([TimedSpeechWord].self, forKey: .speechWords)
        suggestedTitle = try values.decodeIfPresent(String.self, forKey: .suggestedTitle)
        selectionReason = try values.decodeIfPresent(String.self, forKey: .selectionReason)
        captionNotice = try values.decodeIfPresent(String.self, forKey: .captionNotice)
        captionStyle = try values.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)
    }
}

struct CropKeyframe: Codable, Hashable {
    var time: Double
    var position: Double
    /// A source edit boundary: hold the previous framing until this time, then switch.
    var isSceneCut: Bool? = nil
    var preserveWholeFrame: Bool? = nil
}

struct SourceInterval: Sendable {
    let start: Double
    let end: Double
}

struct TimedCaption: Codable, Hashable {
    var text: String
    var start: Double
    var duration: Double
}

struct TimedSpeechWord: Codable, Hashable {
    var text: String
    var start: Double
    var duration: Double
}

enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case classic
    case viral
    /// Retired boxed style. Kept so saved projects still decode; it renders as Simple.
    case clean

    static let allCases: [CaptionStyle] = [.classic, .viral]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic, .clean: "Simple"
        case .viral: "Viral highlight"
        }
    }
}

struct ProjectData: Codable {
    var id: UUID = UUID()
    var name: String
    var media: [MediaItem] = []
    var segments: [EditSegment] = []
    var memory: String = ""
    var created: Date = .now
    /// A name the person chose; older projects have none.
    var title: String? = nil

    /// What people see: their chosen name, else the first Short's title, else the video's name, else the dated folder name.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let clipTitle = segments.first(where: { $0.suggestedTitle?.isEmpty == false })?.suggestedTitle { return clipTitle }
        if let video = media.first(where: { $0.kind == "video" }) { return URL(fileURLWithPath: video.name).deletingPathExtension().lastPathComponent }
        return name
    }
}

struct MachineProfile {
    let memoryGB: Int
    let memoryUsedGB: Double
    let cpu: String
    let os: String
    let freeGB: Int
    let storageGB: Int
    let isAppleSilicon: Bool
    var memoryUsage: Double { min(1, max(0, memoryUsedGB / Double(max(memoryGB, 1)))) }
    var freeStorageRatio: Double { min(1, max(0, Double(freeGB) / Double(max(storageGB, 1)))) }
    var tier: String {
        memoryGB >= 24 ? "Relio AI Pro" : memoryGB >= 16 ? "Relio AI Standard" : "Relio AI Lite"
    }
    static func detect() -> Self {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let totalMemoryGB = Int((Double(bytes) / 1_073_741_824).rounded())
        let storage = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let freeBytes = max(0, storage?.volumeAvailableCapacityForImportantUsage ?? 0)
        let storageBytes = max(0, storage?.volumeTotalCapacity ?? 0)
        return .init(
            memoryGB: totalMemoryGB,
            memoryUsedGB: usedMemoryGB(totalBytes: bytes),
            cpu: ProcessInfo.processInfo.processorCount.description + " cores",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            freeGB: Int(freeBytes / 1_073_741_824),
            storageGB: Int(storageBytes / 1_073_741_824),
            isAppleSilicon: Self.detectAppleSilicon()
        )
    }

    private static func detectAppleSilicon() -> Bool {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
    }

    private static func usedMemoryGB(totalBytes: UInt64) -> Double {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(getpagesize())
        let totalPages = totalBytes / pageSize
        let availablePages = UInt64(statistics.free_count + statistics.speculative_count)
        let usedPages = totalPages > availablePages ? totalPages - availablePages : 0
        let usedBytes = usedPages * pageSize
        return min(Double(totalBytes) / 1_073_741_824, Double(usedBytes) / 1_073_741_824)
    }
}

protocol RelioModel {
    var displayName: String { get }
    func analyzeImage(_ image: NSImage) async throws -> String
    func analyzeFrames(_ images: [NSImage]) async throws -> [String]
    func analyzeScene(_ descriptions: [String]) async throws -> String
    func analyzeTranscript(_ text: String) async throws -> String
    func analyzeAudioContext(_ path: URL) async throws -> String
    func scoreClip(_ media: MediaItem) async throws -> Int
    func createEditPlan(_ media: [MediaItem], preferences: String) async throws -> [EditSegment]
    func reviseEditPlan(_ plan: [EditSegment], instruction: String) async throws -> [EditSegment]
    func searchProject(_ query: String, media: [MediaItem]) async throws -> [MediaItem]
    func chatAboutProject(_ question: String, media: [MediaItem]) async throws -> String
}

// The bundled planner works offline. Future downloaded model adapters can conform to RelioModel.
struct LocalPlanner: RelioModel {
    let displayName = "Relio AI Lite"
    func analyzeImage(_ image: NSImage) async throws -> String { "Photo \(Int(image.size.width)) × \(Int(image.size.height))" }
    func analyzeFrames(_ images: [NSImage]) async throws -> [String] { try await images.asyncMap { try await analyzeImage($0) } }
    func analyzeScene(_ descriptions: [String]) async throws -> String { descriptions.joined(separator: ", ") }
    func analyzeTranscript(_ text: String) async throws -> String { String(text.prefix(300)) }
    func analyzeAudioContext(_ path: URL) async throws -> String { "Audio: \(path.lastPathComponent)" }
    func scoreClip(_ media: MediaItem) async throws -> Int { media.priority }
    func createEditPlan(_ media: [MediaItem], preferences: String) async throws -> [EditSegment] {
        media.sorted { $0.created < $1.created }.map { .init(mediaID: $0.id, duration: $0.kind == "video" ? min($0.duration, 8) : 3) }
    }
    func reviseEditPlan(_ plan: [EditSegment], instruction: String) async throws -> [EditSegment] { plan }
    func searchProject(_ query: String, media: [MediaItem]) async throws -> [MediaItem] { media.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.note.localizedCaseInsensitiveContains(query) } }
    func chatAboutProject(_ question: String, media: [MediaItem]) async throws -> String { "This project contains \(media.count) media items. Local language model support can be added through a model adapter." }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        for item in self { values.append(try await transform(item)) }
        return values
    }
}

final class ProjectStore {
    let root: URL
    private var db: OpaquePointer?
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(root.appendingPathComponent("project.sqlite").path, &db) == SQLITE_OK else { throw StoreError.database }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
    }
    deinit { sqlite3_close(db) }
    enum StoreError: Error { case database }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.database }
    }
    func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw StoreError.database }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.database }
    }
    func load<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.database }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
}

enum MediaEngine {
    static func inspect(_ url: URL, thumbnailDirectory: URL) async -> MediaItem? {
        let ext = url.pathExtension.lowercased()
        let kind = ["mov", "mp4", "m4v", "avi"].contains(ext) ? "video" : (["jpg", "jpeg", "png", "heic", "tiff"].contains(ext) ? "photo" : (["mp3", "wav", "m4a", "aiff"].contains(ext) ? "audio" : ""))
        guard !kind.isEmpty else { return nil }
        var item = MediaItem(path: url.path, kind: kind)
        if kind == "video" || kind == "audio" {
            let asset = AVURLAsset(url: url)
            item.duration = (try? await asset.load(.duration).seconds) ?? 0
            if kind == "video" {
                item.hasAudio = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    let size = (try? await track.load(.naturalSize)) ?? .zero
                    let transform = (try? await track.load(.preferredTransform)) ?? .identity
                    let bounds = CGRect(origin: .zero, size: size).applying(transform)
                    item.width = Int(abs(bounds.width)); item.height = Int(abs(bounds.height))
                }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                if let cg = try? generator.copyCGImage(at: CMTime(seconds: min(item.duration / 2, 0.5), preferredTimescale: 600), actualTime: nil) {
                    item.thumbnail = saveThumbnail(NSImage(cgImage: cg, size: .zero), id: item.id, directory: thumbnailDirectory)
                }
            }
        } else if let image = NSImage(contentsOf: url) {
            item.width = Int(image.size.width); item.height = Int(image.size.height)
            item.thumbnail = saveThumbnail(image, id: item.id, directory: thumbnailDirectory)
            if min(item.width, item.height) < 720 { item.priority = 25; item.note = "Low resolution · low priority" }
        }
        if kind == "video", (!item.duration.isFinite || item.duration <= 0 || item.width <= 0 || item.height <= 0) { return nil }
        return item
    }
    private static func saveThumbnail(_ image: NSImage, id: UUID, directory: URL) -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        let path = directory.appendingPathComponent("\(id).jpg")
        try? data.write(to: path, options: .atomic)
        return path.path
    }
}
