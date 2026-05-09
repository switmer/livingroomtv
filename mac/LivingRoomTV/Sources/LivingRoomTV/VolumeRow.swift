import SwiftUI

/// Volume row with optimistic updates. Drag/tap changes show instantly with a
/// subtle loader; the real LG-side value reconciles on the next status push.
///
/// Two visual modes driven by `status.volume_source`:
///   • "lg"       → mute + − + slider + + + live %   (true TV-speaker volume)
///   • "appletv"  → mute + − + label + +              (step-only; HDMI-CEC blind)
struct VolumeRow: View {
    @EnvironmentObject var store: StatusStore

    // Pending optimistic state — cleared when a real status update arrives
    // (via onChange), or after a short timeout if nothing comes back.
    @State private var pendingValue: Double? = nil
    @State private var isPending: Bool = false
    @State private var pendingClearTask: Task<Void, Never>? = nil

    // Slider drag state
    @State private var dragValue: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        let hasLG = store.status?.hasRealVolume == true
        Group {
            if hasLG { absoluteMode } else { stepMode }
        }
        .onChange(of: store.status?.volume) { _, newValue in
            // Real value arrived — clear optimistic state if it's within tolerance.
            guard let newValue else { return }
            if let p = pendingValue, abs(p - newValue) < 2 {
                pendingValue = nil
            }
        }
    }

    // MARK: - Computed display

    private var displayedValue: Double {
        if isDragging { return dragValue }
        if let p = pendingValue { return p }
        return store.status?.volume ?? 0
    }

    // MARK: - Absolute (LG) mode

    private var absoluteMode: some View {
        let v = displayedValue
        let pct = Int(v.rounded())
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                muteButton
                circleStepButton(icon: "minus") { bump(by: -1) }
                slider(value: v)
                circleStepButton(icon: "plus") { bump(by: +1) }
                HStack(spacing: 3) {
                    Text("\(pct)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary.opacity(isPending ? 0.55 : 0.85))
                        .frame(minWidth: 22, alignment: .trailing)
                    if isPending {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 10)
                    }
                }
            }
            HStack(spacing: 6) {
                LucideIcon(name: "volume-2", size: 10)
                    .foregroundStyle(.tertiary)
                Text("TV Speakers")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanelBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Step-only mode (no LG paired)

    private var stepMode: some View {
        HStack(spacing: 12) {
            muteButton
            circleStepButton(icon: "minus") { bumpStep(delta: -1) }
            Spacer()
            Text("TV Speakers")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            circleStepButton(icon: "plus") { bumpStep(delta: +1) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassPanelBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Components

    private var muteButton: some View {
        let muted = store.status?.muted == true
        return Button(action: toggleMute) {
            LucideIcon(name: muted ? "volume-x" : "volume-2", size: 17)
                .foregroundStyle(muted ? Color.red : .primary.opacity(0.82))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute" : "Mute")
    }

    private func circleStepButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(name: icon, size: 16)
                .foregroundStyle(.primary.opacity(0.88))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private func slider(value: Double) -> some View {
        GeometryReader { geo in
            let thumbX = max(0, geo.size.width * CGFloat(value / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(height: 4)
                Capsule()
                    .fill(.white.opacity(isPending ? 0.65 : 0.95))
                    .frame(width: max(4, thumbX), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: thumbX - 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        dragValue = min(100, max(0, Double(g.location.x / geo.size.width) * 100))
                    }
                    .onEnded { _ in
                        isDragging = false
                        commitAbsolute(dragValue)
                    }
            )
        }
        .frame(height: 14)
    }

    // MARK: - Actions (optimistic)

    private func commitAbsolute(_ target: Double) {
        let rounded = (target.rounded())
        setPending(rounded)
        Task { @MainActor in
            do {
                try await TVCommandRunner.setVolume(rounded)
                store.lastActionSummary = "Volume \(Int(rounded))%"
            } catch {
                store.lastActionSummary = "✗ Volume \(Int(rounded))%: \(error.localizedDescription)"
                pendingValue = nil
            }
            isPending = false
        }
    }

    private func bump(by delta: Int) {
        let current = Int(displayedValue.rounded())
        let target = min(100, max(0, current + delta))
        commitAbsolute(Double(target))
    }

    private func bumpStep(delta: Int) {
        // Step-only mode — no absolute target, just fire the remote key.
        isPending = true
        Task { @MainActor in
            do {
                if delta > 0 {
                    try await TVCommandRunner.volumeUp()
                } else {
                    try await TVCommandRunner.volumeDown()
                }
            } catch {
                store.lastActionSummary = "✗ Volume \(delta > 0 ? "+" : "−"): \(error.localizedDescription)"
            }
            isPending = false
        }
    }

    private func toggleMute() {
        let wasMuted = store.status?.muted == true
        isPending = true
        Task { @MainActor in
            do {
                if wasMuted {
                    try await TVCommandRunner.unmute()
                    store.lastActionSummary = "Unmuted"
                } else {
                    try await TVCommandRunner.mute()
                    store.lastActionSummary = "Muted"
                }
            } catch {
                store.lastActionSummary = "✗ Mute toggle: \(error.localizedDescription)"
            }
            isPending = false
        }
    }

    // MARK: - Pending reconciliation

    private func setPending(_ value: Double) {
        pendingValue = value
        isPending = true
        // Safety net: clear pending after 4s in case status never catches up.
        pendingClearTask?.cancel()
        pendingClearTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { pendingValue = nil }
            }
        }
    }
}
