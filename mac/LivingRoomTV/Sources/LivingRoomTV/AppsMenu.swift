import SwiftUI

/// Horizontal scrolling apps strip. Each tile is a brand-tinted square with
/// the app's letter mark. The currently-active app (per live status) gets a
/// small dot indicator.
struct AppsMenu: View {
    @EnvironmentObject var store: StatusStore
    // Set, not single optional — multiple tiles can be pending concurrently
    // without overwriting each other's loader state.
    @State private var pendingBundleIds: Set<String> = []
    @State private var pendingSearch: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                Text("All")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(StreamingApp.all) { app in
                        appTile(app)
                    }
                    searchTile
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func appTile(_ app: StreamingApp) -> some View {
        let current = isCurrent(app)
        let logo = app.logo
        let isPending = pendingBundleIds.contains(app.bundleId)
        return Button(action: { fireOpen(app) }) {
            VStack(spacing: 4) {
                ZStack {
                    if let logo {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(
                            colors: [app.color, app.color.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Text(app.mark)
                            .font(.system(size: app.mark.count > 1 ? 16 : 22, weight: app.fontWeight))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.30), radius: 1.5, y: 0.5)
                    }
                    // Loader overlay while this tile's launch is in flight.
                    if isPending {
                        Color.black.opacity(0.55)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: app.color.opacity(0.35), radius: 6, y: 2)
                .opacity(isPending ? 0.92 : 1.0)

                Text(app.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if current {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 4, height: 4)
                } else {
                    Color.clear.frame(height: 4)
                }
            }
            .frame(width: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .help("Open \(app.name)")
    }

    private var searchTile: some View {
        Button(action: fireSearch) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    if pendingSearch {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        LucideIcon(name: "search", size: 18)
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
                .frame(width: 54, height: 54)
                Text("Search")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                Color.clear.frame(height: 4)
            }
            .frame(width: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Global search")
    }

    private func isCurrent(_ app: StreamingApp) -> Bool {
        guard let status = store.status?.app else { return false }
        return status.lowercased() == app.name.lowercased()
    }

    // MARK: - Actions

    private func fireOpen(_ app: StreamingApp) {
        // Allow re-tap to be a no-op while this specific tile's launch is
        // still in flight, but don't block other tiles.
        guard !pendingBundleIds.contains(app.bundleId) else { return }
        pendingBundleIds.insert(app.bundleId)
        let start = Date()
        Task { @MainActor in
            defer { clearAfterMinimum(start: start) { pendingBundleIds.remove(app.bundleId) } }
            do {
                try await TVCommandRunner.openApp(app.shortcut)
                store.lastActionSummary = "📺 \(app.name)"
            } catch {
                store.lastActionSummary = "✗ \(app.name): \(error.localizedDescription)"
            }
        }
    }

    private func fireSearch() {
        guard !pendingSearch else { return }
        pendingSearch = true
        let start = Date()
        Task { @MainActor in
            defer { clearAfterMinimum(start: start) { pendingSearch = false } }
            do {
                try await TVCommandRunner.openApp("search")
                store.lastActionSummary = "🔎 Search"
            } catch {
                store.lastActionSummary = "✗ Search: \(error.localizedDescription)"
            }
        }
    }

    /// Keep the pending state visible at least ~0.25s so fast actions still flash a confirm.
    @MainActor
    private func clearAfterMinimum(start: Date, clear: @escaping @MainActor () -> Void) {
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.25 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((0.25 - elapsed) * 1_000_000_000))
                clear()
            }
        } else {
            clear()
        }
    }
}
