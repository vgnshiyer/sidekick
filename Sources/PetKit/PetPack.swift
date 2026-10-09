import CoreGraphics
import Foundation
import ImageIO

/// One animation row of a Codex-format atlas, top to bottom.
public enum PetRow: Int, CaseIterable, Sendable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review

    /// The row's name in the Codex pet contract.
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .runningRight: return "running-right"
        case .runningLeft: return "running-left"
        case .waving: return "waving"
        case .jumping: return "jumping"
        case .failed: return "failed"
        case .waiting: return "waiting"
        case .running: return "running"
        case .review: return "review"
        }
    }

    /// Frames used in this row; the remaining cells are transparent.
    public var frameCount: Int { frameDurations.count }

    /// Per-frame durations in seconds at normal speed (idle runs 6x slower when looping).
    public var frameDurations: [TimeInterval] {
        switch self {
        case .idle: return [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
        case .runningRight, .runningLeft: return Self.timing(8, each: 0.12, last: 0.22)
        case .waving: return Self.timing(4, each: 0.14, last: 0.28)
        case .jumping: return Self.timing(5, each: 0.14, last: 0.28)
        case .failed: return Self.timing(8, each: 0.14, last: 0.24)
        case .waiting: return Self.timing(6, each: 0.15, last: 0.26)
        case .running: return Self.timing(6, each: 0.12, last: 0.22)
        case .review: return Self.timing(6, each: 0.15, last: 0.28)
        }
    }

    /// Length of one play of the row at normal speed.
    public var playDuration: TimeInterval { frameDurations.reduce(0, +) }

    private static func timing(_ count: Int, each: TimeInterval, last: TimeInterval) -> [TimeInterval] {
        Array(repeating: each, count: count - 1) + [last]
    }
}

/// Geometry of the Codex pet atlas: 8 columns of 192x208 px cells.
public enum PetAtlas {
    public static let columns = 8
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let width = columns * cellWidth

    /// Logical size of the art (cells are drawn at 48x52 and scaled x4).
    public static let logicalCellSize = CGSize(width: 48, height: 52)

    /// Row count for an atlas of the given pixel size: 9 (v1, 1536x1872) or 11 (v2, 1536x2288), else nil.
    public static func rowCount(width: Int, height: Int) -> Int? {
        guard width == Self.width else { return nil }
        switch height {
        case 9 * cellHeight: return 9
        case 11 * cellHeight: return 11
        default: return nil
        }
    }
}

/// A pet pack folder: `pet.json` plus its spritesheet.
public struct PetPack: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let directory: URL
    /// 1 for a 9-row atlas, 2 for an 11-row atlas (only rows 0-8 are used).
    public let spriteVersion: Int
    public let atlas: CGImage
    /// Lines the pet says in a speech bubble, or nil when the pack has none.
    public let quips: PetQuips?

    /// Rows in the atlas image.
    public var rowCount: Int { spriteVersion == 2 ? 11 : 9 }

    /// Loads the pack in `directory`, or returns nil if it is not a valid Codex-format pet.
    public static func load(from directory: URL) -> PetPack? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        if let version = manifest.spriteVersionNumber, version != 1, version != 2 { return nil }

        guard let sheetURL = manifest.spritesheetURL(in: directory),
              let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rows = PetAtlas.rowCount(width: image.width, height: image.height) else { return nil }

        let folderName = directory.lastPathComponent
        let id = manifest.id.nonEmpty ?? folderName
        return PetPack(
            id: id,
            displayName: manifest.displayName.nonEmpty ?? id,
            description: manifest.description ?? "",
            directory: directory,
            spriteVersion: rows == 11 ? 2 : 1,
            atlas: image,
            quips: manifest.quips?.nilIfEmpty)
    }

    /// A pack whose atlas comes from elsewhere than a pack folder (another app's resources), or nil
    /// if `sheet` isn't a Codex-format atlas. `origin` stands in for the folder.
    public static func make(id: String, displayName: String, description: String, sheet: Data, origin: URL) -> PetPack? {
        guard let source = CGImageSourceCreateWithData(sheet as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rows = PetAtlas.rowCount(width: image.width, height: image.height) else { return nil }
        return PetPack(
            id: id, displayName: displayName, description: description, directory: origin,
            spriteVersion: rows == 11 ? 2 : 1, atlas: image, quips: nil)
    }

    /// `pet.json` per the Codex pets contract. Every field is optional.
    struct Manifest: Decodable {
        var id: String?
        var displayName: String?
        var description: String?
        var spriteVersionNumber: Int?
        var spritesheetPath: String?
        var quips: PetQuips?

        /// The spritesheet's URL, which must stay inside the pack folder.
        func spritesheetURL(in directory: URL) -> URL? {
            let base = directory.standardizedFileURL.resolvingSymlinksInPath()
            let candidates = spritesheetPath.nonEmpty.map { [$0] } ?? ["spritesheet.png", "spritesheet.webp"]
            for path in candidates {
                let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(base.path + "/") else { return nil }
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }
    }
}

/// What makes a pet speak up.
public enum QuipTrigger: Sendable {
    /// A message from the chat panel was delivered or queued.
    case sent
    /// The pet's mood turned to running.
    case working
}

/// One-line speech-bubble lines, from the optional `quips` key in `pet.json`: a Sidekick
/// extension that Codex ignores. Anything malformed reads as no line, never as a bad pack.
public struct PetQuips: Sendable, Equatable, Decodable {
    public var sent: String?
    public var working: String?

    public init(sent: String? = nil, working: String? = nil) {
        self.sent = sent.nonEmpty
        self.working = working.nonEmpty
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        func line(_ key: CodingKeys) -> String? {
            (try? container?.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        self.init(sent: line(.sent), working: line(.working))
    }

    /// The line for `trigger`, or nil when the pet has none.
    public func text(for trigger: QuipTrigger) -> String? {
        switch trigger {
        case .sent: return sent
        case .working: return working
        }
    }

    var nilIfEmpty: PetQuips? { sent == nil && working == nil ? nil : self }

    private enum CodingKeys: String, CodingKey {
        case sent, working
    }
}

/// Spaces quips out: at most one per `interval`.
public struct QuipThrottle: Sendable {
    public static let interval: TimeInterval = 20

    private var lastShownAt: TimeInterval?

    public init() {}

    /// True, and counted as shown, when no quip showed in the last `interval` seconds.
    public mutating func allow(at now: TimeInterval) -> Bool {
        if let lastShownAt, now - lastShownAt < Self.interval { return false }
        lastShownAt = now
        return true
    }
}

/// Finds pet packs on disk.
public enum PetLibrary {
    /// Loads every valid pack in the subfolders of `roots`, in root order and by name within a root.
    /// Invalid packs are skipped silently; when two packs share an id, the first one wins.
    public static func loadAll(from roots: [URL]) -> [PetPack] {
        var seen = Set<String>()
        var packs: [PetPack] = []
        for root in roots {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let found = folders
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .compactMap(PetPack.load(from:))
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            for pack in found where seen.insert(pack.id).inserted {
                packs.append(pack)
            }
        }
        return packs
    }
}

private extension Optional where Wrapped == String {
    /// The trimmed string, or nil when it is missing or blank.
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
