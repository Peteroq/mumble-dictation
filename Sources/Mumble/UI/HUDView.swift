import SwiftUI

/// The HUD's palette.
///
/// It stays a separate namespace from `DS` because the HUD is the one surface that does not
/// follow the system appearance: its glass is dark-tinted on purpose, so it is always a dark
/// surface even in light mode. Every colour here is therefore fixed rather than
/// face-resolved — `DS.Color.ink` would be near-black on the light face and vanish into the
/// glass, and the light face's deepened lime would read as muddy against it.
enum Brand {
    /// The bright lime, not the light-face value — this always sits on a dark ground.
    static let accent = Color(red: 0.78, green: 0.95, blue: 0.29)
    static let accentWarm = Color(red: 0.66, green: 0.58, blue: 1.0)

    /// Text on the glass.
    static let ink = Color.white.opacity(0.95)
    /// Error text on the glass.
    static let inkError = Color(red: 1.0, green: 0.52, blue: 0.45)

    /// How dark the glass is tinted. Deliberately faint — the pill should read as clear
    /// glass with a hint of shade in it, not as a dark chip. Legibility over bright
    /// wallpaper is carried by `inkShadow` instead of by more tint.
    static let glassTint = Color.black.opacity(0.15)

    /// A soft dark halo behind the text, for the stretch where the scrim has already faded
    /// out but the text has not.
    static let inkShadow = Color.black.opacity(0.5)

    /// The band rising from the foot of the screen. Not pure black — a trace of blue keeps it
    /// from reading as a dead rectangle laid over the desktop.
    static let scrim = Color(red: 0.01, green: 0.012, blue: 0.03)

    /// The light the orb throws into the scrim. Warm, from the near end of the prism ramp, so
    /// the halo looks like it is coming off the orb rather than being a second gradient.
    static let glow = Color(red: 1.0, green: 0.55, blue: 0.72)

    static var gradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentWarm],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// Geometry shared between the SwiftUI view and the AppKit panel that hosts it.
///
/// The panel's content rect is the hard clip boundary for everything SwiftUI draws, so these
/// have to agree. The panel is now the full width of the screen — the backdrop is a band that
/// rises from the bottom edge, not a floating chip — which is why there is no longer a bleed
/// margin: nothing draws outside the band.
enum HUDMetrics {
    /// How far up the screen the band reaches. Generous, because the gradient needs room to
    /// fade out; a short band ends in a visible horizontal edge.
    static let bandHeight: CGFloat = 560

    /// The orb's render surface — larger than the orb itself.
    ///
    /// The bloom is clipped to this texture, so the halo has to reach zero before the edge or
    /// it ends in a visible square. The orb draws at roughly 85pt inside 150, which leaves the
    /// glow about 32pt to fall off in. On the old glass pill this did not matter; on the scrim
    /// it would be the first thing you saw.
    static let orbSize = CGSize(width: 150, height: 150)

    /// The transcript's viewport. The line runs at its natural width behind this and is
    /// scrolled, so this is how much of it you see rather than where it wraps.
    static let transcriptWidth: CGFloat = 460

    /// Fraction of the viewport the leading dissolve covers, measured from the orb.
    static let transcriptFade: CGFloat = 0.24

    /// Where the caret sits before there is enough text to start scrolling.
    ///
    /// Halfway across, not at the leading edge. Starting at zero put the first words inside
    /// the dissolve, so a short transcript was read through the fade it is supposed to
    /// disappear into — the effect is for text on its way out, not on its way in.
    static let transcriptStart: CGFloat = transcriptWidth * 0.3

    /// Negative, and that is not a hack: the orb's render surface carries about 32pt of
    /// transparent margin on each side so its halo has room to fade, and that margin is dead
    /// space between the two. Pulling the text back into it closes the visual gap without
    /// cropping the glow.
    static let contentSpacing: CGFloat = -26

    /// How far the orb and text sit above the bottom edge. Low enough to sit inside the
    /// densest part of the pool rather than above it — the band's own height is unchanged, so
    /// this moves the content down the gradient without moving the gradient.
    static let contentInset: CGFloat = 40
}

struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        ZStack(alignment: .bottom) {
            Backdrop()

            HStack(alignment: .center, spacing: HUDMetrics.contentSpacing) {
                OrbView(level: controller.level, isActive: controller.state.isActive)
                    .frame(width: HUDMetrics.orbSize.width, height: HUDMetrics.orbSize.height)

                StreamingText(
                    text: label,
                    color: isError ? Brand.inkError : Brand.ink,
                    isActive: controller.state.isActive
                )
            }
            .padding(.bottom, HUDMetrics.contentInset)
            // The window carries the band in; this carries the content, a shade behind it and
            // with a little overshoot. Staggering the two is what stops the whole thing
            // reading as one flat slab sliding about.
            .scaleEffect(controller.state.isActive ? 1 : 0.9, anchor: .bottom)
            .opacity(controller.state.isActive ? 1 : 0)
            .animation(.spring(response: 0.46, dampingFraction: 0.74), value: controller.state.isActive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // The panel already ignores mouse events; this keeps SwiftUI from bothering to build
        // hit-test geometry for a view that spans the width of the display.
        .allowsHitTesting(false)
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private var label: String {
        switch controller.state {
        case .starting: "Listening…"
        // Named, not generic: following the system default means the mic in use may not be
        // the one the user has in mind, and this is the moment they can still do something
        // about it.
        case .connecting: "Connecting \(controller.inputDevice?.name ?? "microphone")…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing: controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): message
        case .idle: ""
        }
    }
}

/// The band of light and shade the orb and transcript sit on.
///
/// Three layers, all sharing one falloff shape so the blur, the shade and the glow arrive and
/// leave together. Driving them from separate gradients is how you get a blurred region whose
/// edge does not line up with the darkened one, which reads as a visible rectangle even when
/// neither layer has a hard edge of its own.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            // Progressive blur.
            //
            // Liquid Glass is the only real backdrop blur available to a borderless panel, and
            // its radius is not adjustable — so the progression comes from fading the glass
            // itself along the falloff rather than from varying a radius. What reaches the eye
            // is blur that is absent at the top of the band and full-strength at the bottom.
            //
            // `.regular` rather than `.clear`: clear glass is mostly refraction with very
            // little frost, which is the wrong half of the effect when the shade above it is
            // being lightened. Untinted either way — the shade is what darkens, and tinting
            // here as well would double it in exactly the region that is already densest.
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: Rectangle())
                .mask(falloff)

            Rectangle()
                .fill(Brand.scrim.opacity(0.62))
                .mask(falloff)

            RadialGradient(
                stops: [
                    .init(color: Brand.glow.opacity(0.17), location: 0),
                    .init(color: Brand.glow.opacity(0.06), location: 0.4),
                    .init(color: Brand.glow.opacity(0), location: 1),
                ],
                // Sunk further below the edge than the band is tall, so only the very top of
                // the glow is on screen and its centre never shows as a bright spot.
                center: UnitPoint(x: 0.5, y: 1.35),
                startRadius: 0,
                endRadius: 700
            )
            // Additive, so the glow lifts the scrim instead of laying a pink film over it.
            .blendMode(.plusLighter)
        }
        // Without this the blend mode would reach past the backdrop and tint the desktop.
        .compositingGroup()
        // A last vertical cut to nothing at the top. The falloff already fades there, but its
        // radii are fractions of the panel, and on a tall band the ellipse can still be
        // carrying value where the window clips — which is a hard horizontal line across the
        // screen. This makes that impossible regardless of what the falloff is set to.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.5), location: 0.3),
                    .init(color: .black, location: 0.58),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }

    /// Dense behind the orb and the text, thinning towards the sides.
    ///
    /// Elliptical rather than linear because the panel is now the full width of the display:
    /// a linear vertical fade covers the far corners of a wide screen as heavily as the middle,
    /// which reads as a bar laid across the desktop rather than as light pooling under the
    /// content. Radii are fractions of the panel, so the pool scales with the display instead
    /// of being sized for one.
    private var falloff: some View {
        EllipticalGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.92), location: 0.38),
                .init(color: .black.opacity(0.55), location: 0.66),
                .init(color: .black.opacity(0.16), location: 0.86),
                .init(color: .black.opacity(0), location: 1),
            ],
            center: UnitPoint(x: 0.5, y: 1.04),
            startRadiusFraction: 0,
            endRadiusFraction: 0.74
        )
    }
}

/// The transcript, typed out behind a blinking cursor and scrolled like a marquee.
///
/// One line, always. Text is laid out at its natural width and shifted left once it outgrows
/// the viewport, so the cursor stays put at the right and everything older slides toward the
/// orb and dissolves into the fade. Below the viewport width the offset clamps to zero, which
/// keeps a short transcript sitting next to the orb instead of hugging the far edge — one
/// expression covering both cases rather than two alignment modes.
private struct StreamingText: View {
    let text: String
    let color: Color
    /// Whether the HUD is up. Only used to stop the caret animating behind a hidden panel.
    let isActive: Bool

    @State private var revealedCount = 0
    @State private var textWidth: CGFloat = 0

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
            }
            .task(id: text) { await type() }
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
        let startCount = revealedCount
        let start = ContinuousClock.now

        while revealedCount < text.count, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            // One reading, not two: sampling the clock separately for each component would
            // pair a seconds value with attoseconds from a later instant.
            let components = start.duration(to: .now).components
            let elapsed = Double(components.seconds) + Double(components.attoseconds) * 1e-18
            let next = min(text.count, startCount + Int(elapsed * Self.rate))
            // Only when it actually moves. Assigning every tick would rebuild and re-measure
            // the whole line sixty times a second to show the same characters.
            if next != revealedCount { revealedCount = next }
        }
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

/// The caret at the head of the transcript.
///
/// The blink is one animation on one property rather than a state change per frame — SwiftUI
/// animates opacity without re-evaluating the body at all.
///
/// It is started and stopped with the HUD, which matters more than it sounds: the panel is
/// built once at launch and merely ordered out, so the view never disappears. A
/// `repeatForever` begun in `onAppear` runs for the life of the process, driving the render
/// loop behind an invisible window — measured at 15% of a core with nothing on screen.
private struct Cursor: View {
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
