import SwiftUI

@main
struct LivingRoomTVApp: App {
    @StateObject private var store = StatusStore()
    @StateObject private var catalog = SceneCatalog()

    var body: some Scene {
        MenuBarExtra {
            // Do NOT use `.containerBackground(.ultraThinMaterial, for: .window)`
            // here — it's the Apple-sanctioned API for MenuBarExtra(.window)
            // translucency, but on macOS 26 beta it installs an underlying
            // NSVisualEffectView that absorbs clicks in the top half of the
            // popup, same as our earlier manual attempt. Tracked in ISSUES.md.
            // Shell translucency is sacrificed for reliable clicks.
            MainView()
                .environmentObject(store)
                .environmentObject(catalog)
                // Heuristic 4: popup-open refresh. MenuBarExtra(.window)
                // instantiates MainView fresh on each open, so `.onAppear`
                // fires per-open. Fire a no-op `refresh` RPC whose side
                // effect is a fresh status line within ~200ms — the user
                // can never see a stale value through a freshly-opened popup.
                .onAppear { store.requestRefresh() }
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Dynamic menu bar label that reacts to the current status.
private struct MenuBarLabel: View {
    @EnvironmentObject var store: StatusStore

    var body: some View {
        let s = store.status
        if s?.isOn == true {
            HStack(spacing: 4) {
                Image(systemName: s?.sfSymbol ?? "tv.fill")
                Text(s?.menuBarLabel ?? "Living Room")
                    .lineLimit(1)
            }
        } else {
            Image(systemName: "tv")
        }
    }
}
