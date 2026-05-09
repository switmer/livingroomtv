import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var store: StatusStore
    @EnvironmentObject var catalog: SceneCatalog
    @State private var showSettings: Bool = false
    @State private var powerPillHovered: Bool = false

    /// Last known title/app/series while the TV was on — so the Resume card
    /// in the off state has something to offer even after `power: off`.
    @State private var lastKnownApp: String? = nil
    @State private var lastKnownTitle: String? = nil
    @State private var lastKnownSeries: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .onChange(of: store.status?.app) { _, new in
                    if new != nil { lastKnownApp = new }
                }
                .onChange(of: store.status?.title) { _, new in
                    if new != nil { lastKnownTitle = new }
                }
                .onChange(of: store.status?.series) { _, new in
                    if new != nil { lastKnownSeries = new }
                }
            // Away > pending > displayOn > default-off, in priority order.
            // Away wins over everything — when we can't reach the TV at all,
            // the on/off signals are stale and misleading.
            if store.isAway {
                awayState
            } else if store.pendingPowerTarget == "off" {
                offState
            } else if store.pendingPowerTarget == "on"
                        || (store.status?.displayOn == true)
                        || (store.status?.audioOnly == true) {
                onState
            } else {
                offState
            }
            if DebugPanel.enabled {
                Divider().opacity(0.3)
                DebugPanel()
            }
            statusFooter
        }
        .padding(16)
        .frame(width: Theme.popupWidth)
        // No shell-level `.glassEffect` — per Apple, "glass cannot sample
        // other glass," and the LiquidGlassGroup wrapping Transport / Remote
        // / Volume is already a GlassEffectContainer. Shell translucency
        // comes from `.containerBackground(.ultraThinMaterial, for: .window)`
        // applied at the MenuBarExtra root in App.swift. Here we add just a
        // subtle warm tint + hairline stroke for identity.
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.06, blue: 0.09).opacity(0.14),
                            Color(red: 0.13, green: 0.08, blue: 0.10).opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    // MARK: - On state

    private var onState: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScenesRow()
            AppsMenu()
            if shouldShowNowPlaying {
                NowPlayingCard()
            }
            // Transport + Remote + Volume share one liquid-glass family so
            // these three surfaces morph/merge as one interactive cluster
            // instead of stacking as discrete rows. This is the single hero
            // glass zone — scenes/apps/AskAI stay matte as anchors.
            LiquidGlassGroup {
                VStack(alignment: .leading, spacing: 14) {
                    TransportRow()
                    RemotePad()
                    VolumeRow()
                }
            }
            if let msg = store.lastActionSummary {
                actionToast(msg)
            }
            if store.aiEnabled {
                AskAIField()
            }
        }
    }

    private var shouldShowNowPlaying: Bool {
        guard let s = store.status, s.isOn else { return false }
        return (s.app?.isEmpty == false) || (s.title?.isEmpty == false)
    }

    // MARK: - Away state

    /// Not on home network — the daemon's been disconnected >15s. All LAN
    /// paths are dead; only Apple's iCloud relay for Siri Shortcuts still
    /// works remotely. Show an honest "Away" panel with a small curated set
    /// of scene buttons routed through `shortcuts://run-shortcut?name=…`.
    /// If the user hasn't created a Shortcut with the matching name, the tap
    /// silently does nothing (macOS just doesn't launch anything).
    private var awayState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 12)
            ZStack {
                Circle().fill(.white.opacity(0.04))
                LucideIcon(name: "wifi", size: 22)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text("Away")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("Not on home network — use Siri Shortcuts for scenes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 8) {
                ForEach(catalog.scenes.prefix(4)) { scene in
                    awayShortcutButton(for: scene)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func awayShortcutButton(for scene: RoomScene) -> some View {
        Button(action: { runShortcut(named: scene.label) }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(scene.tint.opacity(0.22))
                    LucideIcon(name: scene.symbol, size: 14)
                        .foregroundStyle(scene.tint)
                }
                .frame(width: 32, height: 32)
                Text(scene.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer(minLength: 0)
                LucideIcon(name: "play", size: 12)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Run the '\(scene.label)' Shortcut")
    }

    private func runShortcut(named name: String) {
        // Apple's URL scheme — routes through iCloud when executed away from
        // home, which is exactly what we need. The Shortcuts app has to
        // contain a Shortcut with this literal name; otherwise nothing runs.
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Off state

    private var offState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 12)
            ZStack {
                Circle().fill(.white.opacity(0.04))
                LucideIcon(name: "tv-minimal", size: 22)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text("Living Room is off")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("Tap a scene to set the mood, or turn on manually")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Resume card — only shown when we have prior context to offer.
            if let resume = resumeCardModel {
                resumeCard(resume)
                    .padding(.horizontal, 4)
            }

            Button(action: {
                store.requestPowerChange("on")
            }) {
                HStack(spacing: 8) {
                    if store.pendingPowerTarget == "on" {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                        Text("Turning on…")
                    } else {
                        Text("Turn on")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 28)
                .padding(.vertical, 11)
                .background(Capsule().fill(.white.opacity(store.pendingPowerTarget == nil ? 1 : 0.7)))
                .shadow(color: .white.opacity(0.18), radius: 10, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(store.pendingPowerTarget != nil)

            // Compact scene pills — same catalog as the on-state.
            ScenesRow()
                .padding(.top, 4)

            if store.aiEnabled {
                AskAIField()
                    .padding(.top, 2)
            }
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Resume card (off-state)

    /// Non-nil when we have a remembered title/app to surface.
    private struct ResumeModel {
        let app: StreamingApp?      // for the tinted tile
        let label: String           // e.g. "Stranger Things" or "Netflix"
        let subtitle: String        // e.g. "Netflix" or "Streaming app"
    }

    private var resumeCardModel: ResumeModel? {
        let app = StreamingApp.forStatusAppName(lastKnownApp)
        if let title = lastKnownTitle, !title.isEmpty {
            return ResumeModel(app: app, label: title, subtitle: lastKnownApp ?? "")
        }
        if let series = lastKnownSeries, !series.isEmpty {
            return ResumeModel(app: app, label: series, subtitle: lastKnownApp ?? "")
        }
        if let appName = lastKnownApp, !appName.isEmpty {
            return ResumeModel(app: app, label: appName, subtitle: "Last used")
        }
        return nil
    }

    private func resumeCard(_ m: ResumeModel) -> some View {
        Button(action: {
            // Wake, then launch the last-used app. If we have a bundle id path,
            // we could do better here — for now "resume" = wake + launch app.
            if let app = m.app {
                store.requestPowerChange("on")
                Task { @MainActor in
                    try? await TVCommandRunner.openApp(app.shortcut)
                }
            } else {
                store.requestPowerChange("on")
            }
        }) {
            HStack(spacing: 10) {
                // Small tinted tile — logo if we have one, else letter mark.
                ZStack {
                    if let logo = m.app?.logo {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else if let app = m.app {
                        LinearGradient(
                            colors: [app.color, app.color.opacity(0.78)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Text(app.mark)
                            .font(.system(size: 13, weight: app.fontWeight))
                            .foregroundStyle(.white)
                    } else {
                        Color.white.opacity(0.08)
                        LucideIcon(name: "tv", size: 14)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Resume")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Text(m.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(1)
                    if !m.subtitle.isEmpty {
                        Text(m.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                LucideIcon(name: "play", size: 14)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Wake and reopen \(m.label)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))
                LucideIcon(name: "tv-minimal", size: 16)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.status?.device ?? "Living Room")
                    .font(.system(size: 17, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            connectionBadge
            Button(action: { showSettings.toggle() }) {
                ZStack {
                    Circle().fill(.white.opacity(0.06))
                    LucideIcon(name: "settings", size: 13)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                SettingsPopover()
                    .environmentObject(store)
            }
        }
    }

    private var subtitle: String {
        if store.isAway { return "Away · Siri Shortcuts only" }
        let device = store.status?.device ?? "Apple TV"
        let app = store.status?.app
        if let a = app, !a.isEmpty { return "\(device) · \(a)" }
        return device
    }

    @ViewBuilder
    private var connectionBadge: some View {
        // Away > pending > status (same priority as the body dispatcher).
        if store.isAway {
            pill(text: "Away", color: .orange)
        } else if store.pendingPowerTarget == "on" {
            pill(text: "Waking", color: .green)
        } else if store.pendingPowerTarget == "off" {
            pill(text: "Sleeping", color: .secondary)
        } else {
            switch store.connection {
            case .connecting:
                pill(text: "…", color: .secondary)
            case .connected:
                if let s = store.status {
                    if s.audioOnly {
                        pill(text: "Audio", color: .teal)
                    } else if s.displayOn {
                        pill(text: "On", color: .green)
                    } else if s.isOn {
                        pill(text: "Screen Off", color: .orange)
                    } else {
                        pill(text: "Off", color: .secondary)
                    }
                } else {
                    pill(text: "…", color: .secondary)
                }
            case .disconnected:
                pill(text: "Off", color: .orange)
            case .waitingForLockHolder:
                pill(text: "…", color: .secondary)
            }
        }
    }

    private func pill(text: String, color: Color) -> some View {
        // Tappable: toggle power. Uses the same loader/pending machinery as the
        // off-state Turn On button via store.requestPowerChange. When Away,
        // no tap — LAN commands won't reach the TV anyway.
        let currentlyOn = (store.status?.isOn == true) || (store.status?.audioOnly == true)
        return Button(action: {
            guard !store.isAway else { return }
            store.requestPowerChange(currentlyOn ? "off" : "on")
        }) {
            HStack(spacing: 5) {
                if store.pendingPowerTarget != nil || store.isSyncing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).tint(color)
                } else {
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(store.isSyncing && store.pendingPowerTarget == nil ? "Syncing" : text)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .foregroundStyle(color.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(powerPillHovered ? 0.18 : 0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(powerPillHovered ? 0.45 : 0.0), lineWidth: 0.5))
            .scaleEffect(powerPillHovered ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: powerPillHovered)
        }
        .buttonStyle(.plain)
        .disabled(store.pendingPowerTarget != nil || store.isAway)
        .onHover { hovering in powerPillHovered = hovering }
        .help(store.isAway ? "Away — LAN commands unavailable" : "Tap to toggle power")
    }

    // MARK: - Toast

    private func actionToast(_ msg: String) -> some View {
        HStack(spacing: 8) {
            LucideIcon(name: msg.hasPrefix("✗") ? "circle-alert" : "check", size: 11)
                .foregroundStyle(msg.hasPrefix("✗") ? .red : .green)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    // MARK: - Status footer

    private var statusFooter: some View {
        HStack(spacing: 6) {
            Spacer()
            if store.isSyncing {
                ProgressView().controlSize(.mini).scaleEffect(0.55).tint(footerColor)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(footerColor)
                    .frame(width: 5, height: 5)
            }
            Text(footerText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.none)
            Spacer()
        }
        .padding(.top, 2)
    }

    private var footerText: String {
        // While syncing, the displayed status may not be current — say so.
        if store.isSyncing {
            switch store.connection {
            case .connected: return "Syncing with the TV…"
            case .connecting, .disconnected, .waitingForLockHolder: break
            }
        }
        switch store.connection {
        case .connecting: return "Connecting…"
        case .connected:
            return store.status?.isOn == true ? "Connected via Wi-Fi" : "Standby"
        case .disconnected: return "Reconnecting…"
        case .waitingForLockHolder(let pid):
            return pid.map { "Another daemon owns the TV (pid \($0)) — waiting" }
                   ?? "Another daemon owns the TV — waiting"
        }
    }

    private var footerColor: Color {
        switch store.connection {
        case .connecting: return .yellow
        case .connected: return store.status?.isOn == true ? .green : .secondary
        case .disconnected: return .orange
        case .waitingForLockHolder: return .yellow
        }
    }

    // MARK: - Background

    /// A subtle warm tone sits behind the glass layer so the popup has a hint
    /// of the old dark-plum palette instead of being fully neutral-gray.
    /// Glass refracts what's behind it, so this color bleeds through softly.
    private var popupTintBacking: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.07, green: 0.06, blue: 0.09), location: 0.0),
                .init(color: Color(red: 0.09, green: 0.07, blue: 0.09), location: 0.55),
                .init(color: Color(red: 0.11, green: 0.07, blue: 0.09), location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
