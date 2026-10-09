import Foundation

/// The Codex mascot's spritesheet, read from the installed Codex desktop app. It is a Codex-format
/// pet atlas inside the app's `app.asar`; Sidekick never ships a copy.
public enum CodexMascot {
    /// Where the web assets sit in the archive, and the sheet's name there (it carries a version and a hash).
    static let assetsPath = ["webview", "assets"]
    static let namePattern = #"^codex-spritesheet-v(\d+)-[0-9a-f]+\.(webp|png)$"#

    /// The spritesheet's bytes from `app` (ChatGPT.app), or nil when the app or the sheet isn't there.
    public static func spritesheet(inApp app: URL) -> Data? {
        let resources = app.appendingPathComponent("Contents/Resources")
        guard let archive = AsarArchive(url: resources.appendingPathComponent("app.asar")),
              let assets = archive.directory(at: assetsPath) else { return nil }
        let regex = try? NSRegularExpression(pattern: namePattern)
        // The newest sheet when more than one version is present.
        let name = assets.keys
            .compactMap { name -> (String, Int)? in
                let range = NSRange(name.startIndex..., in: name)
                guard let match = regex?.firstMatch(in: name, range: range),
                      let version = Range(match.range(at: 1), in: name).flatMap({ Int(name[$0]) }) else { return nil }
                return (name, version)
            }
            .max { $0.1 < $1.1 }?.0
        guard let name else { return nil }
        return archive.contents(of: assetsPath + [name])
    }
}

/// A read-only Electron `asar` archive: a Chromium pickle holding a JSON file tree, then the file bytes.
struct AsarArchive {
    private let url: URL
    private let tree: [String: Any]
    /// Where file offsets count from.
    private let base: UInt64

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // [4][header pickle size][header pickle payload size][JSON length], then the JSON.
        guard let prefix = try? handle.read(upToCount: 16), prefix.count == 16 else { return nil }
        func word(_ offset: Int) -> UInt32 {
            prefix.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        let headerSize = UInt64(word(4)), jsonLength = Int(word(12))
        guard word(0) == 4, jsonLength > 0, jsonLength < 64 << 20, UInt64(jsonLength) + 8 <= headerSize,
              let json = try? handle.read(upToCount: jsonLength), json.count == jsonLength,
              let tree = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        self.url = url
        self.tree = tree
        base = 8 + headerSize
    }

    /// The entries of the folder at `path`, keyed by name.
    func directory(at path: [String]) -> [String: Any]? {
        var node = tree
        for component in path {
            guard let next = (node["files"] as? [String: Any])?[component] as? [String: Any] else { return nil }
            node = next
        }
        return node["files"] as? [String: Any]
    }

    /// The bytes of the file at `path`; files marked unpacked live beside the archive.
    func contents(of path: [String]) -> Data? {
        guard let name = path.last, let entry = directory(at: Array(path.dropLast()))?[name] as? [String: Any],
              let size = (entry["size"] as? NSNumber)?.intValue, size > 0, size < 64 << 20 else { return nil }
        if entry["unpacked"] as? Bool == true {
            let file = path.reduce(URL(fileURLWithPath: url.path + ".unpacked")) { $0.appendingPathComponent($1) }
            return try? Data(contentsOf: file)
        }
        guard let offset = (entry["offset"] as? String).flatMap(UInt64.init),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: base + offset)) != nil,
              let data = try? handle.read(upToCount: size), data.count == size else { return nil }
        return data
    }
}
