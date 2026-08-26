import SwiftUI

/// The band of light and shade the orb and transcript sit on.
///
/// Three layers, all sharing one falloff shape so the blur, the shade and the glow arrive and
/// leave together. Driving them from separate gradients is how you get a blurred region whose
/// edge does not line up with the darkened one, which reads as a visible rectangle even when
/// neither layer has a hard edge of its own.
struct Backdrop: View, Equatable {
    /// Nothing here depends on anything, so nothing here ever needs redrawing.
    ///
    /// `HUDView` re-evaluates its body roughly twenty times a second while you speak, once
    /// per level update. Without this the most expensive layer on screen — a full-width
    /// Liquid Glass pass with two masks over it — is a candidate for redraw on every one of
    /// them. Declaring it equal to itself is what takes it out of that path for good.
    /// `nonisolated` because `View` is main-actor isolated and the conformance would
    /// otherwise cross that boundary. Sound here: the type has no stored properties, so there
    /// is nothing for the comparison to read.
    nonisolated static func == (lhs: Backdrop, rhs: Backdrop) -> Bool { true }

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
            // Blur and shade share one mask rather than carrying one each. Every mask is an
            // offscreen pass the width of the display, and these two were rendering the same
            // gradient twice to the same effect.
            ZStack {
                Color.clear.glassEffect(.regular, in: Rectangle())
                Rectangle().fill(Brand.scrim.opacity(0.62))
            }
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
