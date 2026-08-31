import SwiftUI

/// The transcript, typed out behind a blinking cursor and scrolled like a marquee.
///
/// One line, always. Text is laid out at its natural width and shifted left once it outgrows
/// the viewport, so the cursor stays put at the right and everything older slides toward the
/// orb and dissolves into the fade. Below the viewport width the offset clamps to zero, which
/// keeps a short transcript sitting next to the orb instead of hugging the far edge — one
/// expression covering both cases rather than two alignment modes.
struct StreamingText: View {
    let text: String
    let color: Color
    /// Whether the HUD is up. Only used to stop the caret animating behind a hidden panel.
    let isActive: Bool

    @State private var revealedCount = 0
    @State private var textWidth: CGFloat = 0

    /// Where the typing clock was started, and from which character. Nil when the reveal has
    /// caught up with the text and there is nothing in flight.
    @State private var anchor: Anchor?

    private struct Anchor {
        let count: Int
        let at: ContinuousClock.Instant
    }

    /// Characters a second. Constant, and deliberately unhurried.
    ///
    /// There was a backlog term here that raised the rate when the typing fell behind. It read
    /// badly: the rate is fixed when the loop starts, so a large revision arriving made the
    /// text sprint and then drop back to a crawl on the next one — a stutter rather than the
    /// catching-up it was meant to be. A steady rate trails a fast talker, which is the right
    /// trade: the point is to watch it type.
    private static let rate: Double = 18

    /// How long the line takes to slide one character's width — exactly the gap between
    /// characters, so the scroll tracks the typing instead of chasing it.
    ///
    /// This was longer than the interval, which meant each glide was retargeted before it
    /// arrived and the line sat permanently behind its own last letter. Deriving it from the
    /// rate is what keeps the two from drifting apart again.
    private static var scrollGlide: Double { 1 / rate }

    /// How many trailing characters are laid out at all.
    ///
    /// Only about seventy fit the viewport and everything past the fade is invisible, but
    /// SwiftUI measures every character it is given and a long dictation runs to thousands.
    /// Trimming the head costs nothing visually — it is already scrolled off and faded to
    /// zero — and the shorter line is absorbed exactly by the offset.
    private static let window = 240

    var body: some View {
        line
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                        textWidth = width
                    }
                }
            }
            // `offset` is a render-time transform and does not change layout bounds, so the
            // frame below still aligns the line to the leading edge before it is shifted.
            .offset(x: scrollOffset)
            .animation(.linear(duration: Self.scrollGlide), value: scrollOffset)
            .frame(width: HUDMetrics.transcriptWidth, alignment: .leading)
            .clipped()
            .mask(fade)
            .shadow(color: Brand.inkShadow, radius: 5, y: 1)
            .onChange(of: text) { _, new in
                // Clamped to the new length, and no further. Rewinding to the point where the
                // strings diverge made corrections retype themselves, which sounds right and
                // looks wrong: engines revise words several back while you are still speaking,
                // so the caret kept jumping backwards mid-sentence. Letting a revised word
                // change in place costs one frame of flicker and keeps the typing moving
                // forwards, which is the thing being watched.
                revealedCount = min(revealedCount, new.count)
                // A new dictation, not a revision of this one. The old clock describes a
                // sentence that no longer exists.
                if new.isEmpty { anchor = nil }
            }
            // Keyed on both, so releasing the key ends the loop immediately instead of
            // typing on behind a panel that is already closing.
            .task(id: TypingKey(text: text, isActive: isActive)) {
                guard isActive else { return }
                await type()
            }
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(visible)
                .font(DS.Font.transcript)
                .foregroundStyle(color)
                .lineLimit(1)
                // Natural width, not the parent's: the whole point is to overflow and be clipped.
                .fixedSize()
            Cursor(color: color, isActive: isActive)
        }
    }

    /// Advances the reveal from wall-clock rather than by sleeping once per character.
    ///
    /// `task(id:)` restarts every time the transcript changes, and during speech that is
    /// several times a second. A per-character sleep loses its pending sleep on each restart
    /// and effectively advances one character per revision instead of at the typing rate,
    /// which is what made this stutter and fall behind. Deriving the count from elapsed time
    /// means a restart costs nothing: it re-bases on the current count and carries on.
    private func type() async {
        // The time base has to survive the restart, and that is the whole of this fix.
        //
        // `task(id:)` restarts this loop on every revision of the transcript — several times
        // a second while you are talking. Re-basing the clock on each restart looks free, and
        // is not: `Int(elapsed * rate)` throws away whatever fraction of a character had
        // accrued since the last revision, every time. At a revision every 100ms and 18
        // characters a second that reveals floor(1.8) = 1 character where 1.8 were owed, a
        // 44% loss. At every 50ms it is floor(0.9) = 0 and the typing stops dead until you
        // pause for breath. That is why the text ran late while still looking, once it was
        // moving, like it was moving at the right speed — because it was. It just spent a lot
        // of the time not moving.
        //
        // Carrying one anchor across restarts spends the remainder instead of discarding it.
        let base = anchor ?? Anchor(count: revealedCount, at: .now)
        anchor = base

        while revealedCount < text.count, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            // One reading, not two: sampling the clock separately for each component would
            // pair a seconds value with attoseconds from a later instant.
            let components = base.at.duration(to: .now).components
            let elapsed = Double(components.seconds) + Double(components.attoseconds) * 1e-18
            let next = min(text.count, base.count + Int(elapsed * Self.rate))
            // Only when it actually moves. Assigning every tick would rebuild and re-measure
            // the whole line sixty times a second to show the same characters.
            if next != revealedCount { revealedCount = next }
        }

        // Caught up, so the anchor has done its job. Dropping it is what makes the *next*
        // burst type out at the proper rate from where the caret stands: a clock left running
        // since the start of the sentence is minutes ahead of the text by the end of one, and
        // every new character would appear the instant it arrived.
        if revealedCount >= text.count { anchor = nil }
    }

    private var visible: String {
        let shown = text.prefix(revealedCount)
        return String(shown.suffix(Self.window))
    }

    /// Where the line sits. One expression covering three cases: a short transcript starts
    /// halfway across, a growing one walks left as it fills the viewport, and a long one keeps
    /// scrolling with the caret pinned at the trailing edge.
    private var scrollOffset: CGFloat {
        min(HUDMetrics.transcriptStart, HUDMetrics.transcriptWidth - textWidth)
    }

    /// Opaque everywhere but the leading edge, where the line dissolves as it travels toward
    /// the orb. A hard clip there would read as text hitting a wall.
    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.35), location: HUDMetrics.transcriptFade * 0.45),
                .init(color: .black, location: HUDMetrics.transcriptFade),
                .init(color: .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// What restarts the typing loop: the text itself, and whether the HUD is up at all.
struct TypingKey: Equatable {
    let text: String
    let isActive: Bool
}

/// The caret at the head of the transcript.
///
/// The blink is one animation on one property rather than a state change per frame — SwiftUI
/// animates opacity without re-evaluating the body at all.
///
/// It is started and stopped with the HUD, which matters more than it sounds: the panel is
/// built once at launch and merely ordered out, so the view never disappears. A
/// `repeatForever` begun in `onAppear` runs for the life of the process, driving the render
/// loop behind an invisible window — measured at 15% of a core with nothing on screen.
struct Cursor: View {
    let color: Color
    let isActive: Bool

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color)
            .frame(width: 2, height: 25)
            .opacity(dim ? 0.05 : 1)
            .onChange(of: isActive, initial: true) { _, active in
                guard active else {
                    // A repeating animation is only displaced by another assignment to the
                    // same property; an explicitly animation-free transaction is what ends it
                    // rather than blending into it.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { dim = false }
                    return
                }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
