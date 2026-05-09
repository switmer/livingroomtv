import Foundation

/// Shells out to the `tv` CLI — the slow fallback. When the daemon is live
/// (StatusStore's `tv watch` subprocess), `runFast` routes commands through
/// the existing connection instead, cutting per-action latency from ~500ms
/// (Phase 1 cache) down to ~20-100ms.
enum TVCommandRunner {
    /// Set by `StatusStore.launch()` when the daemon becomes available.
    /// Cleared on daemon stop. When nil, `runFast` falls through to spawn.
    @MainActor static var rpcSender: ((_ cmd: String, _ args: [String: Any]) async throws -> [String: Any])?
    /// Resolve `tv` binary: prefer env override, then ~/.local/bin/tv, then /usr/local/bin.
    static var binaryPath: String {
        if let env = ProcessInfo.processInfo.environment["TV_BIN"], !env.isEmpty {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/tv",
            "/opt/homebrew/bin/tv",
            "/usr/local/bin/tv",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "\(home)/.local/bin/tv"
    }

    struct Result {
        let stdoutData: Data
        let stderrData: Data
        let exitCode: Int32
        var stdoutString: String { String(data: stdoutData, encoding: .utf8) ?? "" }
        var stderrString: String { String(data: stderrData, encoding: .utf8) ?? "" }
        var ok: Bool { exitCode == 0 }
    }

    enum RunnerError: Error, LocalizedError {
        case binaryNotFound(String)
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let path): return "tv CLI not found at \(path)"
            case .nonZeroExit(let c, let s): return "tv exited \(c): \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .decodeFailed(let e): return "couldn't decode tv output: \(e.localizedDescription)"
            }
        }
    }

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 30) async throws -> Result {
        let path = binaryPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RunnerError.binaryNotFound(path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let outData = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
        let result = Result(stdoutData: outData, stderrData: errData, exitCode: proc.terminationStatus)
        if !result.ok {
            throw RunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderrString)
        }
        return result
    }

    static func runJSON<T: Decodable>(_ args: [String], as: T.Type = T.self) async throws -> T {
        let r = try await run(args)
        do {
            return try JSONDecoder().decode(T.self, from: r.stdoutData)
        } catch {
            throw RunnerError.decodeFailed(underlying: error)
        }
    }

    /// Variant of `run` that pipes `stdin` into the subprocess. Used by
    /// commands like `tv scene save` that take a JSON payload on stdin.
    static func runWithStdin(
        _ args: [String],
        stdin: Data,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        let path = binaryPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RunnerError.binaryNotFound(path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        try proc.run()
        try inPipe.fileHandleForWriting.write(contentsOf: stdin)
        try inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let outData = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
        let result = Result(stdoutData: outData, stderrData: errData, exitCode: proc.terminationStatus)
        if !result.ok {
            throw RunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderrString)
        }
        return result
    }

    // MARK: - Fast path (daemon RPC with subprocess fallback)

    /// Attempt the daemon RPC first; on any failure (no daemon, timeout,
    /// server error), transparently fall back to spawning `tv <cliArgs>`.
    /// The daemon holds a live pyatv connection, so RPC hits are ~20-100ms.
    @MainActor
    private static func runFast(
        cmd: String,
        args: [String: Any] = [:],
        fallbackArgs: [String]
    ) async throws {
        if let send = rpcSender {
            do {
                _ = try await send(cmd, args)
                return
            } catch {
                // Daemon dropped the ball (timeout, offline, stale) —
                // fall through to the slow but dependable spawn path.
            }
        }
        try await run(fallbackArgs)
    }

    // MARK: - Convenience wrappers

    static func scene(_ name: String) async throws { try await run(["scene", name]) }
    static func find(_ query: String) async throws { try await run(["find", query]) }

    @MainActor static func playPause() async throws {
        try await runFast(cmd: "play_pause", fallbackArgs: ["play-pause"])
    }
    @MainActor static func volumeUp() async throws {
        try await runFast(cmd: "volume_up", fallbackArgs: ["volume-up"])
    }
    @MainActor static func volumeDown() async throws {
        try await runFast(cmd: "volume_down", fallbackArgs: ["volume-down"])
    }
    @MainActor static func setVolume(_ pct: Double) async throws {
        try await runFast(
            cmd: "set_volume",
            args: ["percent": pct],
            fallbackArgs: ["volume", String(Int(pct.rounded()))]
        )
    }
    @MainActor static func mute() async throws {
        try await runFast(cmd: "mute", fallbackArgs: ["mute"])
    }
    @MainActor static func unmute() async throws {
        try await runFast(cmd: "unmute", fallbackArgs: ["unmute"])
    }
    @MainActor static func menu() async throws {
        try await runFast(cmd: "nav", args: ["key": "menu"], fallbackArgs: ["menu"])
    }
    @MainActor static func home() async throws {
        try await runFast(cmd: "nav", args: ["key": "home"], fallbackArgs: ["home"])
    }
    @MainActor static func wake() async throws {
        try await runFast(cmd: "wake", fallbackArgs: ["on"])
    }
    @MainActor static func sleep() async throws {
        try await runFast(cmd: "sleep", fallbackArgs: ["off"])
    }
    @MainActor static func openApp(_ shortcut: String) async throws {
        try await runFast(
            cmd: "launch_app",
            args: ["name": shortcut],
            fallbackArgs: [shortcut]
        )
    }

    /// Single-key navigation — up, down, left, right, select, menu, home.
    /// Same fast-path routing as the rest; fallback invokes `tv <key>`.
    @MainActor static func nav(_ key: String) async throws {
        try await runFast(cmd: "nav", args: ["key": key], fallbackArgs: [key])
    }

    static func askAI(_ prompt: String) async throws -> AIResponse {
        try await runJSON(["ai", prompt, "--json"])
    }

    /// Persist a user scene from an AI plan. `actions` is the raw tool_use
    /// list straight off `AIResponse.actions`. Returns the saved scene.
    static func saveScene(
        label: String,
        shortLabel: String,
        symbol: String,
        colorHex: String,
        actions: [AIResponse.AIAction]
    ) async throws -> RoomScene {
        let payload: [String: Any] = [
            "label": label,
            "short_label": shortLabel,
            "symbol": symbol,
            "color": colorHex,
            "actions": actions.map { a -> [String: Any] in
                var out: [String: Any] = ["name": a.name]
                if let inp = a.input {
                    out["input"] = inp.mapValues { $0.value }
                } else {
                    out["input"] = [:] as [String: Any]
                }
                return out
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let r = try await runWithStdin(["scene", "save"], stdin: data)
        do {
            return try JSONDecoder().decode(RoomScene.self, from: r.stdoutData)
        } catch {
            throw RunnerError.decodeFailed(underlying: error)
        }
    }

    /// Delete a user scene by id. Throws if it's a builtin or doesn't exist.
    static func deleteScene(_ sceneId: String) async throws {
        try await run(["scene", "delete", sceneId])
    }

    static func artwork(width: Int = 240, height: Int = 240) async throws -> Data {
        try await run(["artwork", "--width", String(width), "--height", String(height)]).stdoutData
    }
}
