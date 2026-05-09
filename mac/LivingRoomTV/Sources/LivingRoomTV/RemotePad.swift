import SwiftUI

/// Apple-Remote-app style D-pad: unified disc with four pie-slice tap regions
/// (entire wedge is pressable, not just the icon), hover highlights, big
/// white OK button, and three action cards below.
struct RemotePad: View {
    @EnvironmentObject var store: StatusStore
    @State private var expanded: Bool = false
    @State private var pendingKey: String? = nil
    @State private var hoveredKey: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 14 : 0) {
            header
            if expanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanelBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - Collapsed header

    private var header: some View {
        Button(action: { expanded.toggle() }) {
            HStack(spacing: 8) {
                LucideIcon(name: "chevron-right", size: 12)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Remote")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                if !expanded {
                    Text("Tap to expand")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded content

    private var content: some View {
        VStack(spacing: 16) {
            dpad
            bottomRow
        }
        .padding(.top, 4)
    }

    // MARK: - D-pad disc

    private let diameter: CGFloat = 250
    private let centerSize: CGFloat = 92

    private var dpad: some View {
        ZStack {
            // Backing disc — subtle radial gradient so the center feels slightly
            // recessed into the panel.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.015), Color.white.opacity(0.05)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.05), lineWidth: 1))
                .allowsHitTesting(false)

            // Quadrant dividers — two diagonals forming an X.
            DPadDividers(diameter: diameter)

            // Four visual wedges. Hit testing is centralized below.
            wedge(key: "up",    startDeg: 225, endDeg: 315, iconOffset: CGSize(width: 0, height: -diameter/2 + 28), icon: "chevron-up")
            wedge(key: "right", startDeg: 315, endDeg: 45,  iconOffset: CGSize(width:  diameter/2 - 28, height: 0), icon: "chevron-right")
            wedge(key: "down",  startDeg: 45,  endDeg: 135, iconOffset: CGSize(width: 0, height:  diameter/2 - 28), icon: "chevron-down")
            wedge(key: "left",  startDeg: 135, endDeg: 225, iconOffset: CGSize(width: -diameter/2 + 28, height: 0), icon: "chevron-left")

            // Single hit surface for the annulus — classifies cursor by angle
            // into one of the four wedge keys. Using `.onContinuousHover` with
            // a coordinate space is the only reliable way to scope hover to a
            // non-rectangular sub-region per wedge; `.onHover` on per-wedge
            // views uses each view's rect (all four are diameter×diameter and
            // overlap) so the z-top wedge would steal every hover.
            Color.clear
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        hoveredKey = wedgeKey(at: point) ?? (hoveredKey == "select" ? "select" : nil)
                    case .ended:
                        if hoveredKey != "select" { hoveredKey = nil }
                    }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    if let key = wedgeKey(at: point) { send(key) }
                }

            // Center OK button on top of the hit surface — its own gestures
            // live on the button itself so the cursor-classifier above
            // reports nil inside the center hole anyway.
            okButton
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func wedge(key: String, startDeg: Double, endDeg: Double, iconOffset: CGSize, icon: String) -> some View {
        let isHovered = (hoveredKey == key)
        let isPending = (pendingKey == key)
        let shape = WedgeShape(
            startAngle: .degrees(startDeg),
            endAngle: .degrees(endDeg),
            innerRadius: centerSize / 2 + 6
        )
        // Visual-only: hit testing is centralized on the dpad ZStack via
        // `.onContinuousHover` + angle classification. Attaching per-wedge
        // `.onHover` doesn't work because `.onHover` uses the view's frame,
        // not `.contentShape` — all four wedges share the diameter×diameter
        // frame, so the top-of-z-stack wedge absorbs every hover.
        ZStack {
            shape
                .fill(Color.white.opacity(isPending ? 0.09 : (isHovered ? 0.05 : 0.0)))
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                .animation(.easeInOut(duration: 0.12), value: isPending)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .offset(iconOffset)
            } else {
                LucideIcon(name: icon, size: 22)
                    .foregroundStyle(.white.opacity(isHovered ? 1.0 : 0.85))
                    .offset(iconOffset)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    /// Classify a cursor point (in the dpad's local coord space) into a
    /// wedge key, or nil if outside the annulus.
    private func wedgeKey(at point: CGPoint) -> String? {
        let cx = diameter / 2
        let cy = diameter / 2
        let dx = point.x - cx
        let dy = point.y - cy
        let dist = sqrt(dx * dx + dy * dy)
        let inner = centerSize / 2 + 6
        let outer = diameter / 2
        guard dist >= inner && dist <= outer else { return nil }
        // 0° = east, 90° = south (SwiftUI's y-down convention — matches WedgeShape).
        var deg = atan2(dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        if deg >= 225 && deg < 315 { return "up" }
        if deg >= 135 && deg < 225 { return "left" }
        if deg >= 45 && deg < 135 { return "down" }
        return "right"  // 315°–360° and 0°–45°
    }

    private var okButton: some View {
        let isPending = (pendingKey == "select")
        let isHovered = (hoveredKey == "select")
        return Button(action: { send("select") }) {
            ZStack {
                Circle()
                    .fill(.white)
                    .shadow(color: .white.opacity(isHovered ? 0.35 : 0.18), radius: isHovered ? 18 : 14)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                    .scaleEffect(isHovered ? 1.03 : 1.0)
                    .animation(.easeInOut(duration: 0.12), value: isHovered)
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                } else {
                    Text("OK")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.black.opacity(0.82))
                        .tracking(1)
                }
            }
            .frame(width: centerSize, height: centerSize)
        }
        .buttonStyle(.plain)
        .disabled(pendingKey != nil)
        .onHover { hovering in hoveredKey = hovering ? "select" : (hoveredKey == "select" ? nil : hoveredKey) }
    }

    // MARK: - Bottom action row (Back / Home / Siri)

    private var bottomRow: some View {
        HStack(spacing: 10) {
            actionCard(title: "Back", icon: "chevrons-left", key: "menu")
            actionCard(title: "Home", icon: "house", key: "home")
            siriCard
        }
    }

    private func actionCard(title: String, icon: String, key: String) -> some View {
        let isPending = (pendingKey == key)
        let isHovered = (hoveredKey == key)
        return Button(action: { send(key) }) {
            VStack(spacing: 4) {
                if isPending {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(height: 18)
                } else {
                    LucideIcon(name: icon, size: 16)
                        .foregroundStyle(.white.opacity(isHovered ? 1.0 : 0.85))
                        .frame(height: 18)
                }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(isHovered ? 0.18 : 0.07), lineWidth: 0.5)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(pendingKey != nil)
        .onHover { hovering in hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey) }
    }

    @State private var siriPending: Bool = false
    private var siriCard: some View {
        let isHovered = (hoveredKey == "siri")
        return Button(action: invokeSiri) {
            VStack(spacing: 4) {
                if siriPending {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .tint(.purple)
                        .frame(height: 18)
                } else {
                    LucideIcon(name: "sparkles", size: 16)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .pink],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(height: 18)
                }
                Text("Siri")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.92))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.purple.opacity(isHovered ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.purple.opacity(isHovered ? 0.55 : 0.35), lineWidth: 0.75)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(siriPending)
        .onHover { hovering in hoveredKey = hovering ? "siri" : (hoveredKey == "siri" ? nil : hoveredKey) }
        .help("Run the macOS ‘TV’ Shortcut — dictation → tv siri → AI planner")
    }

    // MARK: - Dispatch

    private func send(_ key: String) {
        guard pendingKey == nil else { return }
        pendingKey = key
        let start = Date()
        Task { @MainActor in
            defer {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < 0.2 {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64((0.2 - elapsed) * 1_000_000_000))
                        pendingKey = nil
                    }
                } else {
                    pendingKey = nil
                }
            }
            do {
                try await TVCommandRunner.nav(key)
            } catch {
                store.lastActionSummary = "✗ Remote \(key): \(error.localizedDescription)"
            }
        }
    }

    /// Invoke the user's macOS "TV" Shortcut via URL scheme. The URL scheme is
    /// more reliable than the `shortcuts` CLI — it survives rename quirks and
    /// just hands control to the Shortcuts app, which runs the flow including
    /// its dictation step.
    private func invokeSiri() {
        guard !siriPending else { return }
        siriPending = true
        Task { @MainActor in
            defer { siriPending = false }
            // Primary: Shortcuts URL scheme.
            if let url = URL(string: "shortcuts://run-shortcut?name=TV") {
                NSWorkspace.shared.open(url)
                return
            }
            // Fallback: `shortcuts` CLI (needs exact name match).
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            proc.arguments = ["run", "TV"]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    store.lastActionSummary = "✗ Siri: Shortcut named ‘TV’ not found"
                }
            } catch {
                store.lastActionSummary = "✗ Siri: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Wedge shape (pie slice with hollow center)

/// A pie-slice shape with a hollow center, used for the D-pad's four tap
/// regions. Angles are in degrees, 0° = right (east), 90° = down (south).
/// `innerRadius` carves out the middle so the OK button can sit on top
/// without competing for taps.
private struct WedgeShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2

        // Outer arc, start → end
        path.addArc(
            center: center,
            radius: outer,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        // Line to inner arc start
        let endRad = CGFloat(endAngle.radians)
        path.addLine(to: CGPoint(
            x: center.x + cos(endRad) * innerRadius,
            y: center.y + sin(endRad) * innerRadius
        ))
        // Inner arc, end → start (reverse direction)
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - X-shaped quadrant dividers

private struct DPadDividers: View {
    let diameter: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let r = diameter / 2 - 2
            let cx = size.width / 2
            let cy = size.height / 2
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.06))
            for angle in stride(from: 45.0, to: 360.0, by: 90.0) {
                let rad = CGFloat(angle * .pi / 180)
                let x1 = cx + cos(rad) * CGFloat(18)
                let y1 = cy + sin(rad) * CGFloat(18)
                let x2 = cx + cos(rad) * r
                let y2 = cy + sin(rad) * r
                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
                ctx.stroke(path, with: stroke, lineWidth: 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}
