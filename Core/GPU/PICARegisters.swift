// input: PICA internal register indices (0x000-0x2FF) as laid out on 3dbrew GPU/Internal_Registers.
// output: named register indices and typed readers over the 0x300-word register file.
// pos: register map shared by the command processor, draw-state snapshot and shader/vertex front ends.

enum PICAReg {
    static let count = 0x300
    static let finalize = 0x10
    // Rasterizer
    static let cullMode = 0x40, viewportHalfWidth = 0x41, viewportHalfHeight = 0x43
    static let clipEnable = 0x47, clipCoefficients = 0x48
    static let depthScale = 0x4D, depthOffset = 0x4E
    static let outputTotal = 0x4F, outputMap = 0x50
    static let scissorMode = 0x65, scissorMin = 0x66, scissorMax = 0x67, viewportCorner = 0x68, depthMap = 0x6D
    // Texturing
    static let textureConfig = 0x80, texture0 = 0x81, texture0Format = 0x8E, texture1 = 0x91, texture1Format = 0x96
    static let texture2 = 0x99, texture2Format = 0x9E
    static let tevStages = [0xC0, 0xC8, 0xD0, 0xD8, 0xF0, 0xF8]
    static let tevBufferInput = 0xE0, fogColor = 0xE1, fogIndex = 0xE6, fogData = 0xE8, tevBufferColor = 0xFD
    // Fragment lighting
    static let lightingTableIndex = 0x1C5, lightingTableData = 0x1C8
    // Output merger and framebuffer
    static let blendEnable = 0x100, blendFunction = 0x101, logicOp = 0x102, blendColor = 0x103, alphaTest = 0x104
    static let stencilTest = 0x105, stencilOp = 0x106, depthColorMask = 0x107
    static let framebufferFlush = 0x110, framebufferInvalidate = 0x111
    static let colorWriteMask = 0x113, depthWriteMask = 0x115, depthFormat = 0x116, colorFormat = 0x117
    static let depthAddress = 0x11C, colorAddress = 0x11D, framebufferSize = 0x11E
    // Vertex input and draw triggers
    static let attributeBase = 0x200, attributeFormats = 0x201, attributeFormatsHigh = 0x202, attributeLoaders = 0x203
    static let indexArray = 0x227, vertexCount = 0x228, useGeometryShader = 0x229, vertexOffset = 0x22A
    static let drawArrays = 0x22E, drawElements = 0x22F
    static let defaultAttributeIndex = 0x232, defaultAttributeData = 0x233
    static let commandBufferSize = 0x238, commandBufferAddress = 0x23A, commandBufferTrigger = 0x23C
    static let topology = 0x25E, restartPrimitive = 0x25F
    // Vertex shader unit
    static let boolUniforms = 0x2B0, intUniforms = 0x2B1, inputConfig = 0x2B9, entryPoint = 0x2BA
    static let inputPermutation = 0x2BB, outputMask = 0x2BD
    static let uniformIndex = 0x2C0, uniformData = 0x2C1
    static let programOffset = 0x2CB, programData = 0x2CC, swizzleOffset = 0x2D5, swizzleData = 0x2D6
}

struct PICARegisters {
    private(set) var words = [UInt32](repeating: 0, count: PICAReg.count)

    subscript(_ register: Int) -> UInt32 {
        get { words[register] }
        set { words[register] = newValue }
    }

    // Bits `low..<low+width` of a register.
    @inline(__always) func field(_ register: Int, _ low: Int, _ width: Int) -> Int {
        Int((words[register] >> UInt32(low)) & ((1 << UInt32(width)) - 1))
    }

    func float24(_ register: Int) -> Float { PICAMath.float24(words[register]) }

    // Registers hold byte addresses divided by 8 (or 16 for vertex data) in their low 28 bits.
    func physicalAddress(_ register: Int) -> UInt32 { (words[register] & 0x0FFF_FFFF) &* 8 }
}
