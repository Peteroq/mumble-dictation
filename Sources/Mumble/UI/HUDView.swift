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
    static let bandHeight: CGFloat = 340

    /// The orb's render surface — larger than the orb itself.
    ///
    /// The bloom is clipped to this texture, so the halo has to reach zero before the edge or
    /// it ends in a visible square. The orb draws at roughly 85pt inside 150, which leaves the
    /// glow about 32pt to fall off in. On the old glass pill this did not matter; on the scrim
    /// it would be the first thing you saw.
    static let orbSize = CGSize(width: 150, height: 150)

    /// The transcript's viewport. The line runs at its natural width behind this and is
    /// scrolled, so this is how much of it you see rather than where it wraps.
    static let transcriptWidth: CGFloat = 620

    /// Fraction of the viewport the leading dissolve covers, measured from the orb.
    static let transcriptFade: CGFloat = 0.22

    static let contentSpacing: CGFloat = 0

    /// How far the orb and text sit above the bottom edge, leaving the densest part of the
    /// gradient below them.
    static let contentInset: CGFloat = 84
}

struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        ZStack(alignment: .bottom) {
            Backdrop()

            HStack(alignment: .center, spacing: HUDMetrics.contentSpacing) {
                OrbView(level: controller.level, isActive: controller.state.isActive)
                    .frame(width: HUDMetrics.orbSize.width, height: HUDMetrics.orbSize.height)

                StreamingText(text: label, color: isError ? Brand.inkError : Brand.ink)
            }
            .padding(.bottom, HUDMetrics.contentInset)
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
/// Two gradients, not one. The linear pass is the legibility floor — it has to be dense enough
/// under the text to hold white type over an arbitrary desktop. The radial pass is the light,
/// and it is centred slightly below the bottom edge so what reaches the screen is the top of a
/// much larger glow rather than a circle with a visible middle.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Brand.scrim.opacity(0), location: 0),
                    .init(color: Brand.scrim.opacity(0.16), location: 0.34),
                    .init(color: Brand.scrim.opacity(0.62), location: 0.68),
                    .init(color: Brand.scrim.opacity(0.9), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                stops: [
                    .init(color: Brand.glow.opacity(0.20), location: 0),
                    .init(color: Brand.glow.opacity(0.07), location: 0.45),
                    .init(color: Brand.glow.opacity(0), location: 1),
                ],
                center: UnitPoint(x: 0.5, y: 1.12),
                startRadius: 0,
                endRadius: 620
            )
            // Additive, so the glow lifts the scrim instead of laying a pink film over it.
            .blendMode(.plusLighter)
        }
        // Without this the blend mode would reach past the backdrop and tint the desktop.
        .compositingGroup()
        .ignoresSafeArea()
    }
}

/// The transcript, revealed a character at a time and scrolled like a marquee.
///
/// One line, always. Text is laid out at its natural width and shifted left once it outgrows
/// the viewport, so the newest characters stay put at the right and everything older slides
/// toward the orb and dissolves into the fade. Below the viewport width the offset clamps to
/// zero, which keeps a short transcript sitting next to the orb instead of hugging the far
/// edge — one expression covering both cases rather than two alignment modes.
///
/// The reveal head only moves forward, except when a revision changes text already on screen.
/// Speech engines revise: they replace a word several words back once more audio arrives, so
/// the head rewinds to the divergence point rather than restarting or ignoring the change.
/// Corrections retype themselves and everything before them stays put.
private struct StreamingText: View {
    let text: String
    let color: Color

    @State private var revealed: Double = 0
    @State private var textWidth: CGFloat = 0

    /// Well clear of speech, which runs about 15 characters a second. The reveal is meant to
    /// read as the words arriving, not as something typing them out after the fact.
    private static let charactersPerSecond: Double = 115

    /// How many characters the fade covers at the head of the reveal.
    private static let fadeWidth: Double = 2.5

    /// How many trailing characters are laid out at all.
    ///
    /// Only about seventy fit the viewport, and everything past the fade is invisible — but
    /// SwiftUI still measures and lays out every character it is given, and a long dictation
    /// runs to thousands. Trimming the head costs nothing visually: it is already scrolled off
    /// and faded to zero, and dropping it shortens the line, which the offset absorbs exactly.
    private static let window = 240

    /// Roughly one character's worth of travel at speaking pace. The line steps by whole
    /// characters, so each step is animated over about the interval between them — long enough
    /// to glide, short enough that the text never lags behind its own last letter.
    private static let scrollDuration: Double = 0.1

    var body: some View {
        Text(attributed)
            .font(DS.Font.transcript)
            .lineLimit(1)
            // Natural width, not the parent's: the whole point is to overflow and be clipped.
            .fixedSize()
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
            .animation(.linear(duration: Self.scrollDuration), value: scrollOffset)
            .frame(width: HUDMetrics.transcriptWidth, alignment: .leading)
            .clipped()
            .mask(fade)
            .shadow(color: Brand.inkShadow, radius: 5, y: 1)
            .onChange(of: text) { old, new in
                revealed = min(revealed, Double(new.commonPrefix(with: old).count))
            }
            .task(id: text) {
                // Restarts on every revision and stops as soon as the head reaches the end, so
                // nothing is running while the transcript sits still.
                let target = Double(text.count)
                while revealed < target, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(16))
                    revealed = min(target, revealed + 0.016 * Self.charactersPerSecond)
                }
            }
    }

    private var scrollOffset: CGFloat {
        min(0, HUDMetrics.transcriptWidth - textWidth)
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

    /// Three runs, not one attribute per character: everything well behind the head is a single
    /// opaque run, only the few characters inside the fade window are styled individually, and
    /// the rest is not emitted at all. Per-character attributes across a long transcript would
    /// rebuild the whole string every frame.
    private var attributed: AttributedString {
        let all = Array(text)
        guard !all.isEmpty else { return AttributedString() }

        // The reveal head counts from the start of the whole transcript, so it has to be
        // rebased onto the window before it can index into it.
        let start = max(0, all.count - Self.window)
        let characters = Array(all[start...])
        let head = revealed - Double(start)
        let solidEnd = max(0, min(characters.count, Int((head - Self.fadeWidth).rounded(.down))))
        let fadeEnd = max(0, min(characters.count, Int(head.rounded(.up))))

        var result = AttributedString(String(characters[0..<solidEnd]))
        result.foregroundColor = color

        for index in solidEnd..<fadeEnd {
            var piece = AttributedString(String(characters[index]))
            let progress = (head - Double(index)) / Self.fadeWidth
            piece.foregroundColor = color.opacity(min(1, max(0, progress)))
            result += piece
        }
        return result
    }
}
