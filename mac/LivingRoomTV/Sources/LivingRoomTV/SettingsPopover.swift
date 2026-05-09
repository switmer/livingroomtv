import SwiftUI
import AppKit

struct SettingsPopover: View {
    @EnvironmentObject var store: StatusStore
    @State private var launchAtLogin: Bool = LoginItemService.isEnabled
    @State private var errorMessage: String?

    // AI section local state
    @State private var aiKeyDraft: String = ""
    @State private var aiSaving: Bool = false
    @State private var aiMessage: String?
    @State private var aiMessageIsError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Divider()

            if LoginItemService.isSupported {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LoginItemService.setEnabled(newValue)
                            launchAtLogin = LoginItemService.isEnabled
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                            launchAtLogin = LoginItemService.isEnabled
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(size: 12, weight: .medium))
                        Text(LoginItemService.describeStatus())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch at login")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Requires running from the .app bundle in /Applications.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            aiSection

            Divider()

            HStack {
                Text("tv CLI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(TVCommandRunner.binaryPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                HStack {
                    Text("Version")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(version)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Living Room TV")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.9))
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - AI (optional)

    /// Power-user opt-in. When the user pastes their own Anthropic key,
    /// the AskAI input appears in the main popup. No key → no AI surface.
    /// We only check for *presence* of a key here — validity is verified
    /// the first time `tv ai "<prompt>"` actually runs.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("AI (optional)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(store.aiEnabled ? "Enabled" : "Off")
                    .font(.caption2)
                    .foregroundStyle(store.aiEnabled ? Color.green : .secondary)
            }

            Text(store.aiEnabled
                ? "Anthropic key configured. The Ask field is visible in the popup."
                : "Paste your own Anthropic API key to unlock natural-language control. You pay for usage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.aiEnabled {
                SecureField("sk-ant-…", text: $aiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(aiSaving)

                HStack(spacing: 8) {
                    Button(action: saveAIKey) {
                        if aiSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save key").font(.caption)
                        }
                    }
                    .disabled(aiSaving || aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button {
                        if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("Get a key →")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(role: .destructive, action: clearAIKey) {
                    Text("Remove saved key").font(.caption)
                }
                .disabled(aiSaving)
            }

            if let msg = aiMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(aiMessageIsError ? Color.red : .secondary)
                    .lineLimit(3)
            }
        }
    }

    private func saveAIKey() {
        let trimmed = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiSaving = true
        aiMessage = nil
        Task { @MainActor in
            defer { aiSaving = false }
            do {
                _ = try await TVCommandRunner.run(["ai-setup", trimmed])
                aiKeyDraft = ""
                aiMessageIsError = false
                aiMessage = "Saved."
                store.refreshAIStatus()
            } catch {
                aiMessageIsError = true
                aiMessage = error.localizedDescription
            }
        }
    }

    private func clearAIKey() {
        aiSaving = true
        aiMessage = nil
        Task { @MainActor in
            defer { aiSaving = false }
            do {
                _ = try await TVCommandRunner.run(["ai-clear"])
                aiMessageIsError = false
                aiMessage = "Removed."
                store.refreshAIStatus()
            } catch {
                aiMessageIsError = true
                aiMessage = error.localizedDescription
            }
        }
    }
}
