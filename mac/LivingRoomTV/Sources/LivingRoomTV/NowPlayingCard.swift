import SwiftUI

/// Now Playing card — branded tinted background derived from the current app,
/// inset brand tile on the left, editorial text + animated EQ bars on the right.
/// Only rendered when the TV is on and an app is reported.
struct NowPlayingCard: View {
    @EnvironmentObject var store: StatusStore
    @State private var artwork: NSImage?
    @State private var lastArtKey: String = ""

    var body: some View {
        let s = store.status
        let tint = Theme.appTint(s?.app)
        HStack(alignment: .center, spacing: 14) {
            tile(for: s, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Now Playing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Text(primaryLabel(s))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtext(for: s))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                HStack(spacing: 6) {
                    eqBars(active: s?.playState == "playing", color: tint)
                    Text(stateLine(for: s))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(backgroundGradient(tint: tint))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The card is purely informational — no taps here. Make the whole
        // card hit-transparent so neither the blurred artwork backdrop nor
        // the clipped rounded-rect can absorb clicks meant for the rows
        // above or below it.
        .allowsHitTesting(false)
        .onAppear { refreshArtwork(for: s) }
        .onChange(of: artKey(s)) { _, _ in refreshArtwork(for: s) }
    }

    @ViewBuilder
    private func tile(for s: TVStatus?, tint: Color) -> some View {
        let app = StreamingApp.forStatusAppName(s?.app)
        ZStack {
            if let art = artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let logo = app?.logo {
                // Edge-to-edge brand logo — fills the whole tile.
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let app {
                LinearGradient(
                    colors: [app.color, app.color.opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Text(app.mark)
                    .font(.system(size: 32, weight: app.fontWeight))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            } else {
                Color.black.opacity(0.45)
                LucideIcon(name: "tv", size: 28)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func eqBars(active: Bool, color: Color) -> some View {
        // Static EQ bars — no infinite animation. A `repeatForever` animation
        // on top of `.glassEffect` + `GlassEffectContainer` was keeping the
        // main thread in constant SwiftUI re-render, which starved click/scroll
        // event processing and made the popup feel "stuck." Static heights
        // give the same visual read without the per-frame cost.
        let heights: [CGFloat] = active ? [6, 10, 4, 8] : [3, 3, 3, 3]
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(active ? 0.95 : 0.55))
                    .frame(width: 2, height: heights[i])
            }
        }
        .frame(height: 12, alignment: .bottom)
    }

    @ViewBuilder
    private func backgroundGradient(tint: Color) -> some View {
        // Prefer a heavily-blurred version of the current artwork so the card's
        // color vibe tracks what's actually playing. Fall back to the app's
        // brand tint when no artwork is available (Netflix/Prime DRM etc).
        //
        // HARD `.allowsHitTesting(false)` on the ZStack — without this, the
        // `.blur` + `.scaleEffect` pair promote the backdrop to an offscreen
        // rasterized layer that on macOS 26 beta silently absorbs clicks
        // above/around the card. The card itself (the HStack foreground) is
        // what should own any interaction; backgrounds never should.
        if let art = artwork {
            ZStack {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.35)
                    .blur(radius: 44)
                    .opacity(0.85)

                LinearGradient(
                    colors: [
                        .black.opacity(0.25),
                        .black.opacity(0.50),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                tint.opacity(0.10)
                    .blendMode(.overlay)
            }
            .allowsHitTesting(false)
        } else {
            LinearGradient(
                colors: [tint.opacity(0.72), tint.opacity(0.28), .black.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
    }

    private func primaryLabel(_ s: TVStatus?) -> String {
        s?.title ?? s?.series ?? s?.app ?? "Nothing playing"
    }

    private func subtext(for s: TVStatus?) -> String {
        // When title falls back to app, this becomes a light category tag; otherwise app name.
        if let title = s?.title, !title.isEmpty, let app = s?.app, app != title { return app }
        return "Streaming app"
    }

    private func stateLine(for s: TVStatus?) -> String {
        let base: String
        switch s?.playState {
        case "playing": base = "Playing"
        case "paused":  base = "Paused"
        default:        base = "Idle"
        }
        // Be honest when the LG panel is dark — user perceives this as "off"
        // even though audio keeps streaming.
        if s?.audioOnly == true {
            return "\(base) · Screen off"
        }
        return base
    }

    private func artKey(_ s: TVStatus?) -> String {
        "\(s?.app ?? "")|\(s?.title ?? "")|\(s?.series ?? "")|\(s?.isOn ?? false)"
    }

    private func refreshArtwork(for s: TVStatus?) {
        let key = artKey(s)
        if key == lastArtKey { return }
        lastArtKey = key
        guard s?.isOn == true, (s?.app != nil || s?.title != nil) else {
            artwork = nil
            return
        }
        Task { @MainActor in
            do {
                let data = try await TVCommandRunner.artwork(width: 200, height: 200)
                artwork = NSImage(data: data)
            } catch {
                artwork = nil
            }
        }
    }
}
