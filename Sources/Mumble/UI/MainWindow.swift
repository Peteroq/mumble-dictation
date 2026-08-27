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
    /// Whether the page has been scrolled far enough to shrink the transport card.
    @State private var isCollapsed = false

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case dictionary

        var id: String { rawValue }
        var title: String { self == .transcriptions ? "Transcriptions" : "Dictionary" }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground()

            // One scroll view for the whole page, not a fixed header over a scrolling well.
            // A list that scrolls inside a frame inside a window gives you a small porthole
            // onto a long history — the thing you spend the most time reading gets the least
            // room.
            ScrollView {
                VStack(spacing: DS.Space.roomy) {
                    sectionKeys

                    switch section {
                    case .transcriptions: TranscriptionList()
                    case .dictionary: DictionaryPanel()
                    }
                }
                .padding(.horizontal, DS.Space.wide)
                .padding(.bottom, DS.Space.wide)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, travelled in
                // Hysteresis: 28pt of travel to collapse, and back within 8pt of the top to
                // come out of it. A single threshold flaps on whichever pixel it lands on.
                let next = travelled > (isCollapsed ? 8 : 28)
                guard next != isCollapsed else { return }
                withAnimation(DS.Motion.panel) { isCollapsed = next }
            }
            // The card rides above the page rather than in it, so Record, the input and the
            // clock are reachable however far down the history you are.
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .frame(minWidth: 820, minHeight: 600)
        // Zero-sized: this draws nothing itself, it just gets at the window so the wordmark
        // can be hung in the title bar.
        .background { TitlebarWordmark().frame(width: 0, height: 0) }
    }

    /// The transport card, pinned above the page.
    ///
    /// The container's height is constant whatever the card is doing, because this *is* the
    /// scroll view's top inset: an inset that shrank as the card collapsed would move the
    /// content, which would move the scroll offset, which would decide to expand the card
    /// again. The card and its veil shrink inside a frame that never moves.
    private var header: some View {
        Color.clear
            .frame(height: DS.Space.wide + DS.Space.snug
                   + DS.Material.transportHeight + DS.Space.roomy)
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    titleVeil
                    TransportPanel(controller: controller, isCollapsed: isCollapsed)
                        .padding(.horizontal, DS.Space.wide)
                        .padding(.top, cardInset)
                }
            }
    }

    /// How far the card sits below the title strip. Tighter when collapsed — a 52pt card under
    /// 42pt of empty glass reads as a card that failed to load.
    private var cardInset: CGFloat {
        isCollapsed ? DS.Space.snug : DS.Space.wide + DS.Space.snug
    }

    /// Keeps the title strip legible once the page scrolls under it.
    ///
    /// With the whole page scrolling there is always something passing behind the traffic
    /// lights and the wordmark, and with the title bar hidden there is no material up there to
    /// hide it — transcripts collided with the lights directly. This is the material the
    /// hidden bar would have had, faded out rather than cut off, so it reads as the glass
    /// thickening toward the top of the window instead of as a seam across it.
    private var titleVeil: some View {
        let card = isCollapsed ? DS.Material.transportCollapsed : DS.Material.transportHeight
        let solid = cardInset + card
        let height = solid + (isCollapsed ? DS.Material.transportFade : DS.Space.roomy)

        return ZStack {
            Color.clear.glassEffect(.regular, in: Rectangle())
            DS.Color.chassis
        }
        .frame(height: height)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: solid / height),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .top)
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

// MARK: - Title bar

/// Hangs the app's name in the title bar, on the traffic lights' own line.
///
/// `.hiddenTitleBar` keeps the glass running to the top of the window and takes the window's
/// title with it, so the app's name appeared nowhere. Drawing it in the view tree can't
/// replace it: SwiftUI insets content by the title bar's height even when the bar is hidden,
/// which is why the first attempt landed a clear 30pt below the lights instead of beside them.
///
/// An `NSTitlebarAccessoryViewController` is the one thing that lays out *inside* that strip.
/// `.leading` puts it directly after the traffic lights and centres it on them, so neither the
/// inset nor the strip's height is a number this file has to guess at.
private struct TitlebarWordmark: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}

    /// A zero-sized view that exists only to be told when it has a window. `makeNSView` is
    /// too early — the view isn't in a hierarchy yet — and `updateNSView` only runs again when
    /// something upstream changes, which on a cold launch may never happen.
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            TitlebarWordmark.install(in: window)
        }
    }

    private static let id = NSUserInterfaceItemIdentifier("MumbleWordmark")

    private static func install(in window: NSWindow?) {
        guard let window,
              !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == id })
        else { return }

        let host = NSHostingView(rootView: Label())
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = id
        accessory.layoutAttribute = .leading
        accessory.view = host
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// Quiet and small, because it is chrome: at full ink and title size it read as a heading
    /// for the transport card below it.
    private struct Label: View {
        var body: some View {
            Text("Mumble")
                .font(DS.Font.wordmark)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.leading, DS.Space.snug)
        }
    }
}

// MARK: - Transport

/// Record / stop, the level meter, and the counter.
///
/// Two shapes, one row. Expanded it is a card with a caption over every value; collapsed it is
/// a single 52pt line of the same four things, because what you need while reading back a
/// hundred transcripts is to still be able to hit Record — not to be told which control is
/// which. Nothing is dropped on the way down, only the labels and the room around them.
private struct TransportPanel: View {
    @Bindable var controller: DictationController
    var isCollapsed: Bool

    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: isCollapsed ? DS.Space.base : DS.Space.wide) {
            transport
            input
            orb
            counter
            Spacer()
        }
        .padding(.horizontal, DS.Space.base)
        .frame(height: isCollapsed ? DS.Material.transportCollapsed : DS.Material.transportHeight)
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

    private var transport: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            caption("Transport")
            HStack(spacing: DS.Space.snug) {
                // One prominent style in both states — the pill stays ink so the label
                // is always at full contrast, and the glyph carries the state: the
                // accent to arm, the destructive coral to stop.
                ActionButton(
                    title: isRecording ? "Stop" : "Record",
                    systemImage: isRecording ? "stop.fill" : "circle.fill",
                    isBrand: true,
                    iconColor: DS.Color.onAccent
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
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            caption("Input")
            Readout(text: controller.inputDevice?.name ?? "No microphone")
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
        }
    }

    // No "Level" label over it. The orb is the only thing in the bar that moves, and
    // labelling it costs the one alignment in the row: a caption plus the orb is
    // a taller column than any other, which drags every other label off the line.
    private var orb: some View {
        // The orb, not a row of bars: it is already the app's picture of your voice
        // in the HUD, and two different drawings of one signal is one too many.
        //
        // Left running while the window is open rather than only while recording —
        // paused, an `MTKView` shows its last frame, so an idle transport would be a
        // frozen orb or an empty slot. At rest the level is near zero and the orb is
        // correspondingly still.
        OrbView(level: isRecording ? controller.level : 0, isActive: true)
            .frame(width: orbSize, height: orbSize)
            .allowsHitTesting(false)
    }

    private var orbSize: CGFloat {
        isCollapsed ? DS.Material.transportOrbCollapsed : DS.Material.transportOrb
    }

    private var counter: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            caption("Elapsed")
            Readout(text: counterText, large: !isCollapsed)
        }
    }

    /// A caption over a value, in the expanded card only. At 52pt there is no room for one,
    /// and a row that never changes shape is legible without them.
    @ViewBuilder private func caption(_ text: String) -> some View {
        if !isCollapsed {
            TextLabel(text: text)
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
    /// The fix being written, if any. Held here rather than on the row because rows are in a
    /// `LazyVStack` and a sheet attached to one would be torn down when it scrolls away.
    @State private var fix: TranscriptFix?

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: DS.Space.base) {
            SearchField(text: $query, placeholder: "Search transcriptions")

            if runs.isEmpty {
                EmptyPanel(
                    label: store.runs.isEmpty ? "No recordings" : "No matches",
                    detail: store.runs.isEmpty ? "Press Record to start." : "Try a different search."
                )
            } else {
                // Still lazy: the page scrolls now, but the rows are the expensive part of it
                // — each carries a live `NSTextView` — and there is no reason to build the
                // hundredth one before it is anywhere near the screen.
                LazyVStack(spacing: DS.Space.base) {
                    ForEach(runs) { run in
                        TranscriptionRow(
                            run: run,
                            onFix: { heard in fix = TranscriptFix(run: run, heard: heard) },
                            onDelete: {
                                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                            }
                        )
                    }
                }
                footer
            }
        }
        .sheet(item: $fix) { FixWordSheet(fix: $0) }
    }

    private var footer: some View {
        HStack {
            TextLabel(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
            // The feature is invisible otherwise: nothing about selectable text says the app
            // will do something with the selection.
            TextLabel(text: "Highlight a word to teach the dictionary", color: DS.Color.silkscreen)
            Spacer()
            Button { isConfirmingClear = true } label: {
                TextLabel(text: "Delete all", color: DS.Color.meterHot)
            }
            .buttonStyle(.plain)
        }
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
    /// The highlighted text, when the user asks for it to be fixed.
    let onFix: (String) -> Void
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

            SelectableTranscript(text: run.text, onFix: onFix)
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
            TextLabel(text: "Corrected", color: DS.Color.meterFlag)
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
                .background(DS.Color.meterFlag.opacity(DS.Material.noteTint), in: Capsule(style: .continuous))
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
        // A minimum rather than `maxHeight: .infinity`: inside a scroll view "as tall as
        // possible" resolves to the content's own height, which for two lines of text is a
        // caption stranded under the search field.
        .frame(maxWidth: .infinity, minHeight: DS.Material.emptyPanel)
    }
}
