import SwiftUI

struct AskAIField: View {
    @EnvironmentObject var store: StatusStore
    @EnvironmentObject var catalog: SceneCatalog
    @State private var prompt: String = ""
    @State private var isSubmitting: Bool = false  // LOCAL only — not shared
    @State private var reply: AIReply? = nil
    @State private var showingSaveSheet: Bool = false
    @FocusState private var focused: Bool

    struct AIReply: Equatable {
        let question: String
        let summary: String
        let isError: Bool
        let actions: [AIResponse.AIAction]

        static func == (lhs: AIReply, rhs: AIReply) -> Bool {
            // Actions aren't Equatable (AnyCodable isn't); comparing on the
            // stable fields is enough — the reply is immutable per question.
            lhs.question == rhs.question && lhs.summary == rhs.summary && lhs.isError == rhs.isError
        }

        /// True when the plan contains at least one replayable primitive.
        /// Used to decide whether the "Save as scene" affordance is meaningful.
        var isReplayable: Bool {
            guard !isError else { return false }
            let replayable: Set<String> = [
                "launch_app", "search", "set_volume", "mute", "unmute",
                "control_playback", "power",
            ]
            return actions.contains { replayable.contains($0.name) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField
            if let reply {
                replyCard(reply)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: reply)
        .sheet(isPresented: $showingSaveSheet) {
            if let r = reply {
                SaveAsSceneSheet(
                    prompt: r.question,
                    actions: r.actions,
                    onSaved: { saved in
                        store.lastActionSummary = "✓ Saved scene: \(saved.label)"
                        reply = nil
                    }
                )
                .environmentObject(catalog)
            }
        }
    }

    private var inputField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            TextField("", text: $prompt, prompt: Text("Ask Living Room…").foregroundStyle(.secondary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
                .disabled(isSubmitting)
            if isSubmitting {
                ProgressView().controlSize(.small)
            } else if !prompt.isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(focused ? 0.7 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    focused ? LinearGradient(colors: [.purple.opacity(0.5), .pink.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.white.opacity(0.04)], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.12), value: focused)
    }

    @ViewBuilder
    private func replyCard(_ r: AIReply) -> some View {
        // Header (question + close) stays pinned; body scrolls internally so
        // long replies never push the popup past the screen. MenuBarExtra's
        // own window doesn't scroll, so the cap has to live here.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: r.isError ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        r.isError
                        ? AnyShapeStyle(Color.orange)
                        : AnyShapeStyle(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
                    )
                Text(r.question)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: { reply = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            // `LocalizedStringKey` makes `Text` interpret the AI's markdown
            // (**bold**, *italic*, `code`, links) inline. Lists still render
            // as `- item` lines, which reads naturally. No ScrollView — it
            // was collapsing to 0pt inside the VStack.
            Text(LocalizedStringKey(r.summary))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(20)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if r.isReplayable {
                Button(action: { showingSaveSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Save as scene")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    r.isError ? Color.orange.opacity(0.35) : Color.purple.opacity(0.22),
                    lineWidth: 0.5
                )
        )
    }

    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        isSubmitting = true
        reply = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let r = try await TVCommandRunner.askAI(text)
                let summary = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                // Pure-action responses with no replayable actions used to
                // show only a toast — now we still surface the card when the
                // plan is replayable so the user can save it as a scene.
                // Fall back to "summary = 'Done.'" in that case.
                let candidate = AIReply(
                    question: text,
                    summary: summary.isEmpty ? "Done." : summary,
                    isError: false,
                    actions: r.actions
                )
                if summary.isEmpty && !candidate.isReplayable {
                    store.lastActionSummary = "✓ \(text)"
                } else {
                    reply = candidate
                }
            } catch {
                reply = AIReply(
                    question: text,
                    summary: error.localizedDescription,
                    isError: true,
                    actions: []
                )
            }
        }
    }
}
