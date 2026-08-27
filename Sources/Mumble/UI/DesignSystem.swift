import AppKit
import SwiftUI

/// The design system for Mumble.
///
/// Direction: the orb, spread across the app. Glass grounds you can see the desktop through,
/// a violet-to-pink prism ramp taken from the orb's own shader constants, and depth from
/// translucency and soft shadow rather than from borders. Every value a view needs lives
/// here; components never declare their own colors, sizes, radii or durations.
///
/// Two faces from one set of tokens: a bright glass in light appearance and a near-black one
/// in dark. A view is written once and both faces work.
///
/// The rules that keep this from drifting:
/// - The palette is the orb's. `OrbParameters` holds the stops; nothing here re-types them.
/// - Surfaces are translucent. A card is a tint over the window's glass, not an opaque plane,
///   which is why so few of them carry a border — the value change is the edge.
/// - Radii are large and continuous. Nothing in the app has a hard 90° corner.
/// - Space is the primary layout tool. When something feels cramped, add air, not a border.
enum DS {

    // MARK: - Color

    /// Surfaces, from the window ground inward. `face` resolves each to its light or dark
    /// value for the current appearance.
    enum Color {
        // MARK: Surfaces
        //
        // Everything from `panel` inward is translucent: the window itself is glass, and each
        // surface is a tint laid over what shows through it. Stacking tints is what gives the
        // app its depth, so an opaque value here would punch a hole in the effect.

        /// The window ground, laid over the glass as a frosting wash.
        ///
        /// The desktop still comes through, but only as movement and light — this is the only
        /// knob that controls how much. The system glass blur has no public radius, so the
        /// frosted read comes from here rather than from a wider blur.
        static let chassis = face(light: 0xF3F1FA, lightAlpha: 0.62, dark: 0x0B0A12, darkAlpha: 0.74)

        /// A card or grouped surface lifted off the ground.
        static let panel = face(light: 0xFFFFFF, lightAlpha: 0.62, dark: 0xC9C4E8, darkAlpha: 0.12)

        /// Hairline along the lit edge of a card. Barely there — it defines an edge, not a bevel.
        static let panelHighlight = face(light: 0xFFFFFF, lightAlpha: 0.70, dark: 0xFFFFFF, darkAlpha: 0.10)

        /// The slightly darker side of a card edge, used where two surfaces meet.
        static let panelShade = face(light: 0x2A2340, lightAlpha: 0.06, dark: 0x000000, darkAlpha: 0.22)

        /// An inset field — search boxes, code wells, anything typed into.
        static let well = face(light: 0xFFFFFF, lightAlpha: 0.46, dark: 0x08070E, darkAlpha: 0.36)

        /// The backdrop for content lists. Fainter than `panel` so a list reads as its own
        /// plane without becoming another opaque slab.
        static let deck = face(light: 0xFFFFFF, lightAlpha: 0.34, dark: 0xC9C4E8, darkAlpha: 0.07)

        /// A button surface.
        static let cap = face(light: 0xFFFFFF, lightAlpha: 0.66, dark: 0xC9C4E8, darkAlpha: 0.11)

        /// Dividers and the few hairlines left. Cards don't use it — fields and menus do.
        static let seam = face(light: 0x2A2340, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.09)

        // MARK: Text

        /// Primary readable text.
        static let ink = face(light: 0x14121C, dark: 0xF2F0FA)
        /// Supporting text — timings, counts, secondary rows.
        static let inkSecondary = face(light: 0x5F5B70, dark: 0x9C98B3)
        /// Small labels above a group. Quieter than `inkSecondary`.
        static let silkscreen = face(light: 0x807C93, dark: 0x827FA0)
        /// Text sitting on `deck`. Same value as `ink`; the separate name keeps call sites
        /// honest about which plane they're on if the two ever diverge again.
        static let inkOnDeck = face(light: 0x14121C, dark: 0xF2F0FA)

        // MARK: Accent — the orb's own colors
        //
        // Violet is the resting state and pink is the live one, which is the same order the
        // prism ramp runs in. Nothing else in the app is saturated.

        /// Selected, engaged, current. Deepened on the light face so it holds contrast
        /// against white; the bright value would vibrate there.
        static let accent = face(light: 0x6C4FE0, dark: 0xB9A6FF)
        /// A wash of the accent, for filled backgrounds behind text.
        static let accentSoft = face(light: 0xE9E3FF, lightAlpha: 0.85, dark: 0x6C4FE0, darkAlpha: 0.22)
        /// Text and glyphs sitting on a solid `accent` fill, or on the brand gradient.
        static let onAccent = face(light: 0xFFFFFF, dark: 0x120E22)

        /// Text and glyphs sitting on a solid `ink` fill.
        static let onInk = face(light: 0xFFFFFF, dark: 0x0B0A12)

        /// The recording indicator — the hot end of the ramp, so live reads as the orb at
        /// full voice rather than as a second accent.
        static let record = face(light: 0xE0407A, dark: 0xFF7AAE)
        /// The indicator when idle: a dim lens, not an absence.
        static let recordIdle = face(light: 0x2A2340, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.14)

        // MARK: Selection and focus

        /// A selected row or segment — a soft accent wash, so the label stays legible.
        static let selection = face(light: 0x6C4FE0, lightAlpha: 0.14, dark: 0xB9A6FF, darkAlpha: 0.18)
        /// Edge on a selected element.
        static let selectionEdge = face(light: 0x6C4FE0, lightAlpha: 0.34, dark: 0xB9A6FF, darkAlpha: 0.30)
        /// Keyboard focus ring.
        static let focusRing = accent
        /// Row under the pointer, before selection.
        static let hover = face(light: 0x2A2340, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.06)

        // MARK: Instrumentation and status
        //
        // Never for UI chrome. Renamed off their old colour names in the orb palette pass:
        // "green" and "amber" described a scheme this app no longer has, and a token whose
        // name lies about its value is how the next change puts the wrong colour on screen.

        /// On, enabled, healthy — the cool end of the ramp.
        static let meterOn = face(light: 0x2F6BE0, dark: 0x8FB8FF)
        /// Attention — a correction was applied, a value was overridden. Deliberately not the
        /// accent: the accent means selected, and these two must never be confused.
        static let meterFlag = face(light: 0xC2456E, dark: 0xFF9CC0)
        /// Over level, destructive.
        static let meterHot = face(light: 0xE04A34, dark: 0xFF7A66)

        // MARK: The prism ramp

        /// The wash behind selected transcript text, as the orb's own prism ramp.
        ///
        /// The stops are read from `OrbParameters` rather than copied, because the point of
        /// the selection reading as the orb is that it stays the orb — a second set of
        /// numbers here would drift the first time the orb is retuned.
        ///
        /// Alpha is carried per stop rather than by an opacity modifier so the gradient can
        /// go straight into an `NSGradient`, which is what draws it.
        /// Two stops, not three. The warm stop in the middle of the orb's ramp turned every
        /// selection into a three-colour sweep that read as decoration; violet into pink is
        /// the same pair the brand gradient uses, and it reads as one wash.
        static let selectionRamp: [SwiftUI.Color] = [
            prism(OrbParameters.colorC),
            prism(OrbParameters.colorB),
        ]

        /// The ramp at full strength, for gradients that are meant to be seen as colour —
        /// the record button, the brand sweep, the mesh in the background.
        static let ramp: [SwiftUI.Color] = [
            prism(OrbParameters.colorA, alpha: 1),
            prism(OrbParameters.colorB, alpha: 1),
            prism(OrbParameters.colorC, alpha: 1),
        ]

        /// The blue the orb never quite reaches, carried here so the background mesh has
        /// somewhere cool to fall away to. Violet alone reads as a single flat tint.
        static let rampCool = face(light: 0x3E7BFF, dark: 0x5A8CFF)

        /// One orb ramp stop.
        ///
        /// With no `alpha` it dims itself to sit under text, and the dark appearance gets less
        /// of it: the same wash that reads as a soft glow behind dark ink is a bright band
        /// behind light ink, and the text has to stay the thing you're reading.
        private static func prism(_ stop: SIMD4<Float>, alpha: CGFloat? = nil) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let wash = isDark ? DS.Material.selectionWashDark : DS.Material.selectionWashLight
                return NSColor(
                    srgbRed: CGFloat(stop.x),
                    green: CGFloat(stop.y),
                    blue: CGFloat(stop.z),
                    alpha: alpha ?? wash
                )
            })
        }

        // MARK: Face resolution

        /// Resolves to the light or dark value for the current appearance.
        private static func face(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            face(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
        }

        /// The same, for the translucent surfaces — which is most of them now. Alpha belongs
        /// in the token rather than at the call site: `.opacity()` on a surface is invisible
        /// to anyone reading the palette, and two call sites drift immediately.
        private static func face(
            light: UInt32,
            lightAlpha: CGFloat,
            dark: UInt32,
            darkAlpha: CGFloat
        ) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
                    .withAlphaComponent(isDark ? darkAlpha : lightAlpha)
            })
        }
    }

    // MARK: - Gradient

    /// The two sweeps in the app, both cut from the prism ramp.
    ///
    /// Kept as a namespace rather than being written inline, because a gradient assembled at
    /// the call site is a palette decision hiding in a view — which is exactly how the old
    /// scheme ended up with three different limes.
    enum Gradient {
        /// The brand sweep: violet into pink, running along the element.
        static var brand: LinearGradient {
            LinearGradient(
                colors: [DS.Color.ramp[2], DS.Color.ramp[1]],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        /// The record fill: hotter, and running down as well as across, so a small pill still
        /// shows the ramp rather than one flat sample of it.
        static var record: LinearGradient {
            LinearGradient(
                colors: [DS.Color.ramp[1], DS.Color.ramp[2]],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// The wash in the window background: four stops of the ramp plus the cool blue,
        /// blurred to nothing in particular. Deliberately low-contrast — it is a hint of
        /// colour behind the glass, and anything stronger competes with the transcripts.
        static var mesh: MeshGradient {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.6, 0.45], [1.0, 0.5],
                    [0.0, 1.0], [0.4, 1.0], [1.0, 1.0],
                ],
                colors: [
                    DS.Color.ramp[2], DS.Color.rampCool, DS.Color.ramp[2],
                    DS.Color.ramp[1], DS.Color.ramp[2], DS.Color.rampCool,
                    DS.Color.rampCool, DS.Color.ramp[1], DS.Color.ramp[2],
                ]
            )
        }
    }

    // MARK: - Material

    /// The small physical constants shared by controls and instrumentation. Kept here so a
    /// meter bar and a button dot can't drift apart.
    enum Material {
        // Status dots
        static let lampSize: CGFloat = 8
        /// A lit dot's soft halo radius. Small — a hint of bloom, not a glow.
        static let lampHalo: CGFloat = 6
        /// How far an unlit dot sits below the lit value.
        static let lampUnlitOpacity: Double = 0.35

        // Buttons — pill-shaped, roomy, with almost no travel.
        static let keyHeight: CGFloat = 36
        static let keyMinWidth: CGFloat = 76
        /// How far a button sinks when pressed. Barely perceptible; the scale does the work.
        static let keyTravel: CGFloat = 0.5
        /// How far a button scales down while held.
        static let keyPressScale: CGFloat = 0.97

        // Glass. The window is a real backdrop blur; these are how much colour rides on it.
        /// How much of the background mesh shows through the glass. A hint, not a wallpaper.
        static let meshOpacity: Double = 0.30
        /// How far the mesh is blurred before the glass gets it. Large enough that no stop
        /// reads as a shape — what should register is colour, not a blob.
        static let meshBlur: CGFloat = 90

        /// The title bar the window doesn't have.
        ///
        /// `.hiddenTitleBar` removes the bar but not the traffic lights, so the top strip of
        /// the window is still spoken for. `titlebar` is that strip's height — anything drawn
        /// in it centres on the lights — and `titlebarInset` is where content clears the
        /// rightmost of them.
        static let titlebar: CGFloat = 28
        static let titlebarInset: CGFloat = 88

        /// The orb standing in for the level meter, in the transport bar. Its render surface
        /// carries transparent margin for the bloom, so the orb itself draws smaller.
        static let transportOrb: CGFloat = 124

        /// The transcript selection wash, per appearance. Prominent enough to find at a
        /// glance in a wall of history, transparent enough to read through.
        static let selectionWashLight: CGFloat = 0.74
        static let selectionWashDark: CGFloat = 0.62

        /// Corner radius on the selection wash. Rounded enough to read as a drawn chip
        /// rather than a highlighter stroke, and short of the pill a taller radius would make
        /// of a single line fragment.
        static let selectionRadius: CGFloat = 7

        /// How strongly a note or warning panel tints its ground. Enough to separate it from
        /// the surface it sits on, not enough to compete with the text on it.
        static let noteTint: Double = 0.10
    }

    // MARK: - Type

    /// The rounded system face throughout. It is the one macOS face that reads soft and
    /// technical at the same time, and it ships with every weight and optical size needed.
    enum Font {
        /// Small labels above a group. Sentence case — do not uppercase these.
        static let silkscreen = rounded(size: 11, weight: .medium)
        /// A section header on a panel.
        static let silkscreenLarge = rounded(size: 13, weight: .semibold)

        static let caption = rounded(size: 11, weight: .regular)
        static let label = rounded(size: 12, weight: .medium)
        static let body = rounded(size: 13, weight: .regular)
        /// The live transcript in the HUD. Larger than `body` because the HUD is no longer a
        /// chip you glance at — it spans the foot of the screen and is read while speaking.
        static let transcript = rounded(size: 22, weight: .regular)
        static let bodyEmphasis = rounded(size: 13, weight: .semibold)
        static let title = rounded(size: 20, weight: .semibold)
        /// The app's name in the title strip. Small and quiet on purpose: it sits in the same
        /// 28pt band as the traffic lights, where anything larger stops being chrome.
        static let wordmark = rounded(size: 13, weight: .semibold)

        /// Readouts and timings. Monospaced so digits don't shift as they tick.
        static let counter = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
            .monospacedDigit()
        /// The large elapsed counter.
        static let counterLarge = SwiftUI.Font.system(size: 30, weight: .medium, design: .rounded)
            .monospacedDigit()

        /// Letter spacing for small labels, in points. Just enough to open them up.
        static let silkscreenTracking: CGFloat = 0.2

        /// AppKit twins of the faces above.
        ///
        /// A SwiftUI `Font` cannot be handed to `NSTextView`, and the selectable transcript
        /// is an `NSTextView` — so the sizes drawn by AppKit are declared here rather than
        /// left as literals at the call site.
        enum Native {
            /// `@MainActor` because `NSFont` isn't `Sendable`; every use of it is on the
            /// main actor anyway, since it's handed straight to a view.
            @MainActor static let body = rounded(size: 13, weight: .regular)
            /// A transcript in the history list. Larger than the chrome around it: this is
            /// the text you actually read, and it is also the text you have to hit with a
            /// cursor to correct a word in it.
            @MainActor static let transcript = rounded(size: 16, weight: .regular)

            private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
                let base = NSFont.systemFont(ofSize: size, weight: weight)
                guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
                return NSFont(descriptor: descriptor, size: size) ?? base
            }
        }

        private static func rounded(size: CGFloat, weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
    }

    // MARK: - Spacing

    /// The layout tool. Steps are wide apart on purpose — picking the next one up should be
    /// a visible change, so there's no temptation to invent a value in between.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let base: CGFloat = 16
        static let roomy: CGFloat = 24
        static let wide: CGFloat = 32
        static let panel: CGFloat = 44
    }

    // MARK: - Radius

    /// Large and continuous. Every rounded rect in the app should pass `style: .continuous` —
    /// at these radii the circular corner is visibly wrong.
    enum Radius {
        /// Badges, chips, small inline fills.
        static let chip: CGFloat = 12
        /// Buttons, fields, segments.
        static let control: CGFloat = 18
        /// Cards and grouped panels.
        static let panel: CGFloat = 28
        /// The window itself.
        static let window: CGFloat = 32
        /// A full pill. Any value past half the height reads as a capsule; this is explicit.
        static let pill: CGFloat = 999
    }

    // MARK: - Border

    enum Border {
        /// A drawn hairline, in `Color.seam`. The only line weight in the app.
        static let hairline: CGFloat = 1
        /// Kept as a distinct name for dividers so a future change can separate the two.
        static let seam: CGFloat = 1
        /// The edge on a raised control.
        static let bevel: CGFloat = 1
    }

    // MARK: - Elevation

    /// Depth is a single soft shadow, cast straight down and wide. Never colored, never
    /// stacked, never a glow.
    enum Shadow {
        /// A button or card sitting just off its ground.
        static let raised = Spec(color: .black.opacity(0.07), radius: 10, x: 0, y: 3)
        /// The same element while pressed — closer to the surface.
        static let pressed = Spec(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
        /// A grouped panel above the ground.
        static let panel = Spec(color: .black.opacity(0.06), radius: 22, x: 0, y: 8)
        /// The window against the desktop.
        static let window = Spec(color: .black.opacity(0.22), radius: 40, x: 0, y: 16)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Motion

    /// Soft and quick. Things ease into place; nothing snaps and nothing bounces hard.
    enum Motion {
        /// Press down.
        static let press = Animation.easeOut(duration: 0.10)
        /// Release.
        static let release = Animation.spring(response: 0.28, dampingFraction: 0.7)
        /// Panel and view changes.
        static let panel = Animation.easeInOut(duration: 0.24)
        /// A status dot lighting up.
        static let lamp = Animation.easeOut(duration: 0.16)

        /// How long a button holds a "done" label before the thing it was on goes away.
        /// Long enough to read, short enough not to sit in front of what it's covering.
        static let confirmationSeconds: Double = 0.9

    }
}

// MARK: - Shape helpers

extension View {
    /// A continuous-corner rounded rect. Always prefer this over `RoundedRectangle` so the
    /// squircle is not forgotten at a call site.
    func dsShadow(_ spec: DS.Shadow.Spec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: spec.x, y: spec.y)
    }
}

/// A continuous-corner rounded rectangle at a design-system radius.
func dsShape(_ radius: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

// MARK: - Hex helpers

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
