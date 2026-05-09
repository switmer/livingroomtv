import Foundation
import SwiftUI

/// Subscribes to `tv watch --json`, parses each JSON line, publishes to SwiftUI.
/// Separate from action execution — this object never mutates the TV.
@MainActor
final class StatusStore: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case connected
        case disconnected(reason: String)
        /// Another `tv watch` process already owns the per-device lock. We're
        /// not reconnecting in the error sense — we're politely waiting for
        /// the holder to exit before taking over.
        case waitingForLockHolder(pid: Int?)
    }

    @Published var status: TVStatus?
    @Published var connection: Connection = .connecting {
        didSet {
            guard oldValue != connection else { return }
            updateAwayState()
        }
    }

    /// Last action's result surfaced back to the UI (for the bottom status row).
    @Published var lastActionSummary: String?
    @Published var isBusy: Bool = false

    /// "on" or "off" while a power transition is in flight. Cleared when a
    /// status update arrives with matching power, or after a timeout.
    @Published var pendingPowerTarget: String?

    /// True when the popup should render the Away state — the daemon has been
    /// disconnected for 15+ seconds, which almost always means we're off the
    /// home network (Apple TV / LG both only reachable on LAN). Flips back to
    /// false as soon as the daemon reconnects.
    @Published var isAway: Bool = false
    private var awayTask: Task<Void, Never>?

    private func updateAwayState() {
        awayTask?.cancel()
        switch connection {
        case .connected, .connecting, .waitingForLockHolder:
            // `.waitingForLockHolder` doesn't mean we're off-network; a daemon
            // exists on the machine, it's just owned by another process.
            isAway = false
            pendingAwayReason = nil
        case .disconnected:
            // 8s instead of 15s — snappier flip without being twitchy during
            // a brief daemon restart (restart backoff caps at 15s but most
            // reconnects happen in 1–3s).
            awayTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run { self?.isAway = true }
                }
            }
        }
    }

    /// Last reason the popup flipped to Away (for diagnostics / UI copy).
    @Published var pendingAwayReason: String?

    /// True when an Anthropic API key is configured (env var or
    /// ~/.config/tv/anthropic_api_key). Drives whether the AskAI input is
    /// shown in the popup. Refreshed on launch and after Settings edits.
    @Published var aiEnabled: Bool = false

    /// Probe the CLI for AI-key status. Cheap — `tv ai-status --json` doesn't
    /// import the anthropic SDK. Safe to call from the main actor; the work
    /// hops to a background subprocess.
    func refreshAIStatus() {
        Task { @MainActor in
            struct AIStatus: Decodable { let configured: Bool }
            do {
                let s: AIStatus = try await TVCommandRunner.runJSON(["ai-status", "--json"])
                aiEnabled = s.configured
            } catch {
                // Treat any failure (CLI missing, older CLI without the
                // command, JSON shape drift) as "not configured" — the AI
                // field hides itself, which is the safe default.
                aiEnabled = false
            }
        }
    }

    /// Hard-flip to Away when a CLI command just told us the device isn't
    /// reachable — the error is a stronger signal than the time-based
    /// disconnect heuristic. Cancels any pending power transition since it
    /// obviously didn't happen.
    func reportUnreachable(reason: String) {
        awayTask?.cancel()
        isAway = true
        pendingAwayReason = reason
        pendingPowerTarget = nil
    }

    /// Inspect an action error to decide if it means "off home network" vs.
    /// some other kind of failure. Conservative: only flips Away on signals
    /// that clearly mean the device isn't on the LAN.
    func looksUnreachable(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("not found")
            || msg.contains("unreachable")
            || msg.contains("no route")
            || msg.contains("no such host")
            || msg.contains("connection refused")
            || msg.contains("cannot find device")
    }

    /// Debug telemetry (gated by TV_DEBUG=1 in the UI).
    @Published var lastRawJSON: String?
    @Published var lastCommand: String?
    @Published var lastCommandExit: Int32?

    private var process: Process?
    private var readerTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartAttempts: Int = 0

    // Daemon RPC — stdin write handle + pending-response map keyed by UUID.
    private var stdinHandle: FileHandle?
    private var pendingRPC: [UUID: CheckedContinuation<[String: Any], Error>] = [:]

    // Heuristic 3: freshness watchdog. A connected daemon that stops emitting
    // status (silent zombie — Python task stuck, pyatv hung below our Python
    // timeout) should be killed and respawned. `lastStatusAt` updates on
    // every status line; the watchdog task kills `process` if we go too
    // long without one while `connection == .connected`.
    private var lastStatusAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?
    private let watchdogStaleThreshold: TimeInterval = 25.0  // >2× tick interval

    // Syncing state — surfaces to the UI as a brief spinner on the power
    // pill + footer dot. True while we're between a fired `refresh` and
    // the next status line (with a 150ms debounce so a fast refresh doesn't
    // flash), OR when `lastStatusAt` is older than `syncingStaleFloor` and
    // the connection is supposedly `.connected` (the displayed state is
    // technically stale; tell the user).
    @Published var isSyncing: Bool = false
    private var syncingShowTask: Task<Void, Never>?
    private var syncingClearTask: Task<Void, Never>?
    private let syncingDebounce: TimeInterval = 0.15
    private let syncingFailSafe: TimeInterval = 2.0
    private let syncingStaleFloor: TimeInterval = 15.0

    // Daemon-lock coordination. When the Python `tv watch` we spawn finds
    // another daemon already holding the lock, it emits a `daemon_error`
    // line and exits 0. These flags let `consume()` tell the reader that
    // the upcoming stream-end is NOT a crash so `scheduleRestart` shouldn't
    // burn exponential backoff on it.
    private var alreadyRunningHolder: Int?
    private var expectClosedByDaemonError: Bool = false
    private var deviceIdForLock: String = "default"
    private var lockWaitTask: Task<Void, Never>?

    init() {
        // Auto-start on construction so the menu bar label is live before the popup opens.
        start()
        refreshAIStatus()
    }

    func start() {
        stop()
        restartAttempts = 0
        launch()
    }

    func stop() {
        restartTask?.cancel()
        readerTask?.cancel()
        lockWaitTask?.cancel()
        watchdogTask?.cancel()
        restartTask = nil
        readerTask = nil
        lockWaitTask = nil
        watchdogTask = nil
        // Resolve any outstanding RPC continuations so callers fall back cleanly.
        failAllPendingRPC(reason: "daemon stopping")
        stdinHandle = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        TVCommandRunner.rpcSender = nil
    }

    private func launch() {
        // Reset daemon-error flags at the start of every spawn attempt.
        expectClosedByDaemonError = false
        alreadyRunningHolder = nil

        // Phase 3: skip spawn-just-to-exit when another daemon already holds
        // the lock. Read the lockfile; if the owner PID is alive, go straight
        // to the Phase-2 wait loop instead of firing up a doomed subprocess.
        if let holder = readLockHolder(), pidIsAlive(holder) {
            alreadyRunningHolder = holder
            connection = .waitingForLockHolder(pid: holder)
            waitForHolder(pid: holder)
            return
        }

        let path = TVCommandRunner.binaryPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            connection = .disconnected(reason: "tv CLI not found at \(path)")
            scheduleRestart()
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        // 10s tick balances freshness (app changes, out-of-band volume changes)
        // against CPU cost of repeated status polls.
        proc.arguments = ["watch", "--tick", "10"]
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = stdin

        do {
            try proc.run()
        } catch {
            connection = .disconnected(reason: "launch failed: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        process = proc
        connection = .connecting
        stdinHandle = stdin.fileHandleForWriting

        // Wire TVCommandRunner's fast-path to this daemon.
        TVCommandRunner.rpcSender = { [weak self] cmd, args in
            try await self?.sendRPC(cmd: cmd, args: args) ?? [:]
        }

        let handle = stdout.fileHandleForReading
        readerTask = Task { [weak self] in
            await self?.consume(handle: handle)
        }
        lastStatusAt = Date()
        startWatchdog()
    }

    // MARK: - Heuristic 3: freshness watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // poll every 2s (quick syncing flip)
                if Task.isCancelled { return }
                guard let self else { return }
                await MainActor.run {
                    guard case .connected = self.connection else {
                        // Not connected — clear any syncing indicator so the
                        // primary state (connecting / disconnected) dominates.
                        if self.isSyncing { self.isSyncing = false }
                        return
                    }
                    let gap = Date().timeIntervalSince(self.lastStatusAt)
                    // If the last status is older than the "stale floor" but
                    // still under the zombie threshold, flag syncing so the
                    // UI indicates "displayed state may not be current".
                    if gap > self.syncingStaleFloor && gap <= self.watchdogStaleThreshold {
                        if !self.isSyncing { self.isSyncing = true }
                    }
                    if gap > self.watchdogStaleThreshold {
                        // Daemon is a zombie — connected stream but no data.
                        // Nuke the process; `consume()` will hit stream-end
                        // and `scheduleRestart` spawns a fresh one.
                        NSLog("[StatusStore] watchdog: no status for \(Int(gap))s — restarting daemon")
                        if let p = self.process, p.isRunning {
                            p.terminate()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Heuristic 4: force-refresh on popup open

    /// Public hook for the menu-bar popup to call when it becomes visible.
    /// Fires a no-op `refresh` RPC whose side effect is that the daemon
    /// pushes a fresh status line within ~200ms. The user can never see a
    /// stale value through a freshly-opened popup.
    func requestRefresh() {
        guard stdinHandle != nil else { return }
        beginSyncing()
        Task { @MainActor in
            _ = try? await sendRPC(cmd: "refresh", args: [:])
        }
    }

    /// Enter the "syncing" state with a 150ms debounce and a 2s fail-safe.
    /// The debounce means a fast refresh (common case) never flashes a
    /// spinner; only genuinely slow cases surface the loading state.
    /// `noteStatusArrived()` cancels both tasks and flips `isSyncing` off.
    private func beginSyncing() {
        syncingShowTask?.cancel()
        syncingClearTask?.cancel()
        syncingShowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.syncingDebounce ?? 0.15) * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.isSyncing = true }
        }
        syncingClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.syncingFailSafe ?? 2.0) * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.isSyncing = false }
        }
    }

    private func noteStatusArrived() {
        syncingShowTask?.cancel()
        syncingClearTask?.cancel()
        if isSyncing { isSyncing = false }
    }

    private func consume(handle: FileHandle) async {
        do {
            for try await rawLine in handle.bytes.lines {
                if Task.isCancelled { return }
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }

                // Type-dispatched envelope: "status" | "rpc_response" | "daemon_error" | (legacy: no type = status)
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = obj["type"] as? String
                {
                    if type == "rpc_response" {
                        handleRPCResponse(obj)
                        continue
                    }
                    // Phase 1: daemon refused to start because another one owns
                    // the per-device lock. Record the holder's PID so the
                    // stream-end path below can hand off to the Phase-2 wait
                    // loop instead of burning exponential backoff.
                    if type == "daemon_error" {
                        let code = obj["code"] as? String ?? ""
                        let holderPID = (obj["holder"] as? [String: Any])?["pid"] as? Int
                        if code == "already_running" {
                            alreadyRunningHolder = holderPID
                            expectClosedByDaemonError = true
                        }
                        continue
                    }
                }

                // Everything else is a status update (covers both typed "status" and legacy bare).
                do {
                    let s = try JSONDecoder().decode(TVStatus.self, from: data)
                    status = s
                    lastRawJSON = trimmed
                    restartAttempts = 0
                    lastStatusAt = Date()   // Watchdog freshness heartbeat.
                    noteStatusArrived()     // Clears syncing indicator.
                    if connection != .connected { connection = .connected }
                } catch {
                    continue
                }
            }
        } catch {
            // Stream read error; fall through to dispatch below.
        }
        // Stream ended. Dispatch: lock-collision → wait; everything else →
        // exponential reconnect.
        failAllPendingRPC(reason: "watch stream ended")
        if expectClosedByDaemonError, let holder = alreadyRunningHolder {
            connection = .waitingForLockHolder(pid: holder)
            waitForHolder(pid: holder)
        } else {
            connection = .disconnected(reason: "watch stream ended")
            scheduleRestart()
        }
    }

    // MARK: - RPC

    enum RPCError: Error, LocalizedError {
        case daemonUnavailable
        case timeout
        case serverError(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .daemonUnavailable: return "daemon not running"
            case .timeout:           return "RPC timeout"
            case .serverError(let s): return "RPC error: \(s)"
            case .invalidResponse:   return "malformed RPC response"
            }
        }
    }

    /// Send an RPC request to the live daemon and await the matching response.
    /// Throws RPCError on any failure; TVCommandRunner.runFast handles fallback.
    func sendRPC(cmd: String, args: [String: Any]) async throws -> [String: Any] {
        guard let handle = stdinHandle else { throw RPCError.daemonUnavailable }
        let id = UUID()
        let req: [String: Any] = [
            "type": "rpc_request",
            "v": 1,
            "id": id.uuidString,
            "cmd": cmd,
            "args": args,
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: req) else {
            throw RPCError.invalidResponse
        }
        payload.append(0x0A)  // '\n'

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pendingRPC[id] = continuation
            do {
                try handle.write(contentsOf: payload)
            } catch {
                pendingRPC.removeValue(forKey: id)
                continuation.resume(throwing: RPCError.daemonUnavailable)
                return
            }
            // 3s timeout — daemon actions should complete in ~100ms, anything
            // longer usually means a stuck connection; fall back to subprocess.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let c = self?.pendingRPC.removeValue(forKey: id) {
                    c.resume(throwing: RPCError.timeout)
                }
            }
        }
    }

    private func handleRPCResponse(_ obj: [String: Any]) {
        guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        guard let continuation = pendingRPC.removeValue(forKey: id) else { return }
        if (obj["ok"] as? Bool) == true {
            let result = (obj["result"] as? [String: Any]) ?? [:]
            continuation.resume(returning: result)
        } else {
            let msg = (obj["error"] as? String) ?? "unknown"
            continuation.resume(throwing: RPCError.serverError(msg))
        }
    }

    private func failAllPendingRPC(reason: String) {
        let pending = pendingRPC
        pendingRPC.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: RPCError.serverError(reason))
        }
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartAttempts += 1
        // Exponential backoff capped at 15s
        let delay = min(15.0, pow(2.0, Double(min(restartAttempts, 4))))
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.launch() }
        }
    }

    // MARK: - Phase 2: lock-holder wait

    /// Poll the lock holder's PID every 1s. When it dies (or 60s elapse),
    /// relaunch. Any normal `stop()` cancels this task.
    private func waitForHolder(pid: Int) {
        lockWaitTask?.cancel()
        lockWaitTask = Task { [weak self] in
            for _ in 0..<60 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if !(self?.pidIsAlive(pid) ?? false) {
                    await MainActor.run { self?.launch() }
                    return
                }
            }
            // Holder looks immortal. Fall back to the normal exponential
            // reconnect loop so we don't get stuck forever.
            await MainActor.run {
                self?.connection = .disconnected(reason: "lock holder did not release")
                self?.scheduleRestart()
            }
        }
    }

    // MARK: - Lockfile helpers

    /// Path of the per-device lockfile written by `tv/daemon_lock.py`.
    /// Must track the Python side's naming: `watch-<device>.lock` under
    /// `$TV_CONFIG_DIR ?? ~/.config/tv`, with `default` when no device id.
    private var lockfileURL: URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["TV_CONFIG_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/tv", isDirectory: true)
        }
        let safe = deviceIdForLock.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("watch-\(safe).lock")
    }

    /// Parse the lockfile and return the holder PID, or nil if absent/unreadable.
    private func readLockHolder() -> Int? {
        let url = lockfileURL
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int, pid > 0
        else { return nil }
        return pid
    }

    /// `kill(pid, 0)` — nonzero return + ESRCH means the process is gone.
    /// Any other error (EPERM = different user) is treated as "alive".
    private func pidIsAlive(_ pid: Int) -> Bool {
        if pid <= 0 { return false }
        let rc = kill(pid_t(pid), 0)
        if rc == 0 { return true }
        return errno != ESRCH
    }

    // MARK: - Action wrapper

    /// Fire a power-change and keep `pendingPowerTarget` set until the status
    /// stream reports the TV has actually reached the target state. Gives the
    /// UI a real "wake is in progress" window to show a loader.
    func requestPowerChange(_ target: String) {
        pendingPowerTarget = target
        Task { @MainActor in
            do {
                try await TVCommandRunner.run([target == "on" ? "on" : "off"])
                lastActionSummary = target == "on" ? "Waking Living Room…" : "Going to sleep…"
            } catch {
                // If the CLI says it can't find the device, we're off-network.
                // Flip to Away right away instead of waiting on the 8s heuristic;
                // the user gets honest UI instead of a confusing Waking pill
                // that silently resolves to a cryptic error toast.
                if looksUnreachable(error) {
                    reportUnreachable(reason: "Couldn't reach the TV — not on home network")
                    lastActionSummary = "Not on home network — use Siri Shortcuts"
                } else {
                    lastActionSummary = "✗ Power \(target): \(error.localizedDescription)"
                }
                pendingPowerTarget = nil
                return
            }
            // Poll the composite display state — `power` alone lies during
            // Spotify's music-mode (Apple TV stays awake, LG panel dark), so
            // matching on `displayOn` is the truth.
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                let reached = (target == "on") ? (status?.displayOn == true) : (status?.displayOn == false)
                if reached { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            pendingPowerTarget = nil
        }
    }

    /// Runs `tv ...` and publishes a short summary to `lastActionSummary`.
    ///
    /// If `action` returns a string, that becomes the toast. If it returns nil,
    /// no toast fires (useful for high-frequency ephemeral actions like remote
    /// direction presses, where "Remote: down" after every tap is noisy).
    /// Errors always produce a toast prefixed with ✗.
    func perform(_ label: String, _ action: @escaping () async throws -> String?) {
        Task { @MainActor in
            isBusy = true
            lastCommand = label
            lastCommandExit = nil
            defer { isBusy = false }
            do {
                if let msg = try await action() {
                    lastActionSummary = msg
                }
                // nil: deliberately suppress toast. Don't fall back to the label.
                lastCommandExit = 0
            } catch {
                // Same unreachable-error short-circuit as requestPowerChange.
                if looksUnreachable(error) {
                    reportUnreachable(reason: "Couldn't reach the TV — not on home network")
                    lastActionSummary = "Not on home network — use Siri Shortcuts"
                } else {
                    lastActionSummary = "✗ \(label): \(error.localizedDescription)"
                }
                if case let TVCommandRunner.RunnerError.nonZeroExit(code, _) = error {
                    lastCommandExit = code
                } else {
                    lastCommandExit = -1
                }
            }
        }
    }
}
