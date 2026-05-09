import SwiftUI

/// Only shown when TV_DEBUG=1 is in the environment. Strictly diagnostic.
struct DebugPanel: View {
    @EnvironmentObject var store: StatusStore
    @State private var expanded: Bool = false

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["TV_DEBUG"] == "1"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let cmd = store.lastCommand {
                    Text("cmd: \(cmd) → exit \(store.lastCommandExit.map(String.init) ?? "…")")
                }
                Text("conn: \(describe(store.connection))")
                if let raw = store.lastRawJSON {
                    Text(raw)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 4)
        } label: {
            Text("debug")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func describe(_ c: StatusStore.Connection) -> String {
        switch c {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected(let r): return "disconnected(\(r))"
        case .waitingForLockHolder(let pid): return "waitingForLockHolder(pid: \(pid.map(String.init) ?? "?"))"
        }
    }
}
