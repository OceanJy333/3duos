// input: a decoded PICADrawState and the bound texture sizes.
// output: the `Draw` uniform block of PICAMetalShaders (16-byte slots in declaration order) and Metal pipeline/depth-stencil keys.
// pos: translation of PICA register state to Metal state, done once per draw on the CPU.
import Metal

enum PICAMetalState {
    // Slots of one `Draw` block: 72 for the stage, texture, fog and lighting fields, then 9 per light.
    static let slotCount = 72 + 8 * 9

    static func uniforms(_ s: PICADrawState, textures: [PICADecodedTexture?], scale: Int) -> [SIMD4<UInt32>] {
        var slots: [SIMD4<UInt32>] = []
        slots.reserveCapacity(slotCount)
        func i(_ a: Int, _ b: Int = 0, _ c: Int = 0, _ d: Int = 0) { slots.append(SIMD4(UInt32(bitPattern: Int32(a)), UInt32(bitPattern: Int32(b)), UInt32(bitPattern: Int32(c)), UInt32(bitPattern: Int32(d)))) }
        func c(_ v: SIMD4<Int32>) { i(Int(v.x), Int(v.y), Int(v.z), Int(v.w)) }
        func f(_ a: Float, _ b: Float = 0, _ c: Float = 0, _ d: Float = 0) { slots.append(SIMD4(a.bitPattern, b.bitPattern, c.bitPattern, d.bitPattern)) }
        func f3(_ v: SIMD3<Float>) { f(v.x, v.y, v.z) }
        let stages = (0..<6).map { $0 < s.tevStages.count ? s.tevStages[$0] : PICATevStage() }
        for t in stages { i(Int(t.colorSource.0), Int(t.colorSource.1), Int(t.colorSource.2)) }
        for t in stages { i(Int(t.alphaSource.0), Int(t.alphaSource.1), Int(t.alphaSource.2)) }
        for t in stages { i(Int(t.colorModifier.0), Int(t.colorModifier.1), Int(t.colorModifier.2)) }
        for t in stages { i(Int(t.alphaModifier.0), Int(t.alphaModifier.1), Int(t.alphaModifier.2)) }
        for t in stages { i(Int(t.colorOp), Int(t.alphaOp), Int(t.colorScale), Int(t.alphaScale)) }
        for t in stages { c(t.constant) }
        for t in stages { i(t.updatesBufferColor ? 1 : 0, t.updatesBufferAlpha ? 1 : 0) }
        let m = s.merger
        i(s.tevStages.count, m.alphaTestEnabled ? 1 : 0, m.alphaFunc, Int(m.alphaRef))
        c(s.tevBufferColor)
        i(s.textures[0].enabled ? 1 : 0, s.textures[1].enabled ? 1 : 0, s.textures[2].enabled ? 1 : 0, s.textures[0].type == 3 ? 1 : 0)
        for u in 0..<3 { i(s.textures[u].wrapS, s.textures[u].wrapT, s.textures[u].linear ? 1 : 0, textures[u] == nil ? 0 : 1) }
        for u in 0..<3 { i(textures[u]?.width ?? 1, textures[u]?.height ?? 1) }
        for u in 0..<3 { c(s.textures[u].border) }
        i(s.fog.enabled ? 1 : 0, s.fog.flip ? 1 : 0); c(s.fog.color)
        let v = s.viewport
        i(s.texture2UsesCoordinate1 ? 1 : 0, v.wBuffering ? 1 : 0, v.scissorMode == 1 ? 1 : 0, s.lighting.enabled ? 1 : 0)
        i(v.scissor[0], v.scissor[1], v.scissor[2], v.scissor[3])
        f(v.depthScale, v.depthOffset, Float((1 << s.target.depthBits) - 1), Float(scale))
        f(Float(s.target.width), Float(s.target.height))
        let l = s.lighting
        i(l.lights.count, l.clampHighlights ? 1 : 0, l.primaryAlpha ? 1 : 0, l.secondaryAlpha ? 1 : 0)
        let inputs = [l.distribution0, l.distribution1, l.fresnel, l.reflect.0, l.reflect.1, l.reflect.2, l.spot]
        for p in inputs { i(p.enabled ? 1 : 0, p.source, p.absolute ? 1 : 0, p.table) }
        f(inputs[0].scale, inputs[1].scale, inputs[2].scale, inputs[3].scale); f(inputs[4].scale, inputs[5].scale, inputs[6].scale)
        f3(l.globalAmbient)
        i(m.blendEnabled ? 0 : logic(m.logicOp))
        for light in l.lights.prefix(8) {
            f3(light.specular0); f3(light.specular1); f3(light.diffuse); f3(light.ambient); f3(light.position); f3(light.spot)
            f(light.distanceBias, light.distanceScale)
            i(light.directional ? 1 : 0, light.twoSided ? 1 : 0, light.geometric0 ? 1 : 0, light.geometric1 ? 1 : 0)
            i(light.index, light.spotEnabled ? 1 : 0, light.distanceEnabled ? 1 : 0)
        }
        while slots.count < slotCount { i(0) }
        return slots
    }

    // Logic ops the fragment function emulates: clear, set and copy-inverted; noop is a write mask of zero; the rest act as copy.
    private static func logic(_ op: Int) -> Int { op == 0 ? 1 : op == 4 ? 2 : op == 5 ? 3 : 0 }

    struct PipelineKey: Hashable {
        var hasColor = true, hasDepth = true
        var blend = false, sourceRGB = 1, destRGB = 0, sourceAlpha = 1, destAlpha = 0, equationRGB = 0, equationAlpha = 0
        var writeMask = 15
        var motion = false     // the target carries MetalFX motion and reactive attachments
    }

    static func pipelineKey(_ s: PICADrawState, hasColor: Bool, hasDepth: Bool, motion: Bool) -> PipelineKey {
        let m = s.merger
        var k = PipelineKey(hasColor: hasColor, hasDepth: hasDepth, motion: motion)
        k.blend = m.blendEnabled
        if m.blendEnabled {
            k.sourceRGB = m.sourceRGB; k.destRGB = m.destRGB; k.sourceAlpha = m.sourceAlpha; k.destAlpha = m.destAlpha
            k.equationRGB = m.equationRGB; k.equationAlpha = m.equationAlpha
        }
        k.writeMask = !s.colorWrite || (!m.blendEnabled && m.logicOp == 6) ? 0 : Int(m.colorMask)
        return k
    }

    static func describe(_ k: PipelineKey, into d: MTLRenderPipelineDescriptor) {
        let factors: [MTLBlendFactor] = [.zero, .one, .sourceColor, .oneMinusSourceColor, .destinationColor, .oneMinusDestinationColor,
                                         .sourceAlpha, .oneMinusSourceAlpha, .destinationAlpha, .oneMinusDestinationAlpha, .blendColor,
                                         .oneMinusBlendColor, .blendAlpha, .oneMinusBlendAlpha, .sourceAlphaSaturated]
        let equations: [MTLBlendOperation] = [.add, .subtract, .reverseSubtract, .min, .max]
        if k.hasColor {
            let a = d.colorAttachments[0]!
            a.pixelFormat = .rgba8Unorm
            a.isBlendingEnabled = k.blend
            a.sourceRGBBlendFactor = factors[min(k.sourceRGB, 14)]; a.destinationRGBBlendFactor = factors[min(k.destRGB, 14)]
            a.sourceAlphaBlendFactor = factors[min(k.sourceAlpha, 14)]; a.destinationAlphaBlendFactor = factors[min(k.destAlpha, 14)]
            a.rgbBlendOperation = equations[min(k.equationRGB, 4)]; a.alphaBlendOperation = equations[min(k.equationAlpha, 4)]
            var mask: MTLColorWriteMask = []
            if k.writeMask & 1 != 0 { mask.insert(.red) }
            if k.writeMask & 2 != 0 { mask.insert(.green) }
            if k.writeMask & 4 != 0 { mask.insert(.blue) }
            if k.writeMask & 8 != 0 { mask.insert(.alpha) }
            a.writeMask = mask
        }
        if k.motion {
            // Translucent draws mix their motion in by coverage and raise the reactive mask; opaque draws overwrite both.
            let motion = d.colorAttachments[1]!, reactive = d.colorAttachments[2]!
            motion.pixelFormat = .rg16Float; reactive.pixelFormat = .r8Unorm
            motion.isBlendingEnabled = k.blend; reactive.isBlendingEnabled = k.blend
            motion.sourceRGBBlendFactor = .sourceAlpha; motion.destinationRGBBlendFactor = .oneMinusSourceAlpha
            reactive.rgbBlendOperation = .max
            if k.writeMask == 0 { motion.writeMask = []; reactive.writeMask = [] }
        }
        if k.hasDepth { d.depthAttachmentPixelFormat = .depth32Float_stencil8; d.stencilAttachmentPixelFormat = .depth32Float_stencil8 }
    }

    struct DepthKey: Hashable {
        var depthFunc = 1, depthWrite = false, stencil = false, stencilFunc = 1, readMask: UInt8 = 0, writeMask: UInt8 = 0
        var fail = 0, depthFail = 0, pass = 0
    }

    static func depthKey(_ s: PICADrawState) -> DepthKey {
        let m = s.merger
        var k = DepthKey()
        k.depthFunc = m.depthTestEnabled ? m.depthFunc : 1
        k.depthWrite = s.depthStencilWrite && m.depthWrite
        if m.stencilEnabled && s.target.depthFormat == 3 {
            k.stencil = true; k.stencilFunc = m.stencilFunc; k.readMask = m.stencilInputMask
            k.writeMask = s.depthStencilWrite ? m.stencilWriteMask : 0
            k.fail = m.stencilFail; k.depthFail = m.stencilDepthFail; k.pass = m.stencilPass
        }
        return k
    }

    static func describe(_ k: DepthKey) -> MTLDepthStencilDescriptor {
        let functions: [MTLCompareFunction] = [.never, .always, .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual]
        let operations: [MTLStencilOperation] = [.keep, .zero, .replace, .incrementClamp, .decrementClamp, .invert, .incrementWrap, .decrementWrap]
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = functions[k.depthFunc & 7]
        d.isDepthWriteEnabled = k.depthWrite
        if k.stencil {
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = functions[k.stencilFunc & 7]
            s.readMask = UInt32(k.readMask); s.writeMask = UInt32(k.writeMask)
            s.stencilFailureOperation = operations[k.fail & 7]; s.depthFailureOperation = operations[k.depthFail & 7]
            s.depthStencilPassOperation = operations[k.pass & 7]
            d.frontFaceStencil = s; d.backFaceStencil = s
        }
        return d
    }
}
