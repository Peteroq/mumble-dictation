import Metal
import simd

/// Draws the voice-reactive orb: a displaced point lattice with a volumetric haze inside it,
/// through an HDR bloom chain with prism dispersion and film grain.
///
/// A direct port of `prototypes/orb-lab.html`. The pass order is the same and the maths is the
/// same; keep them in step when either moves.
///
/// Not `@MainActor`. Rendering is driven from a display callback, and the only shared state is
/// the level, which the view hands over as a value.
final class OrbRenderer {
    /// Mirrors `Uniforms` in `OrbShaders`. Vectors first, then a flat run of scalars — the
    /// field order here is load-bearing.
    private struct Uniforms {
        var projection: simd_float4x4
        var rotation: simd_float3x3
        var colorA: SIMD4<Float>
        var colorB: SIMD4<Float>
        var colorC: SIMD4<Float>
        var resolution: SIMD2<Float>
        var time: Float
        var level: Float
        var reactivity: Float
        var noiseScale: Float
        var amplitude: Float
        var flow: Float
        var dotSize: Float
        var rim: Float
        var gain: Float
        var spread: Float
        var haze: Float
        var hazeAlpha: Float
        var cameraZ: Float
        var contentScale: Float
        var pulse: Float
        var chaos: Float
        var turbulence: Float
        var levelFloor: Float
        var levelCeiling: Float
        var octaves: Int32
        var isHaze: Int32
    }

    /// Mirrors `PostUniforms` in `OrbShaders`.
    private struct PostUniforms {
        var texel: SIMD2<Float>
        var resolution: SIMD2<Float>
        var threshold: Float
        var knee: Float
        var radius: Float
        var karis: Float
        var bloomStrength: Float
        var dispersion: Float
        var grain: Float
        var exposure: Float
        var seed: Float
    }

    private struct Cloud {
        let positions: MTLBuffer
        let seeds: MTLBuffer
        let count: Int
    }

    private struct Target {
        let texture: MTLTexture
        let width: Int
        let height: Int
    }

    let device: MTLDevice
    private let orbPipeline: MTLRenderPipelineState
    private let prefilterPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    private let dots: Cloud
    private let haze: Cloud

    private var scene: Target?
    private var chain: [Target] = []

    /// - Parameter outputFormat: the pixel format the composite pass writes into — the
    ///   drawable's in the app, an offscreen texture's under test.
    init(device: MTLDevice, outputFormat: MTLPixelFormat) throws {
        self.device = device

        // Compiled here rather than loaded from a metallib: SwiftPM does not build `.metal`
        // sources in this package, so there is no default library to load. One compile, at
        // renderer construction, which the app does off the hot path.
        let library = try device.makeLibrary(source: OrbShaders.source, options: nil)

        func makePipeline(
            vertex: String,
            fragment: String,
            format: MTLPixelFormat,
            blend: Bool
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if blend {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        orbPipeline = try makePipeline(vertex: "orb_vertex", fragment: "orb_fragment",
                                       format: .rgba16Float, blend: true)
        prefilterPipeline = try makePipeline(vertex: "quad_vertex", fragment: "prefilter_fragment",
                                             format: .rgba16Float, blend: false)
        downsamplePipeline = try makePipeline(vertex: "quad_vertex", fragment: "downsample_fragment",
                                              format: .rgba16Float, blend: false)

        // The upsample adds each level back onto the one above it, so it blends with straight
        // ONE/ONE rather than the scene pass's source-alpha weighting.
        let upDescriptor = MTLRenderPipelineDescriptor()
        upDescriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        upDescriptor.fragmentFunction = library.makeFunction(name: "upsample_fragment")
        let upAttachment = upDescriptor.colorAttachments[0]!
        upAttachment.pixelFormat = .rgba16Float
        upAttachment.isBlendingEnabled = true
        upAttachment.rgbBlendOperation = .add
        upAttachment.alphaBlendOperation = .add
        upAttachment.sourceRGBBlendFactor = .one
        upAttachment.destinationRGBBlendFactor = .one
        upAttachment.sourceAlphaBlendFactor = .one
        upAttachment.destinationAlphaBlendFactor = .one
        upsamplePipeline = try device.makeRenderPipelineState(descriptor: upDescriptor)

        compositePipeline = try makePipeline(vertex: "quad_vertex", fragment: "composite_fragment",
                                             format: outputFormat, blend: false)

        dots = try Self.makeLattice(device: device, segments: OrbParameters.segments)
        haze = try Self.makeHaze(device: device, count: OrbParameters.hazeCount,
                                 depth: OrbParameters.cloudDepth)
    }

    // MARK: - Geometry

    private static func makeCloud(
        device: MTLDevice,
        positions: [SIMD3<Float>],
        seeds: [Float]
    ) throws -> Cloud {
        // `packed_float3` on the shader side, so the stride here must be 12 bytes, not the 16
        // a `SIMD3<Float>` array would give.
        var packed = [Float]()
        packed.reserveCapacity(positions.count * 3)
        for p in positions { packed.append(p.x); packed.append(p.y); packed.append(p.z) }

        guard let positionBuffer = device.makeBuffer(bytes: packed,
                                                     length: packed.count * MemoryLayout<Float>.stride,
                                                     options: .storageModeShared),
              let seedBuffer = device.makeBuffer(bytes: seeds,
                                                 length: seeds.count * MemoryLayout<Float>.stride,
                                                 options: .storageModeShared)
        else { throw OrbError.bufferAllocationFailed }

        return Cloud(positions: positionBuffer, seeds: seedBuffer, count: positions.count)
    }

    /// Lat/long lattice. Ring population scales with circumference so the poles do not collapse
    /// into a saturated knot under additive blending.
    private static func makeLattice(device: MTLDevice, segments: Int) throws -> Cloud {
        let rings = max(8, Int((Float(segments) * 0.6).rounded()))
        var positions: [SIMD3<Float>] = [SIMD3(0, 1, 0)]
        var seeds: [Float] = [Float.random(in: 0...1)]

        for iy in 1..<rings {
            let phi = Float(iy) / Float(rings) * .pi
            let sinPhi = sin(phi)
            let cosPhi = cos(phi)
            let ringCount = max(3, Int((Float(segments) * sinPhi).rounded()))
            for ix in 0..<ringCount {
                let theta = Float(ix) / Float(ringCount) * 2 * .pi
                positions.append(SIMD3(sinPhi * cos(theta), cosPhi, sinPhi * sin(theta)))
                seeds.append(Float.random(in: 0...1))
            }
        }
        positions.append(SIMD3(0, -1, 0))
        seeds.append(Float.random(in: 0...1))
        return try makeCloud(device: device, positions: positions, seeds: seeds)
    }

    /// A Fibonacci spiral filled through the interior volume. Directions are scattered rather
    /// than latticed — wide soft sprites on a lattice redraw the grid as a moiré.
    private static func makeHaze(device: MTLDevice, count: Int, depth: Float) throws -> Cloud {
        let inner = depth * 0.12
        let golden = Float.pi * (3 - sqrt(5))
        var positions: [SIMD3<Float>] = []
        var seeds: [Float] = []
        positions.reserveCapacity(count)

        for i in 0..<count {
            let y = 1 - Float(i) / Float(count - 1) * 2
            let radius = (max(0, 1 - y * y)).squareRoot()
            let theta = golden * Float(i)
            // Power below 1/3 on purpose: a uniform-by-volume fill piles the mass just under
            // the surface, which reads as a second shell instead of a full middle.
            let shell = inner + (depth - inner) * pow(Float.random(in: 0...1), 0.55)
            positions.append(SIMD3(cos(theta) * radius * shell, y * shell, sin(theta) * radius * shell))
            seeds.append(Float.random(in: 0...1))
        }
        return try makeCloud(device: device, positions: positions, seeds: seeds)
    }

    // MARK: - Targets

    private func makeTarget(width: Int, height: Int) -> Target? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: max(1, width), height: max(1, height), mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        return Target(texture: texture, width: max(1, width), height: max(1, height))
    }

    private func ensureTargets(width: Int, height: Int) {
        if let scene, scene.width == width, scene.height == height { return }
        scene = makeTarget(width: width, height: height)
        chain = []
        var w = width, h = height
        for _ in 0..<OrbParameters.bloomLevels {
            w = max(2, w / 2)
            h = max(2, h / 2)
            guard let level = makeTarget(width: w, height: h) else { break }
            chain.append(level)
        }
    }

    // MARK: - Draw

    func render(
        into output: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        level: Float,
        time: Float,
        yaw: Float,
        pitch: Float,
        contentScale: Float
    ) {
        let width = output.width
        let height = output.height
        ensureTargets(width: width, height: height)
        guard let scene, chain.count == OrbParameters.bloomLevels else { return }

        var uniforms = makeUniforms(width: width, height: height, level: level,
                                    time: time, yaw: yaw, pitch: pitch, contentScale: contentScale)

        // ---- scene: haze first, then dots. Additive, so the order is cosmetic.
        if let encoder = makeEncoder(commandBuffer, target: scene.texture, clear: true) {
            encoder.setRenderPipelineState(orbPipeline)

            uniforms.isHaze = 1
            encoder.setVertexBuffer(haze.positions, offset: 0, index: 0)
            encoder.setVertexBuffer(haze.seeds, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: haze.count)

            uniforms.isHaze = 0
            encoder.setVertexBuffer(dots.positions, offset: 0, index: 0)
            encoder.setVertexBuffer(dots.seeds, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: dots.count)
            encoder.endEncoding()
        }

        // ---- bloom: threshold into level 0, down the chain, additively back up.
        var post = PostUniforms(
            texel: SIMD2(1 / Float(width), 1 / Float(height)),
            resolution: SIMD2(Float(width), Float(height)),
            threshold: OrbParameters.bloomThreshold,
            knee: OrbParameters.bloomKnee,
            radius: OrbParameters.bloomRadius,
            karis: 0,
            bloomStrength: OrbParameters.bloom,
            dispersion: OrbParameters.dispersion,
            grain: OrbParameters.grain,
            exposure: OrbParameters.exposure,
            seed: time * 91
        )

        drawQuad(commandBuffer, pipeline: prefilterPipeline, target: chain[0].texture,
                 textures: [scene.texture], post: &post, clear: true)

        for i in 1..<chain.count {
            post.texel = SIMD2(1 / Float(chain[i - 1].width), 1 / Float(chain[i - 1].height))
            // Karis on the first downsample only: that is the level reading raw unclamped
            // scene values, where one blown point would drag the whole glow as it moves.
            post.karis = i == 1 ? 1 : 0
            drawQuad(commandBuffer, pipeline: downsamplePipeline, target: chain[i].texture,
                     textures: [chain[i - 1].texture], post: &post, clear: true)
        }

        post.karis = 0
        for i in stride(from: chain.count - 1, to: 0, by: -1) {
            drawQuad(commandBuffer, pipeline: upsamplePipeline, target: chain[i - 1].texture,
                     textures: [chain[i].texture], post: &post, clear: false)
        }

        // ---- composite to the output.
        post.texel = SIMD2(1 / Float(width), 1 / Float(height))
        drawQuad(commandBuffer, pipeline: compositePipeline, target: output,
                 textures: [scene.texture, chain[0].texture], post: &post, clear: true)
    }

    private func makeEncoder(
        _ commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        clear: Bool
    ) -> MTLRenderCommandEncoder? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    }

    private func drawQuad(
        _ commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        target: MTLTexture,
        textures: [MTLTexture],
        post: inout PostUniforms,
        clear: Bool
    ) {
        guard let encoder = makeEncoder(commandBuffer, target: target, clear: clear) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentBytes(&post, length: MemoryLayout<PostUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makeUniforms(
        width: Int, height: Int, level: Float, time: Float,
        yaw: Float, pitch: Float, contentScale: Float
    ) -> Uniforms {
        let aspect = Float(width) / Float(max(height, 1))
        // Per-sprite alpha normalised against the prototype's 2,600-sprite reference cloud, so
        // the haze parameter means density rather than the brightness of one sprite.
        let hazeAlpha = 0.013 * OrbParameters.haze * (2600 / Float(max(haze.count, 1)))

        // The dot is a point sprite measured in pixels and the lattice is a fixed count of
        // them, so one `dotSize` covers a far larger share of a small orb than a large one:
        // at 44pt the sphere fills in solid and reads as a flat white disc rather than a
        // cloud of points. Scaled against the size the parameters were tuned at — and only
        // downward, so the HUD's larger orb keeps exactly the look it was tuned to.
        let sizeScale = min(1, Float(min(width, height))
                            / (OrbParameters.referencePoints * contentScale))

        return Uniforms(
            projection: Self.perspective(fovY: OrbParameters.fieldOfView, aspect: aspect,
                                         near: 0.1, far: 40),
            rotation: Self.rotation(yaw: yaw, pitch: pitch),
            colorA: OrbParameters.colorA,
            colorB: OrbParameters.colorB,
            colorC: OrbParameters.colorC,
            resolution: SIMD2(Float(width), Float(height)),
            time: time,
            level: level,
            reactivity: OrbParameters.reactivity,
            noiseScale: OrbParameters.noiseScale,
            amplitude: OrbParameters.amplitude,
            flow: OrbParameters.flow,
            dotSize: OrbParameters.dotSize * sizeScale,
            rim: OrbParameters.rimBoost,
            gain: OrbParameters.gain,
            spread: OrbParameters.hueSpread,
            haze: OrbParameters.haze,
            hazeAlpha: hazeAlpha,
            cameraZ: OrbParameters.cameraDistance,
            contentScale: contentScale,
            pulse: OrbParameters.pulse,
            chaos: OrbParameters.chaos,
            turbulence: OrbParameters.turbulence,
            levelFloor: OrbParameters.levelFloor,
            levelCeiling: OrbParameters.levelCeiling,
            octaves: OrbParameters.octaves,
            isHaze: 0
        )
    }

    // MARK: - Maths

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2)
        let nf = 1 / (near - far)
        return simd_float4x4(
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, (far + near) * nf, -1),
            SIMD4(0, 0, 2 * far * near * nf, 0)
        )
    }

    private static func rotation(yaw: Float, pitch: Float) -> simd_float3x3 {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        return simd_float3x3(
            SIMD3(cy, sy * sp, -sy * cp),
            SIMD3(0, cp, sp),
            SIMD3(sy, -cy * sp, cy * cp)
        )
    }
}

enum OrbError: Error {
    case bufferAllocationFailed
    case noDevice
}
