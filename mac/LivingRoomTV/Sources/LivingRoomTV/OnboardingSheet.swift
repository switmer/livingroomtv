import SwiftUI
import AppKit

/// First-run sheet that surfaces missing setup steps with copy-paste Terminal
/// commands. Two states: CLI not installed, and CLI present but Apple TV not
/// paired. Both states converge on "open Terminal, run a command, click I did
/// it, sheet dismisses."
///
/// PIN entry in-app is deferred — see ROADMAP.md A2 follow-up.
struct OnboardingSheet: View {
    @EnvironmentObject var store: StatusStore
    @State private var copiedFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().opacity(0.3)
            bodyContent
            Divider().opacity(0.3)
            footer
        }
        .padding(20)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thickMaterial)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                LucideIcon(name: "tv-minimal", size: 20)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var title: String {
        switch store.onboarding {
        case .cliMissing:    return "Install the helper"
        case .needsPairing:  return "Pair your Apple TV"
        case .checking, .ready: return ""
        }
    }

    private var subtitle: String {
        switch store.onboarding {
        case .cliMissing:    return "One Terminal command. Takes about a minute."
        case .needsPairing:  return "You'll enter two 4-digit PINs shown on your TV."
        case .checking, .ready: return ""
        }
    }

    // MARK: - Body

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(explainer)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            commandBlock(commandText)

            if let msg = copiedFeedback {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
    }

    private var explainer: String {
        switch store.onboarding {
        case .cliMissing:
            return "LivingRoomTV uses a small command-line helper to talk to your Apple TV over the network. Run this in Terminal once to install it:"
        case .needsPairing:
            return "Wake your Apple TV and run this in Terminal. It'll print two 4-digit PINs on your TV screen — type each one when prompted."
        case .checking, .ready:
            return ""
        }
    }

    private var commandText: String {
        switch store.onboarding {
        case .cliMissing:
            return "git clone https://github.com/switmer/livingroomtv.git ~/.tv-src && cd ~/.tv-src && ./install.sh"
        case .needsPairing:
            return "tv pair"
        case .checking, .ready:
            return ""
        }
    }

    private func commandBlock(_ cmd: String) -> some View {
        HStack(spacing: 8) {
            Text(cmd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { copy(cmd) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Copy command")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: openTerminal) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open Terminal")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { store.onboardingSuppressed = true }) {
                Text("Skip for now")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: { store.refreshOnboarding() }) {
                Text("I did it")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.95)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copiedFeedback = "Copied to clipboard" }
        // Clear the feedback after a beat so it doesn't linger as stale chrome
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { copiedFeedback = nil }
        }
    }

    private func openTerminal() {
        if let url = URL(string: "file:///System/Applications/Utilities/Terminal.app") {
            NSWorkspace.shared.open(url)
        }
    }
}
