import MumbleDictionary
import SwiftUI

/// A request to fix one thing the engine misheard, raised from a transcript.
struct TranscriptFix: Identifiable {
    let id = UUID()
    /// The run the mistake was spotted in.
    let run: DictationRun
    /// The text that was highlighted — the "when you hear" side, pre-filled.
    let heard: String
}

/// Teach the dictionary from a mistake you just found.
///
/// The flow the whole feature exists for: highlight the wrong word in a past transcript, type
/// what it should have said, save. Two things happen, and both matter:
///
/// - The rule is written to the dictionary, so the next dictation gets it right — the
///   correction pass rewrites it, and the correct spelling is fed to the engine as bias.
/// - The transcript in front of you is rewritten too. Without this the fix is invisible
///   until the next time you happen to say the word, which reads as nothing having happened.
struct FixWordSheet: View {
    let fix: TranscriptFix

    @Environment(\.dismiss) private var dismiss
    @State private var store = DictionaryStore.shared
    @State private var heard: String
    @State private var write: String = ""
    @FocusState private var isWriteFocused: Bool

    init(fix: TranscriptFix) {
        self.fix = fix
        _heard = State(initialValue: fix.heard)
    }

    private var draft: DictionaryEntry {
        DictionaryEntry.correction(
            hear: heard.trimmingCharacters(in: .whitespacesAndNewlines),
            write: write.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    /// The rule that already exists for this trigger, if any. Saving rewrites it rather than
    /// adding a second rule, so it's shown before that happens.
    private var existing: DictionaryEntry? { store.correction(for: draft.hear) }

    private var isValid: Bool { !draft.hear.isEmpty && !draft.write.isEmpty }

    /// The transcript as it will read once the rule is applied.
    private var preview: String {
        guard isValid else { return fix.run.text }
        return DictionaryCorrector(entries: [draft]).apply(to: fix.run.text).text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                TextLabel(text: "Fix this word", large: true)
                Text("Saved to the dictionary, so it's right the next time you say it.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            VStack(alignment: .leading, spacing: DS.Space.base) {
                field("When you hear", text: $heard, prompt: "cloud code")
                field("Write", text: $write, prompt: "Claude Code")
                    .focused($isWriteFocused)
            }

            if let existing, !existing.write.isEmpty {
                note(
                    "Replaces the rule you already have: “\(existing.hear)” → “\(existing.write)”.",
                    tint: DS.Color.inkSecondary
                )
            }

            ForEach(warnings) { warning in
                note(warning.message, tint: DS.Color.meterFlag)
            }

            if isValid {
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    TextLabel(text: "This transcript becomes")
                    Text(preview)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.base)
                        .background(DS.Color.well, in: dsShape(DS.Radius.control))
                }
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                ActionButton(title: "Cancel") { dismiss() }
                ActionButton(title: "Save", isProminent: true, isEnabled: isValid) { save() }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 500)
        .background { AppBackground(isDense: true) }
        .onAppear { isWriteFocused = true }
    }

    private func save() {
        guard isValid else { return }

        let entry = store.teach(hear: draft.hear, write: draft.write)

        // Apply the new rule alone, not the whole dictionary: re-running every rule over an
        // old transcript would rewrite parts of it the user never asked about.
        var run = fix.run
        let result = DictionaryCorrector(entries: [entry]).apply(to: run.text)
        run.text = result.text
        run.corrections = Self.merge(run.corrections ?? [], result.applied)
        RunLog.update(run)

        dismiss()
    }

    /// Folds new corrections into the run's existing list, summing the count when the same
    /// rewrite fires again rather than showing the same badge twice.
    static func merge(
        _ existing: [AppliedCorrection],
        _ new: [AppliedCorrection]
    ) -> [AppliedCorrection] {
        var merged = existing
        for correction in new {
            if let index = merged.firstIndex(where: { $0.from == correction.from && $0.to == correction.to }) {
                merged[index] = AppliedCorrection(
                    from: correction.from,
                    to: correction.to,
                    count: merged[index].count + correction.count
                )
            } else {
                merged.append(correction)
            }
        }
        return merged
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            TextLabel(text: label)
            Inset {
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .padding(.horizontal, DS.Space.base)
                    .padding(.vertical, DS.Space.snug)
            }
        }
    }

    private func note(_ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: DS.Space.snug) {
            StatusDot(color: tint, isLit: true, size: 7)
                .padding(.top, 3)
            Text(message)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(DS.Material.noteTint), in: dsShape(DS.Radius.control))
    }
}
