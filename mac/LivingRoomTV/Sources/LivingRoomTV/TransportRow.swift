import SwiftUI

/// Media transport row: skip-back + big play/pause + skip-forward.
/// Classic media-player layout, matches the target mockup.
struct TransportRow: View {
    @EnvironmentObject var store: StatusStore

    /// Optimistic local override — flips the icon the instant the user taps,
    /// without waiting for the 10s status tick. Cleared on `onChange` when the
    /// real status catches up, or on a safety-net timeout.
    @State private var pendingPlayState: String? = nil
    @State private var pendingClearTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            sideButton(icon: "skip-back", help: "Previous track") {
                store.perform("Previous") { try await TVCommandRunner.nav("previous"); return nil }
            }
            primaryButton
            sideButton(icon: "skip-forward", help: "Next track") {
                store.perform("Next") { try await TVCommandRunner.nav("next"); return nil }
            }
            Spacer()
        }
        .onChange(of: store.status?.playState) { _, newValue in
            // Real truth caught up — drop the optimistic override.
            if let p = pendingPlayState, p == newValue {
                pendingPlayState = nil
                pendingClearTask?.cancel()
            }
        }
    }

    private var effectivePlayState: String? {
        pendingPlayState ?? store.status?.playState
    }

    private var primaryButton: some View {
        let playing = effectivePlayState == "playing"
        let icon = playing ? "pause" : "play"
        return Button(action: togglePlayPause) {
            ZStack {
                Circle().fill(.white)
                LucideIcon(name: icon, size: 20)
                    .foregroundStyle(.black)
            }
            .frame(width: 52, height: 52)
            .shadow(color: .white.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help(playing ? "Pause" : "Play")
    }

    private func togglePlayPause() {
        // Flip the icon immediately based on what we *believe* is true right
        // now — the user's expectation is "tap pause → see pause" with zero
        // perceptual delay, even though the real status arrives up to 10s later.
        let current = effectivePlayState
        let target = (current == "playing") ? "paused" : "playing"
        pendingPlayState = target

        // Safety net: if the status never confirms (e.g. pyatv loses the
        // session, or we were already in the target state), clear after 4s so
        // the UI doesn't stay wrong forever.
        pendingClearTask?.cancel()
        pendingClearTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { pendingPlayState = nil }
            }
        }

        store.perform("Play/Pause") {
            try await TVCommandRunner.playPause()
            return nil
        }
    }

    private func sideButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                LucideIcon(name: icon, size: 16)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
