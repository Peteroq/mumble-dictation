import Foundation

/// The orb's Metal Shading Language source, compiled at runtime.
///
/// Held as a string rather than a `.metal` file in the target because SwiftPM does not compile
/// Metal sources here — a `.metal` alongside these Swift files produces no `default.metallib`
/// and `Bundle.module` has nothing to load. `makeLibrary(source:)` costs one compile at launch,
/// which `OrbRenderer` pays off the hot path, and it keeps the shader in the same target as the
/// code that drives it instead of behind a build-system special case.
///
/// This is a transliteration of the WebGL prototype in `prototypes/orb-lab.html`. The maths is
/// identical; only the types and the entry-point attributes differ. Keep them in step.
enum OrbShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 projection;  //   0
        float3x3 rotation;    //  64
        float4 colorA;        // 112
        float4 colorB;        // 128
        float4 colorC;        // 144
        float2 resolution;    // 160
        float time;           // 168
        float level;
        float reactivity;
        float noiseScale;
        float amplitude;
        float flow;
        float dotSize;
        float rim;
        float gain;
        float spread;
        float haze;
        float hazeAlpha;
        float cameraZ;
        float contentScale;
        int octaves;
        int isHaze;
    };

    struct PostUniforms {
        float2 texel;
        float2 resolution;
        float threshold;
        float knee;
        float radius;
        float karis;
        float bloomStrength;
        float dispersion;
        float grain;
        float exposure;
        float seed;
    };

    // ---------------------------------------------------------------- noise
    // Ashima's simplex noise (webgl-noise, MIT - (C) 2011 Ashima Arts / Stefan Gustavson).

    static inline float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    static inline float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    static inline float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
    static inline float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

    static float snoise(float3 v) {
        const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
        const float4 D = float4(0.0, 0.5, 1.0, 2.0);

        float3 i  = floor(v + dot(v, C.yyy));
        float3 x0 = v - i + dot(i, C.xxx);

        float3 g = step(x0.yzx, x0.xyz);
        float3 l = 1.0 - g;
        float3 i1 = min(g.xyz, l.zxy);
        float3 i2 = max(g.xyz, l.zxy);

        float3 x1 = x0 - i1 + C.xxx;
        float3 x2 = x0 - i2 + C.yyy;
        float3 x3 = x0 - D.yyy;

        i = mod289(i);
        float4 p = permute(permute(permute(
                     i.z + float4(0.0, i1.z, i2.z, 1.0))
                   + i.y + float4(0.0, i1.y, i2.y, 1.0))
                   + i.x + float4(0.0, i1.x, i2.x, 1.0));

        float n_ = 0.142857142857;
        float3 ns = n_ * D.wyz - D.xzx;

        float4 j = p - 49.0 * floor(p * ns.z * ns.z);

        float4 x_ = floor(j * ns.z);
        float4 y_ = floor(j - 7.0 * x_);

        float4 x = x_ * ns.x + ns.yyyy;
        float4 y = y_ * ns.x + ns.yyyy;
        float4 h = 1.0 - abs(x) - abs(y);

        float4 b0 = float4(x.xy, y.xy);
        float4 b1 = float4(x.zw, y.zw);

        float4 s0 = floor(b0) * 2.0 + 1.0;
        float4 s1 = floor(b1) * 2.0 + 1.0;
        float4 sh = -step(h, float4(0.0));

        float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
        float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

        float3 p0 = float3(a0.xy, h.x);
        float3 p1 = float3(a0.zw, h.y);
        float3 p2 = float3(a1.xy, h.z);
        float3 p3 = float3(a1.zw, h.w);

        float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
        p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;

        float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
        m = m * m;
        return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
    }

    static float fbm(float3 p, int octaves) {
        float sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0;
        for (int i = 0; i < 4; i++) {
            if (i >= octaves) break;
            sum += snoise(p * freq) * amp;
            norm += amp;
            freq *= 2.0;
            amp *= 0.5;
        }
        return sum / max(norm, 0.0001);
    }

    // ---------------------------------------------------------------- orb

    struct PointVertex {
        float4 position [[position]];
        float pointSize [[point_size]];
        float shade;
        float alpha;
        float soft;
    };

    vertex PointVertex orb_vertex(uint vid [[vertex_id]],
                                  const device packed_float3 *positions [[buffer(0)]],
                                  const device float *seeds [[buffer(1)]],
                                  constant Uniforms &u [[buffer(2)]]) {
        float3 raw = float3(positions[vid]);
        float3 p = normalize(raw);
        float shell = length(raw);

        float drive = mix(1.0 - u.reactivity, 1.0, clamp(u.level, 0.0, 1.0));
        float n = fbm(p * u.noiseScale + float3(0.0, 0.0, u.time * u.flow), u.octaves);
        float disp = n * u.amplitude * drive;

        float3 displaced = p * shell * (1.0 + disp);
        float3 world = u.rotation * displaced;

        float4 mv = float4(world, 1.0);
        mv.z -= u.cameraZ;

        PointVertex out;
        out.position = u.projection * mv;

        float3 normalWorld = normalize(u.rotation * p);
        float rimTerm = pow(1.0 - abs(normalWorld.z), 2.0);

        float sizeScale = (u.isHaze != 0) ? (13.0 * u.haze + 4.0) : 1.0;
        float size = u.dotSize * (1.0 + rimTerm * u.rim * 0.5) * (0.85 + 0.3 * seeds[vid]) * sizeScale;
        out.pointSize = max(1.0, size * u.contentScale * (u.cameraZ / -mv.z));

        float depth = clamp((world.z + 1.5) / 3.0, 0.0, 1.0);
        float sweep = dot(normalWorld, normalize(float3(0.85, 0.62, 0.3))) * 0.5 + 0.5;
        out.shade = clamp((1.0 - sweep - 0.08) * u.spread + disp * 1.1, 0.0, 1.0);

        float base = mix(0.5, 1.0, depth) * (1.0 + rimTerm * u.rim * 0.65) * (0.66 + 0.34 * drive);
        float hazeA = mix(0.72, 1.0, depth) * (0.66 + 0.34 * drive) * u.hazeAlpha;
        out.alpha = (u.isHaze != 0) ? hazeA : base;
        out.soft = (u.isHaze != 0) ? 1.0 : 0.0;
        return out;
    }

    static inline float3 ramp(float t, constant Uniforms &u) {
        return t < 0.5 ? mix(u.colorA.rgb, u.colorB.rgb, t * 2.0)
                       : mix(u.colorB.rgb, u.colorC.rgb, (t - 0.5) * 2.0);
    }

    fragment float4 orb_fragment(PointVertex in [[stage_in]],
                                 float2 pointCoord [[point_coord]],
                                 constant Uniforms &u [[buffer(0)]]) {
        float2 uv = pointCoord * 2.0 - 1.0;
        float d = dot(uv, uv);
        float mask = mix(smoothstep(1.0, 0.35, d), exp(-d * 3.4), in.soft);
        if (mask <= 0.002) discard_fragment();
        float3 color = ramp(in.shade, u) * u.gain;
        return float4(color, mask * in.alpha);
    }

    // ---------------------------------------------------------------- post

    struct QuadVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex QuadVertex quad_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        QuadVertex out;
        out.uv = p;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    fragment float4 prefilter_fragment(QuadVertex in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       constant PostUniforms &p [[buffer(0)]]) {
        float3 c = src.sample(linearSampler, in.uv).rgb;
        float br = max(c.r, max(c.g, c.b));
        float knee = max(p.threshold * p.knee, 0.0001);
        float soft = clamp(br - p.threshold + knee, 0.0, 2.0 * knee);
        soft = soft * soft / (4.0 * knee);
        float contribution = max(soft, br - p.threshold) / max(br, 0.0001);
        return float4(c * contribution, 1.0);
    }

    static inline float3 karisAverage(float3 a, float3 b, float3 c, float3 d) {
        float wa = 1.0 / (1.0 + luma(a));
        float wb = 1.0 / (1.0 + luma(b));
        float wc = 1.0 / (1.0 + luma(c));
        float wd = 1.0 / (1.0 + luma(d));
        return (a * wa + b * wb + c * wc + d * wd) / max(wa + wb + wc + wd, 0.0001);
    }

    fragment float4 downsample_fragment(QuadVertex in [[stage_in]],
                                        texture2d<float> src [[texture(0)]],
                                        constant PostUniforms &p [[buffer(0)]]) {
        float2 t = p.texel;
        float3 a = src.sample(linearSampler, in.uv + float2(-2, 2) * t).rgb;
        float3 b = src.sample(linearSampler, in.uv + float2( 0, 2) * t).rgb;
        float3 c = src.sample(linearSampler, in.uv + float2( 2, 2) * t).rgb;
        float3 d = src.sample(linearSampler, in.uv + float2(-2, 0) * t).rgb;
        float3 e = src.sample(linearSampler, in.uv).rgb;
        float3 f = src.sample(linearSampler, in.uv + float2( 2, 0) * t).rgb;
        float3 g = src.sample(linearSampler, in.uv + float2(-2,-2) * t).rgb;
        float3 h = src.sample(linearSampler, in.uv + float2( 0,-2) * t).rgb;
        float3 i = src.sample(linearSampler, in.uv + float2( 2,-2) * t).rgb;
        float3 j = src.sample(linearSampler, in.uv + float2(-1, 1) * t).rgb;
        float3 k = src.sample(linearSampler, in.uv + float2( 1, 1) * t).rgb;
        float3 l = src.sample(linearSampler, in.uv + float2(-1,-1) * t).rgb;
        float3 m = src.sample(linearSampler, in.uv + float2( 1,-1) * t).rgb;

        float3 result;
        if (p.karis > 0.5) {
            result  = karisAverage(j, k, l, m) * 0.5;
            result += karisAverage(a, b, d, e) * 0.125;
            result += karisAverage(b, c, e, f) * 0.125;
            result += karisAverage(d, e, g, h) * 0.125;
            result += karisAverage(e, f, h, i) * 0.125;
        } else {
            result  = e * 0.125;
            result += (a + c + g + i) * 0.03125;
            result += (b + d + f + h) * 0.0625;
            result += (j + k + l + m) * 0.125;
        }
        return float4(result, 1.0);
    }

    fragment float4 upsample_fragment(QuadVertex in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      constant PostUniforms &p [[buffer(0)]]) {
        float r = p.radius;
        float3 a = src.sample(linearSampler, in.uv + float2(-1, 1) * r).rgb;
        float3 b = src.sample(linearSampler, in.uv + float2( 0, 1) * r).rgb;
        float3 c = src.sample(linearSampler, in.uv + float2( 1, 1) * r).rgb;
        float3 d = src.sample(linearSampler, in.uv + float2(-1, 0) * r).rgb;
        float3 e = src.sample(linearSampler, in.uv).rgb;
        float3 f = src.sample(linearSampler, in.uv + float2( 1, 0) * r).rgb;
        float3 g = src.sample(linearSampler, in.uv + float2(-1,-1) * r).rgb;
        float3 h = src.sample(linearSampler, in.uv + float2( 0,-1) * r).rgb;
        float3 i = src.sample(linearSampler, in.uv + float2( 1,-1) * r).rgb;
        float3 result = e * 4.0 + (b + d + f + h) * 2.0 + (a + c + g + i);
        return float4(result / 16.0, 1.0);
    }

    static inline float3 aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }

    static inline float hashNoise(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
    }

    /// Composite. Differs from the web version in one way that matters: the HUD orb sits on
    /// liquid glass, not on black, so this writes premultiplied alpha derived from the orb's
    /// own luminance instead of an opaque frame. Painting an opaque black square over the
    /// glass would erase the effect the HUD is built around. The vignette is gone for the same
    /// reason - darkened corners over glass read as a visible rectangle.
    fragment float4 composite_fragment(QuadVertex in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       texture2d<float> bloom [[texture(1)]],
                                       constant PostUniforms &p [[buffer(0)]]) {
        float3 sceneColor = scene.sample(linearSampler, in.uv).rgb;

        float2 dir = in.uv - 0.5;
        float r = length(dir);
        float2 offset = dir * p.dispersion * (0.25 + r * 1.4);
        float3 glow = float3(
            bloom.sample(linearSampler, in.uv + offset).r,
            bloom.sample(linearSampler, in.uv).g,
            bloom.sample(linearSampler, in.uv - offset).b
        );

        float3 color = aces((sceneColor + glow * p.bloomStrength) * p.exposure);

        float shape = 1.0 - abs(luma(color) * 2.0 - 1.0);
        float g = hashNoise(in.uv * p.resolution + p.seed) - 0.5;
        color += g * p.grain * (0.22 + 0.78 * shape);
        color = max(color, 0.0);

        // Coverage from luminance: the orb is emissive, so where it is dark it should simply
        // not be there. Grain is scaled by the same term so it cannot speckle bare glass.
        float alpha = clamp(luma(color) * 2.2, 0.0, 1.0);
        return float4(color * alpha, alpha);
    }
    """
}
