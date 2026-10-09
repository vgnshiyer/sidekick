import AppKit
import Foundation

/// Display size of the pet; each is an integer scale of the 48x52 art.
enum PetSize: String, Codable, CaseIterable {
    case small, medium, large

    var points: CGSize {
        switch self {
        case .small: return CGSize(width: 48, height: 52)
        case .medium: return CGSize(width: 96, height: 104)
        case .large: return CGSize(width: 144, height: 156)
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// UI choices that survive relaunch, saved in `Paths.stateFile`.
struct UIState: Codable, Equatable {
    var petId: String?
    var petSize: PetSize = .medium
    var petHidden = false
    var trayCollapsed = false
    /// Display the pet was last placed on.
    var lastDisplay: String?
    /// Normalized pet position per display (see `PetPosition`).
    var positions: [String: CGPoint] = [:]
    /// Serve the phone page on the local network.
    var phoneAccess = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        petId = try container.decodeIfPresent(String.self, forKey: .petId)
        petSize = (try? container.decodeIfPresent(PetSize.self, forKey: .petSize)) ?? .medium
        petHidden = try container.decodeIfPresent(Bool.self, forKey: .petHidden) ?? false
        trayCollapsed = try container.decodeIfPresent(Bool.self, forKey: .trayCollapsed) ?? false
        lastDisplay = try container.decodeIfPresent(String.self, forKey: .lastDisplay)
        positions = try container.decodeIfPresent([String: CGPoint].self, forKey: .positions) ?? [:]
        phoneAccess = try container.decodeIfPresent(Bool.self, forKey: .phoneAccess) ?? false
    }
}

/// Loads `UIState` once and writes every change back, unless persistence is off.
@MainActor
final class UIStateStore {
    private(set) var state: UIState
    private let file: URL?
    private let persist: Bool

    /// - Parameters:
    ///   - file: where the state lives; nil starts from defaults.
    ///   - persist: write changes back (off for `--demo`).
    init(file: URL?, persist: Bool) {
        self.file = file
        self.persist = persist
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(UIState.self, from: data) {
            state = saved
        } else {
            state = UIState()
        }
    }

    func update(_ change: (inout UIState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        guard persist, let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

extension NSScreen {
    /// Stable identifier used to remember the pet's position per display.
    var displayKey: String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return localizedName
    }
}
