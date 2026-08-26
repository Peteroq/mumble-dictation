import SwiftUI

// The visual vocabulary of the app: cards, insets, tiles, buttons, labels, meters.
// Every value here comes from `DS`. If a component needs a number that isn't a token, the
// token is missing — add it there rather than inlining it.

// MARK: - Surfaces

/// A card: a soft white plane lifted off the ground by one diffuse shadow and bounded by a
/// hairline. No gradient, no grain — the lift comes entirely from the shadow.
struct Card: View {
    var radius: CGFloat = DS.Radius.panel

    var body: some View {
        dsShape(radius)
            .fill(DS.Color.panel)
            .dsShadow(DS.Shadow.panel)
            .overlay(
                dsShape(radius)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

/// An inset field — search boxes, typed-into wells. Sits *into* the surface, so it is a
/// shade darker than the card with no shadow of its own.
struct Inset<Content: View>: View {
    var radius: CGFloat = DS.Radius.control
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(DS.Color.well, in: dsShape(radius))
            .overlay(
                dsShape(radius)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

/// A content tile — the plane a list or transcript sits on. A hair off `Card` so a list
/// reads as its own surface when nested inside one.
struct Tile<Content: View>: View {
    var radius: CGFloat = DS.Radius.panel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(DS.Color.deck, in: dsShape(radius))
            .overlay(
                dsShape(radius)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Labels

/// A small label — a group header, a button title, a metadata chip.
///
/// Sentence case, deliberately: the previous uppercase treatment fought the rounded face and
/// cost width, which is the one thing an airy layout can't spare.
struct TextLabel: View {
    let text: String
    var large = false
    var color: Color = DS.Color.silkscreen

    var body: some View {
        Text(text)
            .font(large ? DS.Font.silkscreenLarge : DS.Font.silkscreen)
            .tracking(DS.Font.silkscreenTracking)
            .foregroundStyle(color)
    }
}

// MARK: - Status

/// A status dot. Lit dots carry a soft halo of their own color; unlit ones stay visible as a
/// dim lens so the row doesn't change height or weight when state flips.
struct StatusDot: View {
    let color: Color
    var isLit: Bool
    var size: CGFloat = DS.Material.lampSize

    var body: some View {
        Circle()
            .fill(isLit ? color : color.opacity(DS.Material.lampUnlitOpacity))
            .frame(width: size, height: size)
            .shadow(
                color: isLit ? color.opacity(0.55) : .clear,
                radius: isLit ? DS.Material.lampHalo : 0
            )
            .animation(DS.Motion.lamp, value: isLit)
    }
}

// MARK: - Controls

/// A pill button. Pressing scales it down slightly rather than sinking it — at these radii a
/// travel offset reads as a glitch, where a scale reads as touch.
///
/// `isProminent` is the primary action: a solid ink pill with light text, the one high-contrast
/// element on a page of white. There should be at most one visible at a time.
struct ActionButton: View {
    let title: String
    var systemImage: String?
    var isEngaged = false
    var engagedColor: Color = DS.Color.accent
    var isProminent = false
    /// Tints the icon independently of the label, so a prominent button can carry its state
    /// in the glyph while the pill itself stays at full contrast.
    var iconColor: Color?
    var isEnabled = true
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        // Explicit, because an Image left unstyled inherits the environment's
                        // primary label colour rather than the button's — which on a solid
                        // ink pill meant a black glyph on a black fill.
                        .foregroundStyle(iconColor ?? labelColor)
                }
                TextLabel(text: title, color: labelColor)
            }
            .frame(minWidth: DS.Material.keyMinWidth)
            .frame(height: DS.Material.keyHeight)
            .padding(.horizontal, DS.Space.base)
            .background(cap)
            .scaleEffect(isPressed ? DS.Material.keyPressScale : 1)
            .offset(y: isPressed ? DS.Material.keyTravel : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onLongPressGesture(minimumDuration: 0) {} onPressingChanged: { pressing in
            withAnimation(pressing ? DS.Motion.press : DS.Motion.release) { isPressed = pressing }
        }
    }

    private var labelColor: Color {
        if isProminent { return DS.Color.onInk }
        return isEngaged ? engagedColor : DS.Color.ink
    }

    private var fill: Color {
        if isProminent { return DS.Color.ink }
        return isEngaged ? DS.Color.selection : DS.Color.cap
    }

    private var stroke: Color {
        if isProminent { return .clear }
        return isEngaged ? DS.Color.selectionEdge : DS.Color.seam
    }

    private var cap: some View {
        Capsule(style: .continuous)
            .fill(fill)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: DS.Border.hairline)
            )
            .dsShadow(isPressed ? DS.Shadow.pressed : DS.Shadow.raised)
    }
}

// MARK: - Instrumentation

/// A level meter drawn as a row of soft capsule bars.
///
/// The damping that makes a meter readable — rather than a row strobing at buffer rate —
/// happens upstream in `DictationController.updateLevel`, so everything here is a pure
/// function of the smoothed level and the clock.
struct LevelMeter: View {
    /// Current input level, 0...1.
    let level: Float
    var isActive: Bool

    var body: some View {
        // Throttled and paused, matching the HUD's waveform. A bare `TimelineView(.animation)`
        // ticks at display rate — 120Hz here — forever, including while the app sits idle in
        // the background with this window closed, which is both a constant CPU draw for a
        // meter reading zero and a stream of calls into a view that may be on its way out.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, at: time)
            }
        }
        .opacity(isActive ? 1 : 0.45)
        .animation(DS.Motion.lamp, value: isActive)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, at time: Double) {
        let pitch = DS.Material.barWidth + DS.Material.barGap
        let count = max(1, Int(size.width / pitch))

        // Left-to-right inset so the row of bars stays centered in whatever width it's given.
        let used = CGFloat(count) * pitch - DS.Material.barGap
        let originX = (size.width - used) / 2

        for index in 0..<count {
            let value = barValue(index: index, of: count, at: time)
            let height = max(DS.Material.barMinHeight, CGFloat(value) * size.height)
            let x = originX + CGFloat(index) * pitch
            let rect = CGRect(
                x: x,
                y: (size.height - height) / 2,
                width: DS.Material.barWidth,
                height: height
            )
            let isHot = value >= DS.Material.meterZeroPoint
            context.fill(
                Path(roundedRect: rect, cornerRadius: DS.Material.barWidth / 2),
                with: .color(isHot ? DS.Color.meterRed : DS.Color.meterLamp)
            )
        }
    }

    /// One bar's height, as a pure function of level, position and time.
    ///
    /// Stateless on purpose. This used to integrate an attack/release envelope per bar in a
    /// class held in `@State`, and read that `@State` from inside the `Canvas` draw closure —
    /// which SwiftUI is free to invoke outside a view update, where reading `@State` is not
    /// valid. `DictationController` already smooths `level` before it ever gets here, so the
    /// envelope was smoothing something smooth; the motion it bought is reproduced by the
    /// per-bar phase offset below, without holding any state to get wrong.
    private func barValue(index: Int, of count: Int, at time: Double) -> Double {
        let target = Double(min(max(level, 0), 1))

        // Bars away from center peak slightly lower, so the row reads as a waveform rather
        // than a block.
        let distance = abs(Double(index) - Double(count - 1) / 2) / Double(max(count, 2))
        let shaped = target * (1 - distance * 0.55)

        // Irrational multiplier keeps the offsets from lining up into a visible period.
        let phase = (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
        let wave = 0.5 + 0.5 * sin((time * 3.4 + phase) * 2 * .pi)
        return shaped * (0.55 + 0.45 * wave)
    }
}

/// A monospaced readout — elapsed time, counts.
struct Readout: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(large ? DS.Font.counterLarge : DS.Font.counter)
            .foregroundStyle(DS.Color.inkOnDeck)
    }
}
