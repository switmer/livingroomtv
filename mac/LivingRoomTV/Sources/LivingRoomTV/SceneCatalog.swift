import SwiftUI

/// One scene in the household catalog — mirrors the Python `preferences.Scene`
/// dataclass so we can decode `tv scene list --json` straight into this type.
struct RoomScene: Identifiable, Hashable, Decodable {
    let id: String
    let label: String
    let shortLabel: String
    let symbol: String          // Lucide icon slug (matches asset in Resources)
    let colorHex: String        // e.g. "#FF9F0A"
    let steps: [SceneStep]
    let source: Source

    enum Source: String, Decodable, Hashable {
        case builtin, user
    }

    var isUser: Bool { source == .user }

    enum CodingKeys: String, CodingKey {
        case id, label, symbol, steps, source
        case shortLabel = "short_label"
        case colorHex = "color"
    }

    init(id: String, label: String, shortLabel: String, symbol: String, colorHex: String, steps: [SceneStep], source: Source = .builtin) {
        self.id = id
        self.label = label
        self.shortLabel = shortLabel
        self.symbol = symbol
        self.colorHex = colorHex
        self.steps = steps
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.shortLabel = try c.decode(String.self, forKey: .shortLabel)
        self.symbol = try c.decode(String.self, forKey: .symbol)
        self.colorHex = try c.decode(String.self, forKey: .colorHex)
        self.steps = (try? c.decode([SceneStep].self, forKey: .steps)) ?? []
        // Older preferences lack `source` — default to builtin so upgrades don't
        // silently turn every existing scene into a user-deletable one.
        let raw = (try? c.decode(String.self, forKey: .source)) ?? "builtin"
        self.source = Source(rawValue: raw) ?? .builtin
    }

    var tint: Color {
        Color(hex: parseHex(colorHex))
    }

    private func parseHex(_ s: String) -> UInt32 {
        var trimmed = s
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        return UInt32(trimmed, radix: 16) ?? 0x888888
    }
}

struct SceneStep: Hashable, Decodable {
    let action: String
    // Other TOML keys (query, repeat, name, seconds, percent…) are ignored
    // by the Swift side — the UI only needs the action verb for step counts
    // and hints. The Python runner handles args.
}

/// Fetches and holds the scene catalog. Populated once at launch from
/// `tv scene list --json`; UI binds to `scenes`. Falls through to hardcoded
/// defaults if the CLI is unreachable, so the popup is never blank.
@MainActor
final class SceneCatalog: ObservableObject {
    @Published var scenes: [RoomScene] = fallback

    static let fallback: [RoomScene] = [
        RoomScene(id: "morning",  label: "Quiet Morning",  shortLabel: "Morning",  symbol: "sunrise",  colorHex: "#FF9F0A", steps: []),
        RoomScene(id: "movie",    label: "Movie Night",    shortLabel: "Movie",    symbol: "film",     colorHex: "#7C3AED", steps: []),
        RoomScene(id: "dinner",   label: "Family Dinner",  shortLabel: "Dinner",   symbol: "utensils", colorHex: "#F0A202", steps: []),
        RoomScene(id: "bedtime",  label: "Bedtime",        shortLabel: "Bedtime",  symbol: "moon",     colorHex: "#E05780", steps: []),
    ]

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        do {
            let loaded: [RoomScene] = try await TVCommandRunner.runJSON(["scene", "list", "--json"])
            if !loaded.isEmpty {
                scenes = loaded
            }
        } catch {
            // Fall through to the hardcoded fallback; the popup still renders.
        }
    }
}
