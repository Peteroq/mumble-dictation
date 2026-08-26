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

    /// A soft dark halo behind the text. At this little tint the glass alone can't keep
    /// white text off a white desktop, and this costs far less clarity than tinting up.
    static let inkShadow = Color.black.opacity(0.45)

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
/// The two have to agree: the panel's content rect is the hard clip boundary for everything
/// SwiftUI draws, so a shadow that bleeds past it is simply cut off. Keeping the pill size
/// and the bleed margin in one place is what stops them drifting apart.
enum HUDMetrics {
    /// The visible capsule.
    static let pillSize = CGSize(width: 340, height: 76)

    /// Transparent margin around the pill, sized to hold the shadow.
    ///
    /// `DS.Shadow.window` blurs 40pt and is offset 16pt down, so it reaches 56pt below the
    /// capsule and 40pt to either side. The margin is uniform at the larger figure rather
    /// than per-edge: it costs nothing (the panel is transparent and ignores mouse events)
    /// and it means a future change to the shadow only has to update one number.
    static let shadowMargin: CGFloat = 56

    /// What the hosting panel must actually be sized to.
    static var panelSize: CGSize {
        CGSize(
            width: pillSize.width + shadowMargin * 2,
            height: pillSize.height + shadowMargin * 2
        )
    }

    /// The level meter inside the pill.
    static let waveformSize = CGSize(width: 84, height: 32)
}

struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Waveform(level: controller.level, isActive: controller.state == .listening)
                .frame(width: HUDMetrics.waveformSize.width, height: HUDMetrics.waveformSize.height)

            Text(label)
                .font(DS.Font.body)
                .foregroundStyle(isError ? Brand.inkError : Brand.ink)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shadow(color: Brand.inkShadow, radius: 4, y: 1)
                .animation(.easeOut(duration: 0.12), value: controller.transcript)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .frame(width: HUDMetrics.pillSize.width, height: HUDMetrics.pillSize.height)
        // A full pill, not a rounded rect: at 76pt tall the capsule is the largest radius
        // the shape allows, and the HUD is the one element that should read as completely
        // soft against whatever app it floats over.
        //
        // Liquid Glass rather than `.ultraThinMaterial`: a material is a flat translucent
        // fill, which over a borderless transparent panel reads as a grey wash. The glass
        // effect samples and refracts what is actually behind the window and brings its own
        // specular edge, which is why there is no border stroke — glass draws its own, and a
        // hairline on top of it reads as a seam.
        //
        // `.clear` rather than `.regular` because the HUD sits over the user's actual work
        // and should stay see-through; the dark tint is what keeps it legible without adding
        // opacity back.
        .glassEffect(.clear.tint(Brand.glassTint), in: Capsule(style: .continuous))
        .dsShadow(DS.Shadow.window)
        // The panel clips to its content rect, so the shadow needs real space inside the
        // view — without this it is cut off square along the capsule's bounding box.
        .padding(HUDMetrics.shadowMargin)
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

/// Level-reactive bars. Each bar gets a fixed phase offset so the group ripples rather
/// than pumping in unison.
private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = 12
    private static let phases: [Double] = (0..<barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(Brand.gradient)
                        .frame(width: 3, height: height(for: index, at: t))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let floorHeight: CGFloat = 3
        guard isActive else { return floorHeight }

        let phase = Self.phases[index]
        let wave = sin(time * 6.0 + phase * .pi * 2)
        // `level` is linear amplitude, which sits low for ordinary speech — a normal
        // speaking voice rarely passes 0.3, so the bars used to barely leave the floor.
        // The square root expands the bottom of the range, which is where speech actually
        // lives. The gain is kept just above 1 so ordinary speech reads clearly without
        // pinning the meter — it should still have somewhere left to go when you get loud.
        let amplitude = min(1, CGFloat(sqrt(Double(max(0, level)))) * 1.2)
        // Wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = amplitude * (0.55 + 0.45 * CGFloat(wave))
        return floorHeight + max(0, scaled) * (HUDMetrics.waveformSize.height - floorHeight)
    }
}
