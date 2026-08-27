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

    @State private var navigation = Navigation.shared
    /// Whether the page has been scrolled far enough to shrink the transport card.
    @State private var isCollapsed = false

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case prompts
        case dictionary
        /// Reached from the gear on the transport card or ⌘,, never from the pill row —
        /// settings is somewhere you go and come back from, not a fourth place to be.
        case settings

        static let tabs: [Section] = [.transcriptions, .prompts, .dictionary]

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcriptions: "Transcriptions"
            case .prompts: "Prompts"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }
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

                    switch navigation.section {
                    case .transcriptions: TranscriptionList()
                    case .prompts: PromptsPanel()
                    case .dictionary: DictionaryPanel()
                    case .settings: SettingsPanel(controller: controller)
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
                    TransportPanel(
                        controller: controller,
                        isCollapsed: isCollapsed,
                        isShowingSettings: navigation.section == .settings,
                        onSettings: {
                            withAnimation(DS.Motion.panel) {
                                // A toggle, so the gear is also the way back out. Landing on
                                // Transcriptions rather than wherever you were is deliberate:
                                // remembering costs a stored section for a trip that is
                                // almost always one setting long.
                                navigation.section =
                                    navigation.section == .settings ? .transcriptions : .settings
                            }
                        }
                    )
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
            ForEach(Section.tabs) { candidate in
                ActionButton(
                    title: candidate.title,
                    isEngaged: navigation.section == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { navigation.section = candidate }
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
/// Three objects on a row, each one carrying its own label. The captions over them are gone:
/// "Transport" over a Record button, "Input" over a device name and "Elapsed" over a clock all
/// name what the thing below already says, and three of them across the top of the window was
/// most of what made the card tall.
///
/// The orb has moved inside the button. It was sitting apart from the control it describes,
/// which meant the one moving thing in the app was decoration; in the button it is the record
/// glyph, and it is lit by your own voice.
private struct TransportPanel: View {
    @Bindable var controller: DictationController
    var isCollapsed: Bool
    var isShowingSettings: Bool
    var onSettings: () -> Void

    @State private var settings = Settings.shared
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?
    @State private var isPressed = false

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: DS.Space.base) {
            recordButton
            clock
            input
            Spacer()
            settingsButton
        }
        // The padding is the gap the inner radii are cut against, so it has to be the same
        // on every side — see `insetRadius`.
        .padding(.horizontal, gap)
        .frame(height: cardHeight)
        // Not `Card`: this one is pinned over moving content, and `panel` is a 0.12 tint —
        // transcripts read straight through it. Its own glass is what stops them, and it has
        // to be the card's rather than the veil's, because a wash heavy enough to do the same
        // job across the full width of the window flattens the top of it at rest.
        .background {
            dsShape(DS.Radius.panel)
                .fill(DS.Color.panel)
                // Glass blurs what passes behind the card; `chassis` is what stops it coming
                // through at all. Glass on its own lightens the surface, so a blurred ghost
                // of the transcript was still there in the value even once it stopped being
                // readable — measurably brighter than the card had been without it.
                .background { dsShape(DS.Radius.panel).fill(DS.Color.chassis) }
                .background {
                    Color.clear.glassEffect(.regular, in: dsShape(DS.Radius.panel))
                }
                // A lit edge and a heavy shadow, which is what actually separates the card
                // from the page: the glass behind it blurs the transcripts but blurred text
                // is still roughly the same value as the card, so with nothing at the
                // boundary the two read as one surface.
                .overlay {
                    dsShape(DS.Radius.panel)
                        .strokeBorder(DS.Color.panelHighlight, lineWidth: DS.Border.hairline)
                }
                .dsShadow(DS.Shadow.floating)
        }
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

    // MARK: The record control

    /// The orb is the glyph. There is no separate lamp beside it any more: a still orb is idle
    /// and a moving one is live, which is a better indicator than a dot with a word next to it
    /// because it also tells you the microphone is hearing something.
    private var recordButton: some View {
        Button {
            if isRecording {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        } label: {
            // No spacing, and no leading padding: the orb's render surface carries
            // transparent margin for its bloom, so it supplies its own gap on both sides.
            // Adding more put the glyph adrift in the middle of the capsule.
            HStack(spacing: 0) {
                // Left running while the window is open rather than only while recording —
                // paused, an `MTKView` shows its last frame, so an idle transport would be a
                // frozen orb or an empty slot. At rest the level is near zero and the orb is
                // correspondingly still.
                OrbView(level: isRecording ? controller.level : 0, isActive: true)
                    .frame(width: orbSize, height: orbSize)
                    .allowsHitTesting(false)
                Text(isRecording ? "Stop" : "Record")
                    .font(DS.Font.control)
                    .foregroundStyle(DS.Color.ink)
            }
            // Deeper on the right than the left, where the orb's own transparent margin is
            // already holding the label off the edge.
            .padding(.trailing, DS.Space.roomy)
            .frame(height: buttonHeight)
            .background {
                ground.dsShadow(isPressed ? DS.Shadow.pressed : DS.Shadow.raised)
            }
            .scaleEffect(isPressed ? DS.Material.keyPressScale : 1)
            .offset(y: isPressed ? DS.Material.keyTravel : 0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0) {} onPressingChanged: { pressing in
            withAnimation(pressing ? DS.Motion.press : DS.Motion.release) { isPressed = pressing }
        }
    }

    /// The ground both controls sit on: a flat dark wash, cut to a radius concentric with the
    /// card's. Not the prism ramp the pill used to carry — the orb inside is already the app's
    /// colour at full strength, and a saturated fill behind it left the one thing worth
    /// looking at competing with its own button.
    private var ground: some View {
        dsShape(insetRadius).fill(DS.Color.sunken)
    }

    /// The elapsed counter.
    ///
    /// Its own view rather than a `Readout`, because it is the one piece of text in the app
    /// that changes size while you are watching it. `.rounded` at both sizes: `Readout` uses
    /// a monospaced *design* when small and a rounded one when large, and a typeface cannot
    /// be animated between — the digits stay tabular either way.
    private var clock: some View {
        Text(counterText)
            .animatableFont(
                size: isCollapsed ? DS.Font.counterSize : DS.Font.counterLargeSize,
                weight: .medium,
                design: .rounded
            )
            .monospacedDigit()
            .foregroundStyle(DS.Color.inkOnDeck)
    }

    /// The way into settings, and back out of it.
    ///
    /// On the card rather than in the tab row because it is chrome, not a place: the three
    /// tabs are things you keep, and this is a trip you make to change one value.
    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .animatableFont(
                    size: isCollapsed ? DS.Material.gearGlyphCollapsed : DS.Material.gearGlyph,
                    weight: .medium
                )
                .foregroundStyle(isShowingSettings ? DS.Color.ink : DS.Color.inkSecondary)
                .frame(width: buttonHeight, height: buttonHeight)
                .background {
                    dsShape(insetRadius).fill(isShowingSettings ? DS.Color.sunken : .clear)
                }
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    // MARK: The readouts

    /// The input, as a picker rather than a readout.
    ///
    /// It writes the same `Settings.inputDeviceUID` the Microphone panel in Settings does, so
    /// there is one preference and not two — including its opt-in nature. "System default" is
    /// nil, and nil is the case that lets the engine follow the default-device aggregate,
    /// which is what moves dictation onto AirPods the moment they connect. Naming a device
    /// pins Mumble to it and gives that up on purpose.
    ///
    /// The list is rebuilt each time the menu opens rather than observed: devices come and go,
    /// and a stale list is a preference pointing at something unplugged.
    private var input: some View {
        Menu {
            // An inline `Picker` rather than a list of `Button`s: a menu drops the image out
            // of a `Label`, so a hand-rolled checkmark simply does not appear, and the row
            // that is actually selected looks the same as every other one.
            Picker(selection: inputSelection) {
                Text("System default").tag(String?.none)
                ForEach(AudioInputDevice.all) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: DS.Space.snug) {
                Readout(text: controller.inputDevice?.name ?? "No microphone")
                    .lineLimit(1)
                    .frame(maxWidth: DS.Material.inputChipWidth, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .padding(.horizontal, DS.Space.base)
            .frame(height: buttonHeight)
            .background(ground)
        }
        // `.button` with a plain button style, not `.borderlessButton`: that style discards a
        // custom label and draws AppKit's own popup layout instead — background, padding and
        // frame all dropped, with the indicator moved to the left of the text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// What the picker reads and writes. `reloadInputDevice` is what makes the card's label
    /// change the moment a device is picked rather than after the next recording.
    private var inputSelection: Binding<String?> {
        Binding(
            get: { settings.inputDeviceUID },
            set: { uid in
                settings.inputDeviceUID = uid
                controller.reloadInputDevice()
            }
        )
    }

    // MARK: Geometry

    private var cardHeight: CGFloat {
        isCollapsed ? DS.Material.transportCollapsed : DS.Material.transportHeight
    }

    /// The margin between the card's edge and the controls on it, on every side.
    private var gap: CGFloat { (cardHeight - buttonHeight) / 2 }

    /// Cut against the card's own radius so the two curves stay parallel — and recut when the
    /// card collapses, because the gap it is measured from changes with it.
    private var insetRadius: CGFloat {
        DS.Radius.concentric(inside: DS.Radius.panel, gap: gap)
    }

    private var buttonHeight: CGFloat {
        isCollapsed ? DS.Material.recordButtonCollapsed : DS.Material.recordButton
    }

    private var orbSize: CGFloat {
        isCollapsed ? DS.Material.transportOrbCollapsed : DS.Material.transportOrb
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
    /// The prompt being written from a transcript, held here for the same reason.
    @State private var draft: PromptDraft?

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
                            onKeep: {
                                draft = PromptDraft(
                                    prompt: Prompt(
                                        title: Prompt.title(from: run.text),
                                        text: run.text
                                    ),
                                    isNew: true
                                )
                            },
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
        // The same editor the Prompts tab uses, with the transcript already in it: the
        // fastest way to write a long prompt is to say it, and the history is already full of
        // things that were said.
        .sheet(item: $draft) { draft in
            PromptEditor(draft: draft) { PromptStore.shared.add($0) }
        }
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
    /// Keep this transcript as a prompt.
    let onKeep: () -> Void
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
                keepButton
                    .opacity(isHovering ? 1 : 0)
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

    /// Keeps this transcript as a prompt. On hover only: it is a deliberate act on one row,
    /// not something that needs to be on screen for all of them at once.
    private var keepButton: some View {
        Button(action: onKeep) {
            Image(systemName: "bookmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight)
                .background(DS.Color.well, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Save as a prompt")
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
