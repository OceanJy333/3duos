// input: the PICA register file at the moment a draw is triggered.
// output: an immutable, decoded snapshot of viewport, render target, textures, TEV stages and output merger.
// pos: the contract between the PICA front end and any pixel backend (software today, Metal later).

struct PICATevStage {
    var colorSource: (UInt8, UInt8, UInt8) = (15, 15, 15)
    var colorModifier: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var alphaSource: (UInt8, UInt8, UInt8) = (15, 15, 15)
    var alphaModifier: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var colorOp: UInt8 = 0, alphaOp: UInt8 = 0
    var colorScale: Int32 = 1, alphaScale: Int32 = 1
    var constant = SIMD4<Int32>(repeating: 0)
    var updatesBufferColor = false, updatesBufferAlpha = false

    // A stage that forwards the previous result unchanged; trailing ones need not run.
    var isPassThrough: Bool {
        colorSource.0 == 15 && alphaSource.0 == 15 && colorOp == 0 && alphaOp == 0 && colorModifier.0 == 0
            && alphaModifier.0 == 0 && colorScale == 1 && alphaScale == 1 && !updatesBufferColor && !updatesBufferAlpha
    }
}

struct PICATextureUnit {
    var enabled = false
    var address: UInt32 = 0          // physical
    var width = 0, height = 0
    var format = 0                   // 0 RGBA8 ... 13 ETC1A4
    var wrapS = 0, wrapT = 0         // 0 clamp edge, 1 clamp border, 2 repeat, 3 mirror (4-7 are variants)
    var linear = false
    var border = SIMD4<Int32>(repeating: 0)
    var type = 0                     // unit 0 only: 0 2D, 3 projection, others unsupported
}

struct PICAOutputMerger {
    var blendEnabled = false
    var equationRGB = 0, equationAlpha = 0
    var sourceRGB = 0, destRGB = 0, sourceAlpha = 0, destAlpha = 0
    var blendColor = SIMD4<Int32>(repeating: 0)
    var logicOp = 0
    var alphaTestEnabled = false, alphaFunc = 0, alphaRef: Int32 = 0
    var stencilEnabled = false, stencilFunc = 0
    var stencilWriteMask: UInt8 = 0, stencilRef: UInt8 = 0, stencilInputMask: UInt8 = 0
    var stencilFail = 0, stencilDepthFail = 0, stencilPass = 0
    var depthTestEnabled = false, depthFunc = 0, depthWrite = false
    var colorMask: UInt8 = 15        // bits: red, green, blue, alpha
}

// Fog combiner (mode 5): mixes the fog color in by a 128-entry table indexed with depth.
struct PICAFog {
    var enabled = false, flip = false
    var color = SIMD4<Int32>(repeating: 0)
    var lut: UnsafePointer<UInt32>?                // owned by the renderer
}

struct PICAViewport {
    var halfWidth: Float = 0, halfHeight: Float = 0
    var cornerX: Float = 0, cornerY: Float = 0
    var depthScale: Float = 1, depthOffset: Float = 0
    var wBuffering = false
    var cullMode = 0                 // 0/3 keep all, 1 keep clockwise, 2 keep counter-clockwise
    var scissorMode = 0              // 1 exclude inside, 3 include inside
    var scissor = SIMD4<Int>(repeating: 0)   // x1, y1, x2, y2 inclusive
    var clipEnabled = false
    var clipPlane = SIMD4<Float>(repeating: 0)
}

struct PICARenderTargetDescription: Equatable {
    var colorAddress: UInt32 = 0, depthAddress: UInt32 = 0     // physical
    var width = 0, height = 0
    var colorFormat = 0              // 0 RGBA8, 1 RGB8, 2 RGB5A1, 3 RGB565, 4 RGBA4
    var depthFormat = 0              // 0 D16, 2 D24, 3 D24S8
    var bytesPerColorPixel: Int { [4, 3, 2, 2, 2][min(colorFormat, 4)] }
    var bytesPerDepthPixel: Int { [2, 2, 3, 4][depthFormat & 3] }
    var depthBits: Int { depthFormat == 0 ? 16 : 24 }
}

struct PICADrawState {
    var viewport = PICAViewport()
    var target = PICARenderTargetDescription()
    var merger = PICAOutputMerger()
    var colorWrite = true, depthStencilWrite = true
    var overlay = false   // set by the renderer: a 2D top-screen draw (text, HUD) that goes into the UI layer
    var textures = [PICATextureUnit](repeating: PICATextureUnit(), count: 3)
    var tevStages: [PICATevStage] = []
    var tevBufferColor = SIMD4<Int32>(repeating: 0)
    var texture2UsesCoordinate1 = false
    var lighting = PICALightingState()
    var fog = PICAFog()

    init() {}

    init(_ r: PICARegisters) {
        viewport = Self.viewport(r)
        target = PICARenderTargetDescription(
            colorAddress: r.physicalAddress(PICAReg.colorAddress), depthAddress: r.physicalAddress(PICAReg.depthAddress),
            width: r.field(PICAReg.framebufferSize, 0, 11), height: r.field(PICAReg.framebufferSize, 12, 10) + 1,
            colorFormat: r.field(PICAReg.colorFormat, 16, 3), depthFormat: r.field(PICAReg.depthFormat, 0, 2))
        merger = Self.merger(r)
        colorWrite = r.field(PICAReg.colorWriteMask, 0, 4) != 0
        depthStencilWrite = r.field(PICAReg.depthWriteMask, 0, 2) != 0
        textures = (0..<3).map { Self.texture(r, $0) }
        textures[0].type = r.field(PICAReg.texture0 + 2, 28, 3)
        texture2UsesCoordinate1 = r.field(PICAReg.textureConfig, 13, 1) != 0
        var stages = (0..<6).map { Self.tevStage(r, $0) }
        while let last = stages.last, last.isPassThrough, stages.count > 1 { stages.removeLast() }
        tevStages = stages
        tevBufferColor = Self.color(r[PICAReg.tevBufferColor])
        lighting = PICALightingState(r)
        fog.enabled = r.field(PICAReg.tevBufferInput, 0, 3) == 5
        fog.flip = r.field(PICAReg.tevBufferInput, 16, 1) != 0
        fog.color = Self.color(r[PICAReg.fogColor])
    }

    static func color(_ packed: UInt32) -> SIMD4<Int32> {
        SIMD4(Int32(packed & 255), Int32((packed >> 8) & 255), Int32((packed >> 16) & 255), Int32(packed >> 24))
    }

    private static func viewport(_ r: PICARegisters) -> PICAViewport {
        var v = PICAViewport()
        v.halfWidth = r.float24(PICAReg.viewportHalfWidth); v.halfHeight = r.float24(PICAReg.viewportHalfHeight)
        let corner = r[PICAReg.viewportCorner]
        v.cornerX = Float(Int32(truncatingIfNeeded: corner << 22) >> 22)
        v.cornerY = Float(Int32(truncatingIfNeeded: (corner >> 16) << 22) >> 22)
        v.depthScale = r.float24(PICAReg.depthScale); v.depthOffset = r.float24(PICAReg.depthOffset)
        v.wBuffering = r.field(PICAReg.depthMap, 0, 1) == 0
        v.cullMode = r.field(PICAReg.cullMode, 0, 2)
        v.scissorMode = r.field(PICAReg.scissorMode, 0, 2)
        v.scissor = SIMD4(r.field(PICAReg.scissorMin, 0, 10), r.field(PICAReg.scissorMin, 16, 10),
                          r.field(PICAReg.scissorMax, 0, 10), r.field(PICAReg.scissorMax, 16, 10))
        v.clipEnabled = r.field(PICAReg.clipEnable, 0, 1) != 0
        v.clipPlane = SIMD4((0..<4).map { r.float24(PICAReg.clipCoefficients + $0) })
        return v
    }

    private static func merger(_ r: PICARegisters) -> PICAOutputMerger {
        var m = PICAOutputMerger()
        m.blendEnabled = r.field(PICAReg.blendEnable, 8, 1) != 0
        let f = PICAReg.blendFunction
        m.equationRGB = r.field(f, 0, 3); m.equationAlpha = r.field(f, 8, 3)
        m.sourceRGB = r.field(f, 16, 4); m.destRGB = r.field(f, 20, 4)
        m.sourceAlpha = r.field(f, 24, 4); m.destAlpha = r.field(f, 28, 4)
        m.blendColor = color(r[PICAReg.blendColor])
        m.logicOp = r.field(PICAReg.logicOp, 0, 4)
        m.alphaTestEnabled = r.field(PICAReg.alphaTest, 0, 1) != 0
        m.alphaFunc = r.field(PICAReg.alphaTest, 4, 3); m.alphaRef = Int32(r.field(PICAReg.alphaTest, 8, 8))
        let s = PICAReg.stencilTest
        m.stencilEnabled = r.field(s, 0, 1) != 0; m.stencilFunc = r.field(s, 4, 3)
        m.stencilWriteMask = UInt8(r.field(s, 8, 8)); m.stencilRef = UInt8(r.field(s, 16, 8)); m.stencilInputMask = UInt8(r.field(s, 24, 8))
        m.stencilFail = r.field(PICAReg.stencilOp, 0, 3); m.stencilDepthFail = r.field(PICAReg.stencilOp, 4, 3)
        m.stencilPass = r.field(PICAReg.stencilOp, 8, 3)
        let d = PICAReg.depthColorMask
        m.depthTestEnabled = r.field(d, 0, 1) != 0; m.depthFunc = r.field(d, 4, 3); m.depthWrite = r.field(d, 12, 1) != 0
        m.colorMask = UInt8(r.field(d, 8, 4))
        return m
    }

    private static func texture(_ r: PICARegisters, _ unit: Int) -> PICATextureUnit {
        let base = [PICAReg.texture0, PICAReg.texture1, PICAReg.texture2][unit]
        let format = [PICAReg.texture0Format, PICAReg.texture1Format, PICAReg.texture2Format][unit]
        var t = PICATextureUnit()
        t.enabled = r.field(PICAReg.textureConfig, unit, 1) != 0
        t.border = color(r[base])
        t.width = r.field(base + 1, 16, 11); t.height = r.field(base + 1, 0, 11)
        t.linear = r.field(base + 2, 1, 1) != 0
        t.wrapT = r.field(base + 2, 8, 3); t.wrapS = r.field(base + 2, 12, 3)
        t.address = r.physicalAddress(base + 4)
        t.format = r.field(format, 0, 4)
        return t
    }

    private static func tevStage(_ r: PICARegisters, _ index: Int) -> PICATevStage {
        let base = PICAReg.tevStages[index]
        let sources = r[base], modifiers = r[base + 1], ops = r[base + 2], scales = r[base + 4]
        func nibble(_ v: UInt32, _ shift: UInt32) -> UInt8 { UInt8((v >> shift) & 15) }
        var s = PICATevStage()
        s.colorSource = (nibble(sources, 0), nibble(sources, 4), nibble(sources, 8))
        s.alphaSource = (nibble(sources, 16), nibble(sources, 20), nibble(sources, 24))
        s.colorModifier = (nibble(modifiers, 0), nibble(modifiers, 4), nibble(modifiers, 8))
        s.alphaModifier = (nibble(modifiers, 12) & 7, nibble(modifiers, 16) & 7, nibble(modifiers, 20) & 7)
        s.colorOp = nibble(ops, 0); s.alphaOp = nibble(ops, 16)
        s.constant = color(r[base + 3])
        s.colorScale = scales & 3 < 3 ? 1 << Int32(scales & 3) : 1
        s.alphaScale = (scales >> 16) & 3 < 3 ? 1 << Int32((scales >> 16) & 3) : 1
        s.updatesBufferColor = index < 4 && r.field(PICAReg.tevBufferInput, 8 + index, 1) != 0
        s.updatesBufferAlpha = index < 4 && r.field(PICAReg.tevBufferInput, 12 + index, 1) != 0
        return s
    }
}
