import Foundation

struct TVStatus: Codable, Equatable {
    var device: String?
    var deviceId: String?
    var power: String?
    var playState: String?
    var mediaType: String?
    var app: String?
    var title: String?
    var artist: String?
    var album: String?
    var series: String?
    var position: Double?
    var totalTime: Double?
    var volume: Double?
    var volumeSource: String?       // "lg" when LG paired, "appletv" otherwise
    var speakerOutput: String?      // "tv_speakers" | "airplay"
    var muted: Bool?
    var tvDisplayOn: Bool?          // true = LG panel is actually lit; nil when LG not paired
    var lgPowerState: String?       // raw LG value: "Active" | "Screen Off" | "Active Standby" | "Suspend"

    enum CodingKeys: String, CodingKey {
        case device
        case deviceId = "device_id"
        case power
        case playState = "play_state"
        case mediaType = "media_type"
        case app
        case title
        case artist
        case album
        case series
        case position
        case totalTime = "total_time"
        case volume
        case volumeSource = "volume_source"
        case speakerOutput = "speaker_output"
        case muted
        case tvDisplayOn = "tv_display_on"
        case lgPowerState = "lg_power_state"
    }

    /// True when the volume value came from the LG webOS adapter (real TV speakers).
    var hasRealVolume: Bool { volumeSource == "lg" }

    /// Composite display state: true when the LG screen is lit, false when it's
    /// dark (Screen Off, Active Standby, Suspend). When LG isn't paired we fall
    /// back to Apple TV's `power == "on"` signal, which is a less-accurate proxy.
    var displayOn: Bool {
        if let d = tvDisplayOn { return d }
        return power == "on"
    }

    /// Audio is streaming while the LG display is off — Spotify's "music mode"
    /// pattern. Worth surfacing so the UI doesn't say "ON" for a dark screen.
    var audioOnly: Bool {
        guard tvDisplayOn == false else { return false }
        return playState == "playing"
    }

    var isOn: Bool { power == "on" }

    /// Best label for the menu bar (truncated).
    var menuBarLabel: String {
        let candidate = title ?? series ?? app ?? "Living Room"
        if candidate.count <= 22 { return candidate }
        return String(candidate.prefix(21)) + "…"
    }

    var sfSymbol: String {
        guard isOn else { return "tv" }
        switch playState {
        case "playing": return "play.fill"
        case "paused": return "pause.fill"
        default: return "tv.fill"
        }
    }

    /// pyatv reports AirPlay output volume; 0 typically means audio is routed via HDMI-CEC.
    var hasMeaningfulVolume: Bool {
        if let v = volume { return v > 0 }
        return false
    }

    var progressFraction: Double? {
        guard let p = position, let t = totalTime, t > 0 else { return nil }
        return max(0, min(1, p / t))
    }

    var positionFormatted: String { Self.format(seconds: position) }
    var totalFormatted: String { Self.format(seconds: totalTime) }

    static func format(seconds: Double?) -> String {
        guard let s = seconds else { return "–" }
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

/// The structured response from `tv ai --json`.
struct AIResponse: Codable {
    var summary: String
    var actions: [AIAction]
    var model: String?

    struct AIAction: Codable {
        var name: String
        var input: [String: AnyCodable]?
    }
}

/// Minimal AnyCodable to decode the heterogeneous `input` map of an AI action.
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        default: try c.encode("")
        }
    }
}
