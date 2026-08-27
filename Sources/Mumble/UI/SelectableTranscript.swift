import MumbleDictionary
import AppKit
import SwiftUI

/// A past transcript, rendered so a word in it can be selected and taught to the dictionary.
///
/// This is an `NSTextView` rather than a SwiftUI `Text` because the whole point is acting on
/// the selection, and SwiftUI's `.textSelection(.enabled)` gives the user a selection the app
/// cannot read. AppKit is the only way to know *which* word was highlighted.
///
/// Three details worth keeping:
///
/// **TextKit 1 on purpose.** `NSTextView()` defaults to TextKit 2, where `layoutManager` is
/// nil — and the height calculation below is what lets the row size itself inside a
/// `LazyVStack`. `usingTextLayoutManager: false` keeps that measurement available.
///
/// **The selection draws itself.** `selectedTextAttributes` gets a clear background and the
/// wash is painted in `drawBackground(in:)`, because the stock highlight is a flat system
/// blue rectangle and this one is the orb's prism ramp with a rounded edge.
///
/// **Finishing a selection offers the action.** Releasing the mouse pops a small panel over
/// the selection rather than waiting for a right-click, which nothing on screen advertises.
struct SelectableTranscript: NSViewRepresentable {
    let text: String
    /// The highlighted text, when the user asks for it to be fixed.
    let onFix: (String) -> Void

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.font = DS.Font.Native.transcript
        view.textColor = NSColor(DS.Color.ink)
        // Clear, because `drawBackground(in:)` paints the wash. Leaving the stock colour here
        // would draw a system-blue rectangle underneath the gradient.
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.clear,
            .foregroundColor: NSColor(DS.Color.ink),
        ]
        view.string = text
        view.onFix = onFix
        return view
    }

    func updateNSView(_ nsView: TranscriptTextView, context: Context) {
        nsView.onFix = onFix
        // Only on a real change: assigning `string` collapses the selection, which would wipe
        // a highlight out from under the user on every unrelated redraw.
        if nsView.string != text {
            nsView.dismissActions()
            nsView.string = text
            nsView.font = DS.Font.Native.transcript
            nsView.textColor = NSColor(DS.Color.ink)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: TranscriptTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: TranscriptTextView.height(of: text, width: width))
    }

    static func dismantleNSView(_ nsView: TranscriptTextView, coordinator: ()) {
        nsView.dismissActions()
    }
}

/// The text view behind `SelectableTranscript`.
final class TranscriptTextView: NSTextView {
    var onFix: ((String) -> Void)?

    private var actions: NSPopover?
    /// Set while a context menu is being built, so the click that opens the menu doesn't also
    /// pop the action panel behind it.
    private var isOpeningMenu = false
    private var scrollObserver: (any NSObjectProtocol)?

    /// Selects on the first click, even when the window isn't frontmost.
    ///
    /// Without this the drag that would have highlighted a word is swallowed by macOS to
    /// activate the window, so the panel appears only on a second try — which reads exactly
    /// like the feature not working.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height this text needs at `width`, for SwiftUI's layout.
    ///
    /// Measured in a throwaway TextKit stack rather than by resizing the live view's own
    /// container. The view's container tracks the view's width, so setting it here is a
    /// change the next layout pass undoes — and the measurement that came back was whatever
    /// width the view happened to have last, which is how a row ended up shorter than the
    /// text inside it the moment the transcript font grew.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: DS.Font.Native.transcript]
        )
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    // MARK: - The wash

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        let stops = DS.Color.selectionRamp.map { NSColor($0) }
        guard let gradient = NSGradient(colors: stops) else { return }

        for fragment in selectionRects() {
            let path = NSBezierPath(
                roundedRect: fragment.insetBy(dx: 0, dy: -DS.Material.selectionRadius / 2),
                xRadius: DS.Material.selectionRadius,
                yRadius: DS.Material.selectionRadius
            )
            // Along the run rather than down it: the ramp should read as one sweep across the
            // words, which is how it reads on the orb.
            gradient.draw(in: path, angle: 0)
        }
    }

    /// The line fragments the selection covers, in view coordinates.
    private func selectionRects() -> [NSRect] {
        guard let container = textContainer, let manager = layoutManager else { return [] }
        let range = selectedRange()
        guard range.length > 0 else { return [] }

        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        manager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: glyphs,
            in: container
        ) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    // MARK: - Selection

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true

        // Mid-drag the selection is still being chosen, and a panel that followed the pointer
        // would be in the way of the very words being selected.
        if stillSelecting {
            dismissActions()
        } else {
            presentActionsForSelection()
        }
    }

    /// Pops the action panel over the current selection, or takes it away when there isn't one.
    private func presentActionsForSelection() {
        guard !isOpeningMenu else { return }

        let selection = selectedTranscriptText
        guard !selection.isEmpty, let anchor = selectionRects().first else {
            dismissActions()
            return
        }

        // Re-anchoring an open popover is not supported, and closing and reopening it on every
        // keystroke-sized selection change flickers. One panel per selection.
        if let actions, actions.isShown {
            (actions.contentViewController as? NSHostingController<SelectionActions>)?
                .rootView = makeActions(for: selection)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: makeActions(for: selection))
        // `.minY`, not `.maxY`: an `NSTextView` is flipped, so `.maxY` is the *bottom* of the
        // selection on screen. Anchored to the first fragment, this asks for the panel over
        // the top line of the selection rather than under the last one.
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
        settle(popover, over: anchor)
        actions = popover

        observeScrolling()
    }

    /// Puts the panel where `.minY` was asked to put it.
    ///
    /// AppKit's edge math is wrong for a flipped positioning view: it lands the panel's top a
    /// flat 346pt above the anchor, measured the same whatever the window size, the row, or
    /// the panel's own height. That constant is stable enough to have been tempting and far
    /// too strange to trust, so this corrects against the selection's real position on screen
    /// instead — the panel's bottom edge, which is where its arrow tip is, is moved to meet
    /// the top of the highlighted line.
    ///
    /// Only the origin moves, so the arrow stays under the words it was aimed at. `animates`
    /// is off, and the panel's window is already at its final frame when `show` returns, so
    /// nothing of the first placement is ever on screen.
    private func settle(_ popover: NSPopover, over anchor: NSRect) {
        guard let panel = popover.contentViewController?.view.window,
              let window
        else { return }

        let onScreen = window.convertToScreen(convert(anchor, to: nil))
        let rise = onScreen.maxY - panel.frame.minY
        guard rise != 0 else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY + rise))
    }

    private func makeActions(for selection: String) -> SelectionActions {
        SelectionActions(
            word: selection,
            onFix: { [weak self] word in
                self?.dismissActions()
                self?.onFix?(word)
            },
            onDone: { [weak self] in self?.dismissActions() }
        )
    }

    /// Takes the panel away when the list scrolls out from under it — a popover keeps its
    /// screen position, so left alone it ends up pointing at a different transcript.
    private func observeScrolling() {
        guard scrollObserver == nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            // A hop rather than `MainActor.assumeIsolated`: the notification does arrive on
            // the main queue, but `assumeIsolated` asserts rather than checks, and it has
            // taken this app down once already.
            Task { @MainActor in self?.dismissActions() }
        }
    }

    func dismissActions() {
        actions?.close()
        actions = nil
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        isOpeningMenu = true
        defer { isOpeningMenu = false }

        dismissActions()
        selectWordUnderPointer(for: event)

        let menu = super.menu(for: event) ?? NSMenu()
        let selection = selectedTranscriptText
        guard !selection.isEmpty else { return menu }

        let item = NSMenuItem(
            title: "Fix “\(selection)” in Dictionary…",
            action: #selector(fixSelection),
            keyEquivalent: ""
        )
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    /// The selection, trimmed of the whitespace and punctuation a drag usually picks up —
    /// a trigger of `"cloud code."` would never fire, because the correction pass fences
    /// every rule on word boundaries and the period is not part of the word.
    var selectedTranscriptText: String {
        let range = selectedRange()
        guard range.length > 0, let text = string as NSString? else { return "" }
        guard NSMaxRange(range) <= text.length else { return "" }
        return text.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?—–-\"'“”‘’()[]{}"))
    }

    /// Puts the selection on the word that was right-clicked, unless the click landed inside
    /// an existing selection — which is how the user says "this phrase, not that word".
    private func selectWordUnderPointer(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let current = selectedRange()
        guard current.length == 0 || !NSLocationInRange(index, current) else { return }
        guard index < (string as NSString).length else { return }

        let word = selectionRange(
            forProposedRange: NSRange(location: index, length: 0),
            granularity: .selectByWord
        )
        setSelectedRange(word)
    }

    @objc private func fixSelection() {
        let selection = selectedTranscriptText
        guard !selection.isEmpty else { return }
        onFix?(selection)
    }
}

// MARK: - The panel

/// What you can do with a highlighted word, offered where you highlighted it.
///
/// Two actions, because the dictionary has two shapes and the selection is enough to tell
/// them apart at the point of use: a word that came out *wrong* needs a correction, and a
/// word the engine simply doesn't know needs a term.
private struct SelectionActions: View {
    let word: String
    let onFix: (String) -> Void
    let onDone: () -> Void

    @State private var store = DictionaryStore.shared
    @State private var didAddTerm = false

    /// Whether this exact trigger is already taught, which changes what the first button
    /// honestly says it will do.
    private var existing: DictionaryEntry? { store.correction(for: word) }

    private var isKnownTerm: Bool {
        store.entries.contains {
            $0.kind == .term && $0.write.caseInsensitiveCompare(word) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(word)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(1)

            HStack(spacing: DS.Space.tight) {
                ActionButton(
                    title: existing == nil ? "Change in Dictionary" : "Change Rule",
                    isProminent: true
                ) {
                    onFix(word)
                }

                ActionButton(
                    title: addTermTitle,
                    isEnabled: !isKnownTerm && !didAddTerm
                ) {
                    store.add(.term(word))
                    didAddTerm = true
                    // Long enough to read the label change, short enough not to sit in front
                    // of the text it's covering.
                    Task {
                        try? await Task.sleep(for: .seconds(DS.Motion.confirmationSeconds))
                        onDone()
                    }
                }
            }
        }
        .padding(DS.Space.base)
        .background { AppBackground(isDense: true) }
    }

    private var addTermTitle: String {
        if didAddTerm { return "Added" }
        return isKnownTerm ? "Known Term" : "Add to Dictionary"
    }
}
