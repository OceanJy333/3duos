// input: one queued draw's state, surfaces and textures, and covered pixels with their edge values.
// output: the shaded, tested and blended pixel written into the tiled color/depth mirrors.
// pos: per-pixel stage of the software rasterizer: interpolation, texturing, lighting, TEV, fog, depth/stencil and blend.
import Foundation

struct PICARasterContext {
    var color: UnsafeMutablePointer<UInt8>?, depth: UnsafeMutablePointer<UInt8>?
    var width = 0, height = 0
    var colorFormat = 0, colorBytes = 4, depthBytes = 4
    var writeColor = true
    var samplers: (PICASampler, PICASampler, PICASampler)
    var textureEnabled: (Bool, Bool, Bool)
    var projectTexture0 = false, texture2UsesCoordinate1 = false
    var usesTexture = false
    var tev: PICATevPipeline
    var merger: PICAMergerPipeline
    var earlyDepth: Bool               // nothing after the combiner can discard the fragment
    var replaces: Bool                 // blending leaves the fragment unchanged, so the destination is never read
    var lightingState: PICALightingState, lighting: PICALightingPipeline?
    var fog: PICAFog
    var depthScale: Float, depthOffset: Float, wBuffering: Bool, maxDepth: Float
    var scissorMode: Int, scissor: SIMD4<Int>

    init(state: PICADrawState, color: PICASurface?, depth: PICASurface?, textures: [PICADecodedTexture?]) {
        func sampler(_ unit: Int) -> PICASampler {
            let u = state.textures[unit]
            var s = PICASampler()
            if let t = textures[unit] { s.pixels = UnsafePointer(t.pixels); s.width = Int32(t.width); s.height = Int32(t.height) }
            s.wrapS = Int32(u.wrapS); s.wrapT = Int32(u.wrapT); s.linear = u.linear
            s.border = UInt32(truncatingIfNeeded: u.border.x | u.border.y << 8 | u.border.z << 16 | u.border.w << 24)
            return s
        }
        self.color = color?.bytes; self.depth = depth?.bytes
        width = state.target.width; height = state.target.height
        colorFormat = state.target.colorFormat; colorBytes = state.target.bytesPerColorPixel; depthBytes = state.target.bytesPerDepthPixel
        writeColor = state.colorWrite && color != nil
        samplers = (sampler(0), sampler(1), sampler(2))
        textureEnabled = (state.textures[0].enabled, state.textures[1].enabled, state.textures[2].enabled)
        usesTexture = textureEnabled.0 || textureEnabled.1 || textureEnabled.2
        projectTexture0 = state.textures[0].type == 3; texture2UsesCoordinate1 = state.texture2UsesCoordinate1
        tev = PICATevPipeline(stages: nil, stageCount: state.tevStages.count, bufferColor: state.tevBufferColor)
        merger = PICAMergerPipeline(merger: state.merger, depthFormat: state.target.depthFormat, depthBits: state.target.depthBits,
                                    depthStencilWrite: state.depthStencilWrite)
        earlyDepth = merger.canTestDepthEarly
        replaces = merger.replacesDestination
        lightingState = state.lighting; lighting = nil
        fog = state.fog
        depthScale = state.viewport.depthScale; depthOffset = state.viewport.depthOffset; wBuffering = state.viewport.wBuffering
        maxDepth = Float((1 << state.target.depthBits) - 1)
        scissorMode = state.viewport.scissorMode; scissor = state.viewport.scissor
    }

    // Points the combiner and lighting at this draw's stages and lights once their storage is stable.
    mutating func bind(stages: UnsafePointer<PICATevStage>?, lights: UnsafePointer<PICALight>?) {
        tev = PICATevPipeline(stages: stages, stageCount: tev.stageCount, bufferColor: tev.bufferColor)
        if lightingState.enabled, let lut = lightingState.lut, let lights {
            lighting = PICALightingPipeline(state: lightingState, lights: lights, lut: lut)
        }
    }

    @inline(__always)
    func shade(_ t: PICASetupTriangle, _ px: Int, _ py: Int, _ edge: SIMD3<Int>, _ stats: inout PICARasterStats) {
        stats.covered += 1
        let f = SIMD3<Float>(Float(edge.x), Float(edge.y), Float(edge.z))
        let reciprocalW = (t.invW * f).sum()
        guard reciprocalW > 0 else { return }
        let scale = 1 / reciprocalW
        var depthValue = (t.z * f).sum() / Float(t.area) * depthScale + depthOffset
        if wBuffering { depthValue *= Float(t.area) * scale }
        let z = UInt32((depthValue > 0 ? min(depthValue, 1) : 0) * maxDepth)
        let tile = PICAMath.tiledIndex(px, height - 1 - py, width: width)
        let depthPointer = depth.map { $0 + tile * depthBytes }
        if earlyDepth, let p = depthPointer, !merger.depthStencilPasses(p, depth: z) { stats.depthFailed += 1; return }

        let primary = PICAColor(clampedColor: (t.color.0 * f.x + t.color.1 * f.y + t.color.2 * f.z) * (scale * 255))
        var textures = (PICAColor(repeating: 0), PICAColor(repeating: 0), PICAColor(repeating: 0))
        if usesTexture {
            let uv01 = (t.texture01.0 * f.x + t.texture01.1 * f.y + t.texture01.2 * f.z) * scale
            let uv2W = (t.texture2W.0 * f.x + t.texture2W.1 * f.y + t.texture2W.2 * f.z) * scale
            @inline(__always) func fetch(_ s: PICASampler, _ u: Float, _ v: Float) -> PICAColor {
                s.pixels == nil ? PICAColor(0, 0, 0, 255) : s.sample(u: u, v: v)
            }
            if textureEnabled.0 {
                textures.0 = projectTexture0 ? fetch(samplers.0, uv01.x / uv2W.z, uv01.y / uv2W.z) : fetch(samplers.0, uv01.x, uv01.y)
            }
            if textureEnabled.1 { textures.1 = fetch(samplers.1, uv01.z, uv01.w) }
            if textureEnabled.2 { textures.2 = texture2UsesCoordinate1 ? fetch(samplers.2, uv01.z, uv01.w) : fetch(samplers.2, uv2W.x, uv2W.y) }
        }
        var lit = (PICAColor(repeating: 0), PICAColor(repeating: 0))
        if let lighting {
            let q = (t.quaternion.0 * f.x + t.quaternion.1 * f.y + t.quaternion.2 * f.z) * scale
            let view = (t.view.0 * f.x + t.view.1 * f.y + t.view.2 * f.z) * scale
            lit = lighting.evaluate(quaternion: q, view: SIMD3(view.x, view.y, view.z))
        }
        var fragment = tev.evaluate(primary: primary, lit: lit, textures: textures)
        guard merger.alphaPasses(fragment.w) else { stats.alphaFailed += 1; return }
        if fog.enabled, let table = fog.lut {
            let clamped = depthValue > 0 ? min(depthValue, 1) : 0
            let index = (fog.flip ? 1 - clamped : clamped) * 128, i = min(max(index.rounded(.down), 0), 127)
            let entry = table[Int(i)]
            let difference = Float(Int32(bitPattern: entry << 19) >> 19) / 2047
            let factor = min(max(Float((entry >> 13) & 0x7FF) / 2047 + difference * (index - i), 0), 1)
            @inline(__always) func mix(_ a: Int32, _ b: Int32) -> Int32 { Int32(Float(a) * factor + Float(b) * (1 - factor)) }
            fragment = PICAColor(mix(fragment.x, fog.color.x), mix(fragment.y, fog.color.y), mix(fragment.z, fog.color.z), fragment.w)
        }
        if !earlyDepth, let p = depthPointer, !merger.depthStencilPasses(p, depth: z) { stats.depthFailed += 1; return }
        guard writeColor, let colorBase = color else { return }
        stats.written += 1
        let p = colorBase + tile * colorBytes
        let result = replaces ? fragment : merger.blend(fragment, over: PICASampler.unpack(PICAColorFormat.read(p, colorFormat)))
        PICAColorFormat.write(p, colorFormat, UInt32(result.x) | UInt32(result.y) << 8 | UInt32(result.z) << 16 | UInt32(result.w) << 24)
    }
}

extension SIMD4 where Scalar == Int32 {
    // Rounds a color in 0...255 float units to integers; NaN becomes 0. Per lane, because the generic
    // SIMD rounding initializer is not specialized and dominated the pixel loop.
    @inline(__always) init(clampedColor c: SIMD4<Float>) {
        @inline(__always) func lane(_ f: Float) -> Int32 { f > 0 ? Int32(Swift.min(f, 255) + 0.5) : 0 }
        self.init(lane(c.x), lane(c.y), lane(c.z), lane(c.w))
    }
}
