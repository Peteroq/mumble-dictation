import SwiftUI

/// The HUD's palette.
///
/// It stays a separate namespace from `DS` because the HUD is the one surface that does not
/// follow the system appearance: its glass is dark-tinted on purpose, so it is always a dark
/// surface even in light mode. Every colour here is therefore fixed rather than
/// face-resolved — `DS.Color.ink` would be near-black on the light face and vanish into the
/// glass, and the light face's deepened lime would read as muddy against it.
enum Brand {
    /// The hot end of the orb's prism ramp — this always sits on a dark ground, so it is the
    /// bright value rather than the deepened light-face one.
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.72)
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

    /// How far below its resting place the content starts, and sinks back to on the way out.
    /// Comfortably more than the content inset, so it begins fully below the screen edge.
    static let entryRise: CGFloat = 64

    /// How far the orb and text sit above the bottom edge. Low enough to sit inside the
    /// densest part of the pool rather than above it — the band's own height is unchanged, so
    /// this moves the content down the gradient without moving the gradient.
    static let contentInset: CGFloat = 40
}

struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        ZStack(alignment: .bottom) {
            Backdrop().equatable()

            HStack(alignment: .center, spacing: HUDMetrics.contentSpacing) {
                OrbView(level: controller.level, isActive: controller.state.showsHUD)
                    .frame(width: HUDMetrics.orbSize.width, height: HUDMetrics.orbSize.height)

                StreamingText(
                    text: label,
                    color: isError ? Brand.inkError : Brand.ink,
                    isActive: controller.state.showsHUD
                )
            }
            .padding(.bottom, HUDMetrics.contentInset)
            // All of the movement lives here rather than on the window. The window fades in
            // place; the content rises into it from below the bottom edge and is clipped by
            // the panel on the way, which is what reads as coming up from off-screen without
            // the band's own edge ever being visible in transit.
            .offset(y: controller.state.showsHUD ? 0 : HUDMetrics.entryRise)
            .scaleEffect(controller.state.showsHUD ? 1 : 0.94, anchor: .bottom)
            .opacity(controller.state.showsHUD ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: controller.state.showsHUD)
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
