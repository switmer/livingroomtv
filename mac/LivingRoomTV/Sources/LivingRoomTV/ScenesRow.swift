import SwiftUI

/// Compact horizontal scene pills with per-pill loading state.
struct ScenesRow: View {
    @EnvironmentObject var store: StatusStore
    @EnvironmentObject var catalog: SceneCatalog
    // Set, not single optional — user can fire multiple scenes without the
    // second tap clobbering the first tile's loader state. Scenes are
    // independent CLI Task sequences, safe to overlap.
    @State private var pendingSceneIds: Set<String> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(catalog.scenes) { scene in
                    pill(for: scene)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func pill(for scene: RoomScene) -> some View {
        let isPending = pendingSceneIds.contains(scene.id)
        return Button(action: { fire(scene) }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(scene.tint.opacity(0.18))
                    if isPending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                            .tint(scene.tint)
                    } else {
                        LucideIcon(name: scene.symbol, size: 14)
                            .foregroundStyle(scene.tint)
                    }
                }
                .frame(width: 26, height: 26)

                Text(scene.shortLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(isPending ? 0.65 : 0.92))
                    .fixedSize(horizontal: true, vertical: false)

                // Tiny "user-made" dot — subtle provenance hint. Keeps the
                // user from wondering why long-press delete only works on
                // some pills.
                if scene.isUser {
                    Circle()
                        .fill(scene.tint.opacity(0.7))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .help(scene.isUser ? "\(scene.label) — right-click to delete" : scene.label)
        .contextMenu {
            if scene.isUser {
                Button(role: .destructive) {
                    delete(scene)
                } label: {
                    Label("Delete “\(scene.label)”", systemImage: "trash")
                }
            }
        }
    }

    private func delete(_ scene: RoomScene) {
        Task { @MainActor in
            do {
                try await TVCommandRunner.deleteScene(scene.id)
                await catalog.refresh()
                store.lastActionSummary = "🗑 Deleted scene: \(scene.label)"
            } catch {
                store.lastActionSummary = "✗ Delete \(scene.label): \(error.localizedDescription)"
            }
        }
    }

    private func fire(_ scene: RoomScene) {
        // Silent no-op if THIS scene is already running; don't gate on others.
        guard !pendingSceneIds.contains(scene.id) else { return }
        pendingSceneIds.insert(scene.id)
        let start = Date()
        Task { @MainActor in
            defer {
                // Enforce a short minimum visible time so fast scenes still show a confirm flash.
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < 0.25 {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64((0.25 - elapsed) * 1_000_000_000))
                        pendingSceneIds.remove(scene.id)
                    }
                } else {
                    pendingSceneIds.remove(scene.id)
                }
            }
            do {
                try await TVCommandRunner.scene(scene.id)
                store.lastActionSummary = "🎬 \(scene.label)"
            } catch {
                store.lastActionSummary = "✗ \(scene.label): \(error.localizedDescription)"
            }
        }
    }
}
