import SwiftUI

/// The design system for Mumble.
///
/// Direction: soft future-tech. Near-white grounds with a lot of air, generous squircle
/// radii, one electric accent, and depth that comes from soft diffuse shadow rather than
/// bevels or glow. Every value a view needs lives here; components never declare their own
/// colors, sizes, radii or durations.
///
/// Two faces from one set of tokens: a paper-bright light appearance and a near-black dark
/// one. A view is written once and both faces work.
///
/// The rules that keep this from drifting:
/// - One accent: the lime. It marks what is live or selected, never decoration.
/// - Radii are large and continuous. Nothing in the app has a hard 90° corner.
/// - Space is the primary layout tool. When something feels cramped, add air, not a border.
/// - Depth is a soft shadow and a hairline. No gradients on surfaces, no glow, no grain.
enum DS {

    // MARK: - Color

    /// Surfaces, from the window ground inward. `face` resolves each to its light or dark
    /// value for the current appearance.
    enum Color {
        /// The window ground everything floats on. Slightly off-white so cards read as white.
        static let chassis = face(light: 0xEDF1E9, dark: 0x0A0C0B)

        /// A card or grouped surface lifted off the ground.
        static let panel = face(light: 0xFFFFFF, dark: 0x15191A)

        /// Hairline along the lit edge of a card. Barely there — it defines an edge, not a bevel.
        static let panelHighlight = face(light: 0xFFFFFF, dark: 0x232A2C)

        /// The slightly darker side of a card edge, used where two surfaces meet.
        static let panelShade = face(light: 0xE3E9DF, dark: 0x0F1213)

        /// An inset field — search boxes, code wells, anything typed into.
        static let well = face(light: 0xF2F5EE, dark: 0x101416)

        /// The backdrop for content lists. A hair off `panel` so a list reads as its own plane.
        static let deck = face(light: 0xFAFCF7, dark: 0x111517)

        /// A button surface.
        static let cap = face(light: 0xFFFFFF, dark: 0x1C2123)

        /// Dividers and hairline borders.
        static let seam = face(light: 0xE2E7DC, dark: 0x252B2D)

        // Text
        /// Primary readable text.
        static let ink = face(light: 0x0F1310, dark: 0xEEF3E9)
        /// Supporting text — timings, counts, secondary rows.
        static let inkSecondary = face(light: 0x6A7268, dark: 0x939C90)
        /// Small labels above a group. Quieter than `inkSecondary`.
        static let silkscreen = face(light: 0x878F82, dark: 0x7E8879)
        /// Text sitting on `deck`. Same value as `ink`; the separate name keeps call sites
        /// honest about which plane they're on if the two ever diverge again.
        static let inkOnDeck = face(light: 0x0F1310, dark: 0xEEF3E9)

        // Accent — the only saturated color used for state
        /// Live, selected, engaged. The lime is deepened on the light face so it holds
        /// contrast against white; the bright value would vibrate there.
        static let accent = face(light: 0x7DC400, dark: 0xC7F24A)
        /// A wash of the accent, for filled backgrounds behind dark text.
        static let accentSoft = face(light: 0xE9F7CB, dark: 0x243213)
        /// Text and glyphs sitting on a solid `accent` fill.
        static let onAccent = face(light: 0x0B0F08, dark: 0x0B0F08)

        /// Text and glyphs sitting on a solid `ink` fill — the primary button. Not `panel`:
        /// `panel` is a surface value that happens to be white today, and reusing it here
        /// silently couples the button's legibility to a card's background.
        static let onInk = face(light: 0xFFFFFF, dark: 0x0B0F08)

        /// The recording indicator. Same accent — one live color in the app.
        static let record = accent
        /// The indicator when idle: a dim lens, not an absence.
        static let recordIdle = face(light: 0xD8DED2, dark: 0x2A302C)

        // Selection and focus
        /// A selected row or segment — a soft accent wash, so the label stays dark and legible.
        static let selection = face(light: 0xE8F6CE, dark: 0x24301A)
        /// Edge on a selected element.
        static let selectionEdge = face(light: 0xCBE596, dark: 0x3A4A22)
        /// Keyboard focus ring.
        static let focusRing = accent
        /// Row under the pointer, before selection.
        static let hover = face(light: 0xF4F7EE, dark: 0x1A1F21)

        // Level instrumentation and status. Never use these for UI chrome.
        /// The unlit track a level meter's bars sit in.
        static let meterFace = face(light: 0xF2F5EE, dark: 0x101416)
        /// A lit level bar at nominal.
        static let meterLamp = accent
        /// Meter scale marks.
        static let meterNeedle = face(light: 0xC9D1C3, dark: 0x2C3430)
        /// Enabled / healthy.
        static let meterGreen = face(light: 0x5FB000, dark: 0x9EE84A)
        /// Attention — a correction was applied, a value was overridden. Deliberately not
        /// the accent: the accent means live, and these two must never be confused.
        static let meterAmber = face(light: 0x6B4BE8, dark: 0xA895FF)
        /// Over level, destructive.
        static let meterRed = face(light: 0xE04A34, dark: 0xFF7A66)

        // MARK: Face resolution

        /// Resolves to the light or dark value for the current appearance.
        private static func face(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    // MARK: - Material

    /// The small physical constants shared by controls and instrumentation. Kept here so a
    /// meter bar and a button dot can't drift apart.
    enum Material {
        // Level meter — soft capsule bars rising and falling, no needle.
        static let barWidth: CGFloat = 4
        static let barGap: CGFloat = 5
        static let barMinHeight: CGFloat = 4
        /// Where nominal level sits along the scale, 0...1. Above this a bar reads hot.
        static let meterZeroPoint: Double = 0.78

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
        static let bodyEmphasis = rounded(size: 13, weight: .semibold)
        static let title = rounded(size: 20, weight: .semibold)

        /// Readouts and timings. Monospaced so digits don't shift as they tick.
        static let counter = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
            .monospacedDigit()
        /// The large elapsed counter.
        static let counterLarge = SwiftUI.Font.system(size: 30, weight: .medium, design: .rounded)
            .monospacedDigit()

        /// Letter spacing for small labels, in points. Just enough to open them up.
        static let silkscreenTracking: CGFloat = 0.2

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
