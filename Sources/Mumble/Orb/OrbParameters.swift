import simd

/// The orb's look, as tuned in `prototypes/orb-lab.html`.
///
/// These are the **96pt** values, not the full-window ones. The distinction is not cosmetic:
/// dot size and lattice density are measured in pixels and in counts, so they do not survive
/// a change of scale. The saved full-size tuning put 95 segments across the orb, which at
/// 96pt is half a pixel of spacing — not a coarser grid, an unrepresentable one. Everything
/// frame-relative (bloom radius, dispersion, grain) carries over from that tuning unchanged.
enum OrbParameters {
    // Displacement — identical to the saved tuning apart from a slightly wider noise scale,
    // which keeps the lobes readable when there are far fewer points to describe them.
    static let noiseScale: Float = 2.0
    static let amplitude: Float = 0.33
    static let flow: Float = 0.28
    static let octaves: Int32 = 3
    static let reactivity: Float = 0.74

    // Point cloud. 40 segments across ~85pt of orb is about 2pt between dots — the coarsest
    // lattice that still reads as a lattice rather than a smear.
    static let segments = 40
    static let dotSize: Float = 1.2
    static let rimBoost: Float = 1.0
    static let gain: Float = 0.62
    static let hueSpread: Float = 1.2

    // Haze. Far fewer sprites than the prototype's 2,600: each one covers a fixed fraction of
    // the orb, so at this size that many overlap into a solid wash. Per-sprite alpha is
    // normalised by the count, so this trades graininess for density, not brightness.
    static let hazeCount = 700
    static let haze: Float = 0.7
    static let cloudDepth: Float = 0.72

    // Post chain. Three bloom levels, not six — the fourth would be under 12pt across.
    static let bloomLevels = 3
    static let bloom: Float = 0.85
    static let bloomRadius: Float = 0.010
    static let bloomThreshold: Float = 0.95
    static let bloomKnee: Float = 0.6
    static let dispersion: Float = 0.0058
    static let grain: Float = 0.12
    static let exposure: Float = 0.99

    /// Prism ramp — the saved stops, unchanged.
    static let colorA = SIMD4<Float>(1.0, 0.82, 0.68, 1)
    static let colorB = SIMD4<Float>(1.0, 0.44, 0.66, 1)
    static let colorC = SIMD4<Float>(0.62, 0.53, 1.0, 1)

    /// Camera distance at 1x. The orb is framed to fill its square, so this is the prototype's
    /// base distance divided by the zoom the 96pt preset settled on.
    /// Framed to about 57% of the render surface rather than filling it, so the bloom has
    /// somewhere to fade out before the texture edge.
    static let cameraDistance: Float = 16.8 / 3.0
    static let fieldOfView: Float = 0.72
}
