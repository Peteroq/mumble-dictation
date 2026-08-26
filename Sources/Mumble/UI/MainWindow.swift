import MumbleDictionary
import AppKit
import SwiftUI

/// The app's main window.
///
/// Laid out as two stacked planes on an off-white ground: a transport card across the top,
/// then the selected section on a tile below it. The section selector is a row of pill
/// buttons rather than a segmented control, because the engaged pill is the same object as
/// every other button in the app and a stock control would read as borrowed.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var section: Section = .transcriptions

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case dictionary

        var id: String { rawValue }
        var title: String { self == .transcriptions ? "Transcriptions" : "Dictionary" }
    }

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(spacing: DS.Space.roomy) {
                TransportPanel(controller: controller)

                sectionKeys

                Tile {
                    Group {
                        switch section {
                        case .transcriptions: TranscriptionList()
                        case .dictionary: DictionaryPanel()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(DS.Space.wide)
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    private var sectionKeys: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach(Section.allCases) { candidate in
                ActionButton(
                    title: candidate.title,
                    isEngaged: section == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { section = candidate }
                }
            }
            Spacer()
        }
    }
}

// MARK: - Transport

/// Record / stop, the level meter, and the counter.
private struct TransportPanel: View {
    @Bindable var controller: DictationController

    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                TextLabel(text: "Transport")
                HStack(spacing: DS.Space.snug) {
                    // One prominent style in both states — the pill stays ink so the label
                    // is always at full contrast, and the glyph carries the state: the
                    // accent to arm, the destructive coral to stop.
                    ActionButton(
                        title: isRecording ? "Stop" : "Record",
                        systemImage: isRecording ? "stop.fill" : "circle.fill",
                        isProminent: true,
                        iconColor: isRecording ? DS.Color.meterRed : DS.Color.accent
                    ) {
                        if isRecording {
                            controller.stopButtonRecording()
                        } else {
                            controller.startButtonRecording()
                        }
                    }

                    HStack(spacing: DS.Space.tight) {
                        StatusDot(color: DS.Color.record, isLit: isRecording)
                        TextLabel(text: isRecording ? "Live" : "Idle")
                    }
                    .padding(.leading, DS.Space.tight)
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                TextLabel(text: "Input")
                Readout(text: controller.inputDevice?.name ?? "No microphone")
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                TextLabel(text: "Level")
                LevelMeter(level: controller.level, isActive: isRecording)
                    .frame(width: 180, height: 40)
            }

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                TextLabel(text: "Elapsed")
                Readout(text: counterText, large: true)
            }

            Spacer()
        }
        .padding(DS.Space.roomy)
        .background(Card())
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Minutes and seconds, zero-padded.
    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transcriptions

/// Past transcriptions, searchable, each copyable.
private struct TranscriptionList: View {
    @State private var store = RunStore.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: DS.Space.base) {
            SearchField(text: $query, placeholder: "Search transcriptions")
                .padding(.horizontal, DS.Space.roomy)
                .padding(.top, DS.Space.roomy)

            if runs.isEmpty {
                EmptyPanel(
                    label: store.runs.isEmpty ? "No recordings" : "No matches",
                    detail: store.runs.isEmpty ? "Press Record to start." : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.base) {
                        ForEach(runs) { run in
                            TranscriptionRow(run: run) {
                                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.roomy)
                    .padding(.bottom, DS.Space.base)
                }
                footer
            }
        }
    }

    private var footer: some View {
        HStack {
            TextLabel(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
            Spacer()
            Button { isConfirmingClear = true } label: {
                TextLabel(text: "Delete all", color: DS.Color.meterRed)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.bottom, DS.Space.roomy)
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct TranscriptionRow: View {
    let run: DictationRun
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.snug) {
                TextLabel(text: run.engine)
                Readout(text: String(format: "%.2fs", run.processSeconds))
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                Text(run.date, style: .time)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                copyButton
                deleteButton
                    .opacity(isHovering ? 1 : 0)
            }

            Text(run.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .padding(DS.Space.roomy)
        .background(Card(radius: DS.Radius.panel))
        .overlay(
            dsShape(DS.Radius.panel)
                .strokeBorder(isHovering ? DS.Color.selectionEdge : .clear,
                              lineWidth: DS.Border.hairline)
        )
        .animation(DS.Motion.lamp, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                didCopy = false
            }
        } label: {
            TextLabel(
                text: didCopy ? "Copied" : "Copy",
                color: didCopy ? DS.Color.accent : DS.Color.inkSecondary
            )
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.tight)
            .background(DS.Color.well, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Appears on hover only, and deletes without a confirmation — a single transcript is
    /// cheap to redo, and a dialog on every row would make tidying up tedious. The
    /// irreversible one is "Delete all", which does confirm.
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight)
                .background(DS.Color.well, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Delete this transcription")
    }
}

/// Shows that the dictionary fired, and on what. Without this the dictionary is invisible
/// and you can't tell a rule that works from one that never matches.
private struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            TextLabel(text: "Corrected", color: DS.Color.meterAmber)
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.tight) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.inkSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text(correction.to)
                        .foregroundStyle(DS.Color.ink)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                }
                .font(DS.Font.caption)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight)
                .background(DS.Color.meterAmber.opacity(0.10), in: Capsule(style: .continuous))
            }
            Spacer()
        }
    }
}

// MARK: - Shared

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        Inset(radius: DS.Radius.pill) {
            HStack(spacing: DS.Space.snug) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.inkSecondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
        }
    }
}

struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            TextLabel(text: label, large: true, color: DS.Color.inkSecondary)
            Text(detail)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.silkscreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
