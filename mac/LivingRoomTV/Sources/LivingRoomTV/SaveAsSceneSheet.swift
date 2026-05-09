import SwiftUI

/// Modal sheet that turns a successful AI plan into a reusable scene.
/// The user sees the replay steps up front so there's no mystery about
/// what tapping the pill later will actually do.
struct SaveAsSceneSheet: View {
    @EnvironmentObject var catalog: SceneCatalog
    @Environment(\.dismiss) private var dismiss

    /// The original prompt — used as the default label suggestion.
    let prompt: String
    /// The AI-planned action list to persist.
    let actions: [AIResponse.AIAction]
    /// Called after a successful save with the newly-persisted scene.
    var onSaved: ((RoomScene) -> Void)? = nil

    @State private var label: String = ""
    @State private var shortLabel: String = ""
    @State private var symbol: String = "sparkles"
    @State private var colorHex: String = "#7C3AED"
    @State private var isSaving: Bool = false
    @State private var error: String? = nil

    // Curated, small sets. Lucide slugs must match bundled PNGs in Resources/Icons.
    static let iconChoices: [String] = [
        "sparkles", "tv", "film", "music", "moon", "sunrise",
        "baby", "utensils", "power", "play", "house", "circle",
    ]
    static let colorChoices: [String] = [
        "#7C3AED", "#FF9F0A", "#F0A202", "#E05780",
        "#34C759", "#0A84FF", "#FF453A", "#5E5CE6",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            labelFields
            iconPicker
            colorPicker
            stepsPreview
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            // Suggest a label from the prompt — first 3 words, title-cased.
            let words = prompt.split(separator: " ").prefix(3).map(String.init)
            let suggested = words.joined(separator: " ").capitalized
            if label.isEmpty { label = suggested }
            if shortLabel.isEmpty {
                shortLabel = words.first.map { $0.capitalized } ?? suggested
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
            Text("Save as scene")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
    }

    private var labelFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Scene name", text: $label)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            TextField("Short label (for the pill)", text: $shortLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase).tracking(0.6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.iconChoices, id: \.self) { slug in
                    Button(action: { symbol = slug }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: parseHex(colorHex)).opacity(symbol == slug ? 0.28 : 0.10))
                            LucideIcon(name: slug, size: 16)
                                .foregroundStyle(Color(hex: parseHex(colorHex)))
                        }
                        .frame(height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(symbol == slug ? Color(hex: parseHex(colorHex)) : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase).tracking(0.6)
            HStack(spacing: 8) {
                ForEach(Self.colorChoices, id: \.self) { hex in
                    Button(action: { colorHex = hex }) {
                        Circle()
                            .fill(Color(hex: parseHex(hex)))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(.white, lineWidth: colorHex == hex ? 2 : 0)
                            )
                            .overlay(
                                Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }

    private var stepsPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Replay steps")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(replayableSummaries.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("›").foregroundStyle(.tertiary).font(.system(size: 11))
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if replayableSummaries.isEmpty {
                    Text("Nothing replayable — plan had only info gathering.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.04))
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(action: save) {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Save scene")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || label.trimmingCharacters(in: .whitespaces).isEmpty || replayableSummaries.isEmpty)
        }
    }

    /// Human-readable one-liner per replayable action.
    private var replayableSummaries: [String] {
        actions.compactMap { a in
            switch a.name {
            case "launch_app":
                return "launch \(stringValue(a.input?["name"]) ?? "?")"
            case "search":
                return "search \"\(stringValue(a.input?["query"]) ?? "?")\""
            case "set_volume":
                return "set volume \(doubleValue(a.input?["percent"]).map { "\(Int($0))%" } ?? "?")"
            case "mute": return "mute"
            case "unmute": return "unmute"
            case "control_playback":
                return stringValue(a.input?["action"]).map { $0.replacingOccurrences(of: "_", with: " ") } ?? "playback"
            case "power":
                return "power \(stringValue(a.input?["state"]) ?? "?")"
            case "get_status", "get_preferences", "list_apps", "navigate", "run_scene":
                return nil  // not replayable (or not useful when replayed)
            default:
                return nil
            }
        }
    }

    private func stringValue(_ any: AnyCodable?) -> String? {
        guard let v = any?.value else { return nil }
        return v as? String
    }
    private func doubleValue(_ any: AnyCodable?) -> Double? {
        guard let v = any?.value else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private func parseHex(_ s: String) -> UInt32 {
        var t = s; if t.hasPrefix("#") { t.removeFirst() }
        return UInt32(t, radix: 16) ?? 0x7C3AED
    }

    private func save() {
        error = nil
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let saved = try await TVCommandRunner.saveScene(
                    label: label.trimmingCharacters(in: .whitespaces),
                    shortLabel: shortLabel.trimmingCharacters(in: .whitespaces),
                    symbol: symbol,
                    colorHex: colorHex,
                    actions: actions
                )
                await catalog.refresh()
                onSaved?(saved)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
