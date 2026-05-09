import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let popupWidth: CGFloat = 420

    enum SceneTint {
        case movie, kids, resume, off
        var color: Color {
            switch self {
            case .movie: return .indigo
            case .kids: return .orange
            case .resume: return .teal
            case .off: return .red
            }
        }
        var symbol: String {
            switch self {
            case .movie: return "film.fill"
            case .kids: return "teddybear.fill"
            case .resume: return "play.rectangle.fill"
            case .off: return "power"
            }
        }
        var label: String {
            switch self {
            case .movie: return "Movie"
            case .kids: return "Kids"
            case .resume: return "Resume TV"
            case .off: return "All Off"
            }
        }
        var scene: String {
            switch self {
            case .movie: return "movie"
            case .kids: return "kids"
            case .resume: return "resume"
            case .off: return "off"
            }
        }
    }

    /// A known-app icon tint so the placeholder card doesn't look like dead space
    /// for DRM-protected apps (Netflix/Prime) that don't expose artwork.
    static func appTint(_ app: String?) -> Color {
        StreamingApp.forStatusAppName(app)?.color ?? .secondary
    }
}

/// Brand/theme asset for a streaming app. Keyed primarily on bundle ID so
/// that display metadata survives renames / rebrandings (Apple's own apps do
/// this often). `name` is only used for fuzzy matching when the caller has
/// a display string instead of a bundle ID (e.g. pyatv reports "Netflix"
/// as the current app rather than "com.netflix.Netflix").
///
/// This is the UI/asset layer — it has no behavior. Behavior lives in the
/// `tv` CLI. These tiles render brand-consistent visuals without embedding
/// copyrighted wordmarks; when the user supplies their own PNG wordmark in
/// `Resources/AppLogos/<slug>.png` we render that instead of the letter mark.
struct StreamingApp: Identifiable, Hashable {
    let bundleId: String    // canonical key, e.g. "com.netflix.Netflix"
    let name: String        // display label
    let shortcut: String    // `tv <shortcut>` CLI alias
    let mark: String        // 1–3 character letter-mark for the tile (fallback when no logo asset)
    let color: Color        // brand color
    let fontWeight: Font.Weight

    var id: String { bundleId }

    /// Cached NSImage for the local PNG asset in the resource bundle, if
    /// present. Files live at Resources/logo-<shortcut>.png (personal-use
    /// assets, not committed). This is read from SwiftUI view bodies on
    /// every render of the apps row — caching is mandatory, not optional:
    /// uncached, every tile would cause a synchronous disk read + PNG
    /// decode on the main thread per re-render, which starves tap / scroll
    /// event processing and produces the "clicks don't work" symptom.
    @MainActor var logo: NSImage? { StreamingApp.cachedLogo(shortcut: shortcut) }

    // MainActor-isolated: SwiftUI view bodies run on the main actor, so
    // this matches the only expected access site and prevents accidental
    // background-thread mutation of the dict.
    @MainActor private static var logoCache: [String: NSImage?] = [:]

    @MainActor
    static func cachedLogo(shortcut: String) -> NSImage? {
        if let hit = logoCache[shortcut] { return hit }
        let image = loadLogoFromDisk(shortcut: shortcut)
        logoCache[shortcut] = image
        return image
    }

    /// Disk-read path — never call from a view body. Only `cachedLogo`
    /// uses this on first access per shortcut.
    private static func loadLogoFromDisk(shortcut: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: "logo-\(shortcut)",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    static let all: [StreamingApp] = [
        .init(bundleId: "com.netflix.Netflix",              name: "Netflix",     shortcut: "netflix",   mark: "N",  color: Color(hex: 0xE50914), fontWeight: .black),
        .init(bundleId: "com.disney.disneyplus",            name: "Disney+",     shortcut: "disney",    mark: "D+", color: Color(hex: 0x0E47A1), fontWeight: .bold),
        .init(bundleId: "com.wbd.stream",                   name: "HBO Max",     shortcut: "hbo",       mark: "M",  color: Color(hex: 0x002BE7), fontWeight: .black),
        .init(bundleId: "com.amazon.aiv.AIVApp",            name: "Prime Video", shortcut: "prime",     mark: "Pv", color: Color(hex: 0x00A8E1), fontWeight: .heavy),
        .init(bundleId: "com.hulu.plus",                    name: "Hulu",        shortcut: "hulu",      mark: "h",  color: Color(hex: 0x1CE783), fontWeight: .black),
        .init(bundleId: "com.cbsvideo.app",                 name: "Paramount+",  shortcut: "paramount", mark: "P+", color: Color(hex: 0x0064FF), fontWeight: .bold),
        .init(bundleId: "com.peacocktv.peacock",            name: "Peacock",     shortcut: "peacock",   mark: "P",  color: Color(hex: 0x000000), fontWeight: .black),
        .init(bundleId: "com.google.ios.youtubeunplugged",  name: "YouTube TV",  shortcut: "youtube",   mark: "▶",  color: Color(hex: 0xFF0000), fontWeight: .black),
        .init(bundleId: "com.apple.TVWatchList",            name: "Apple TV",    shortcut: "appletv",   mark: "tv", color: Color(hex: 0x1C1C1E), fontWeight: .semibold),
        .init(bundleId: "com.spotify.client",               name: "Spotify",     shortcut: "spotify",   mark: "♫",  color: Color(hex: 0x1DB954), fontWeight: .black),
        .init(bundleId: "com.apple.TVMusic",                name: "Music",       shortcut: "music",     mark: "♪",  color: Color(hex: 0xFA243C), fontWeight: .black),
    ]

    /// Bundle-ID lookup. Preferred path when the caller has a bundle identifier.
    static let byBundleId: [String: StreamingApp] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.bundleId, $0) }
    )

    /// Look up by bundle id first, then fall back to fuzzy name match.
    static func forBundleIdOrName(bundleId: String? = nil, name: String? = nil) -> StreamingApp? {
        if let bid = bundleId, let hit = byBundleId[bid] { return hit }
        guard let lower = name?.lowercased(), !lower.isEmpty else { return nil }
        // Exact-name wins over substring to avoid "TV" matching "Apple TV".
        if let exact = all.first(where: { $0.name.lowercased() == lower }) { return exact }
        return all.first { lower.contains($0.name.lowercased()) }
    }

    /// Convenience for callers that only have a display name (e.g. pyatv's `app` field).
    static func forStatusAppName(_ name: String?) -> StreamingApp? {
        forBundleIdOrName(bundleId: nil, name: name)
    }
}

extension Color {
    /// Color from a 0xRRGGBB int literal.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

// MARK: - Glass effect helpers

extension View {
    /// Apply Apple's liquid-glass effect on macOS 26+, fall back to
    /// ultra-thin material vibrancy on earlier systems. Clipped to the
    /// given shape with a hairline edge highlight on both paths so the
    /// two look consistent.
    /// Shell-level glass: used for the outer popup surface. Apple's liquid
    /// glass on macOS 26, vibrancy material on older systems. A hairline
    /// white stroke is added on both paths — 26's native material edge
    /// highlight is very subtle, so we help it read as a discrete floating
    /// plate against the desktop.
    @ViewBuilder
    func glassShellBackground<S: InsettableShape>(in shape: S) -> some View {
        // macOS 26 `.glassEffect` disabled — it (along with
        // `.containerBackground(for: .window)`, `NSVisualEffectView`, and
        // `GlassEffectContainer`) breaks MenuBarExtra hit testing on the
        // current Tahoe beta. Until Apple ships a fix, we use plain
        // `.ultraThinMaterial` everywhere. See ISSUES.md.
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }

    @ViewBuilder
    func glassPanelBackground<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

/// Container that groups multiple glass surfaces so they morph together on
/// macOS 26. Currently disabled — `GlassEffectContainer` triggers the same
/// MenuBarExtra hit-test regression as `.glassEffect` / `.containerBackground`.
/// Falls back to a plain VStack everywhere; we lose the morph-together feel
/// but gain reliable clicks. See ISSUES.md.
@ViewBuilder
func LiquidGlassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14, content: content)
}

/// Rounded material background used by cards and grouped rows.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
    }
}

extension View {
    func card(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(CardBackground(radius: radius))
    }
}
