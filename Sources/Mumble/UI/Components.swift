import SwiftUI

// The visual vocabulary of the app: cards, insets, tiles, buttons, labels, meters.
// Every value here comes from `DS`. If a component needs a number that isn't a token, the
// token is missing — add it there rather than inlining it.

// MARK: - Surfaces

/// The window ground: real glass, with the orb's colours drifting behind it.
///
/// Three layers, in order. The mesh is the colour, blurred past the point where any stop
/// reads as a shape. The glass is the backdrop blur that makes the desktop behind the window
/// part of the surface. The chassis wash on top is what keeps text legible over a bright
/// wallpaper — without it the whole app is at the mercy of whatever is on screen behind it.
///
/// `.ignoresSafeArea` is on the whole stack so the glass runs under the title bar too, which
/// is the point: the top of the window should be the same surface as the rest of it.
struct AppBackground: View, Equatable {
    /// A frost pass, for glass that floats over the app rather than being the app: sheets and
    /// the selection panel. At window density those read as smudges, because what is behind
    /// them is text rather than a desktop.
    ///
    /// It lightens rather than darkens — a second chassis wash is what turned the selection
    /// popover into a near-black slab, since chassis is the near-black end of the palette in
    /// dark appearance and two of them stack to opaque.
    var isDense = false

    /// Nothing here depends on anything but `isDense`, so nothing here needs redrawing — and
    /// this view sits under a transport bar that re-evaluates on every level update.
    nonisolated static func == (lhs: AppBackground, rhs: AppBackground) -> Bool {
        lhs.isDense == rhs.isDense
    }

    var body: some View {
        ZStack {
            DS.Gradient.mesh
                .opacity(DS.Material.meshOpacity)
                .blur(radius: DS.Material.meshBlur)
                // The blur samples past the edges of the mesh, so it has to be oversized or
                // the corners fade to nothing and the window ends in four grey triangles.
                .scaleEffect(1.4)

            Color.clear.glassEffect(.regular, in: Rectangle())

            DS.Color.chassis
            if isDense { DS.Color.panel }
        }
        .ignoresSafeArea()
    }
}

/// A card: a tint over the window's glass, lifted by one diffuse shadow.
///
/// No border. On an opaque scheme a hairline is what separates a white card from a white
/// ground; here the card is a different transparency of the same surface, and the value
/// change is already the edge. Drawing a line as well makes it read as a box.
struct Card: View {
    var radius: CGFloat = DS.Radius.panel

    var body: some View {
        dsShape(radius)
            .fill(DS.Color.panel)
            .dsShadow(DS.Shadow.panel)
    }
}

/// An inset field — search boxes, typed-into wells. Sits *into* the surface, so it is darker
/// than the card and keeps its hairline: a field has to look like somewhere text goes.
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

/// A content tile — the plane a list or transcript sits on. Fainter than `Card` so a list
/// reads as its own surface when nested inside one, and borderless for the same reason.
struct Tile<Content: View>: View {
    var radius: CGFloat = DS.Radius.panel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(DS.Color.deck, in: dsShape(radius))
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
    /// The record control. Same pill, filled with the prism ramp rather than a flat accent —
    /// the one element in the app that is allowed to be the orb's colours at full strength.
    var isBrand = false
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
        if isBrand { return DS.Color.onAccent }
        if isProminent { return DS.Color.onInk }
        return isEngaged ? engagedColor : DS.Color.ink
    }

    /// Type-erased because the brand fill is a gradient and the rest are flat colours, and a
    /// `ShapeStyle` is the only thing the three have in common.
    private var fill: AnyShapeStyle {
        if isBrand { return AnyShapeStyle(DS.Gradient.record) }
        if isProminent { return AnyShapeStyle(DS.Color.ink) }
        return AnyShapeStyle(isEngaged ? DS.Color.selection : DS.Color.cap)
    }

    private var stroke: Color {
        if isBrand || isProminent { return .clear }
        return isEngaged ? DS.Color.selectionEdge : .clear
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
