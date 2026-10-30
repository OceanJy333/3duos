// input: GX command-list submissions (guest address and size) and the guest memory they and their data live in.
// output: triangles rendered into the game's color/depth buffers in guest memory, plus a per-draw info record.
// pos: PICA200 front end. Parses command lists, keeps the register file, fetches vertices and assembles primitives. With Metal
//      the vertex shader runs on the GPU (PICAMesh); the software rasterizer gets triangles shaded and clipped on the CPU.
import Foundation
import Metal

// What the renderer exposes after each draw, e.g. for MetalFX depth, motion and jitter inputs.
struct PICADrawInfo {
    let state: PICADrawState
    let triangleCount: Int                   // before clipping
    let color: PICASurface?, depth: PICASurface?
    var targetWidth: Int { state.target.width }
    var targetHeight: Int { state.target.height }
    var colorPointer: UnsafeMutablePointer<UInt8>? { color?.bytes }
    var depthPointer: UnsafeMutablePointer<UInt8>? { depth?.bytes }
}

final class PICARenderer {
    private let rasterizer = PICARasterizer()
    private(set) var metal: PICAMetalBackend?
    var backend: PICAPixelBackend { metal ?? rasterizer }
    var onDraw: ((PICADrawInfo) -> Void)?
    var onFinishFrame: (() -> Void)?      // called before the finished frame's motion is published
    private(set) var lastDraw: PICADrawInfo?
    private(set) var registers = PICARegisters()
    private(set) var drawCount = 0
    private(set) var listCount = 0
    private(set) var skippedGeometryShaderDraws = 0
    private(set) var busyNanoseconds: UInt64 = 0     // time spent executing command lists, for performance checks
    private(set) var vertexNanoseconds: UInt64 = 0   // of which vertex fetch and shader
    private(set) var renderToTextureCount = 0

    private let memory: PagedMemory
    let program = PICAShaderProgram()
    private let vertexProcessor = PICAVertexProcessor()
    let motion = PICAMotionTracker()
    private let surfaces = PICASurfaceCache()
    private let textures = PICATextureCache()
    private var topology = 0
    private var immediate = PICAPrimitiveAssembler<[SIMD4<Float>]>()   // raw attributes; draws assemble their own primitives
    private var defaultAttributes = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 16)
    private var attributeWords: [UInt32] = []
    private var immediateVertex = [SIMD4<Float>](repeating: .zero, count: 16)
    private var immediateAttribute = 0
    private var jump: (address: UInt32, size: UInt32)?
    private let lightingTables = UnsafeMutablePointer<UInt32>.allocate(capacity: 24 * 256)
    private let fogTable = UnsafeMutablePointer<UInt32>.allocate(capacity: 128)

    // `metal`: render on the GPU at `internalScale` when a Metal device exists; otherwise (and for tests) the software rasterizer.
    init(memory: PagedMemory, metal: Bool = false, internalScale: Int = 3) {
        self.memory = memory
        lightingTables.initialize(repeating: 0, count: 24 * 256)
        fogTable.initialize(repeating: 0, count: 128)
        self.internalScale = internalScale
        surfaces.willEvict = { [unowned self] in backend.finish() }
        if metal { useMetal() }
    }

    // Resolution multiplier of the Metal backend (1...4). Changing it recreates the GPU targets from guest memory.
    var internalScale: Int { didSet { if metal != nil, internalScale != oldValue { useMetal() } } }
    var usesMetal: Bool { metal != nil }
    var metalDevice: MTLDevice? { metal?.device }

    private func useMetal() {
        backend.finish()
        guard let m = PICAMetalBackend(scale: internalScale) else { return }
        m.tracksMotion = emitsMotionInputs
        m.textures.filters = filtersTextures
        m.textures.pack = texturePack
        metal = m
    }

    private let frameLock = NSLock()
    // Per LCD buffer (virtual address): the sequence of the latest display transfer into it, and its high-res frame.
    private var latestTransfer: [UInt32: Int] = [:], frames: [UInt32: PICAHighResFrame] = [:], frameSequence = 0

    // The high-res image of the LCD buffer at `address` (Metal only): the latest completed GPU transfer into it, nil when
    // its latest transfer was not rendered on the GPU. Safe to call from any thread; GPUState.highResFrame(_:) looks up the displayed buffer.
    func highResFrame(at address: UInt32) -> PICAHighResFrame? {
        frameLock.lock(); defer { frameLock.unlock() }
        return frames[GPUState.virtualAddress(address)]
    }

    // GX command-queue events from the GSP service, in submission order.
    func memoryFilled(start: UInt32, end: UInt32, value: UInt32, width: UInt32) { metal?.fill(start: start, end: end, value: value, width: width) }
    func guestWritten(_ start: UInt32, length: Int) { metal?.guestWritten(start, length: length) }
    // With Metal, renders the high-res LCD frame on the GPU; the native transfer then needs guest memory only if `keepsNativeFrames`.
    var keepsNativeFrames = true
    func displayTransfer(_ transfer: DisplayTransfer, memory: PagedMemory) {
        if let metal {
            frameSequence += 1
            let address = GPUState.virtualAddress(transfer.output), sequence = frameSequence
            frameLock.lock(); latestTransfer[address] = sequence; frameLock.unlock()
            let handled = metal.lcdFrame(transfer, sequence: sequence, shift: published.shift, depthReversed: published.depthReversed) { [weak self] frame in
                guard let self else { return }
                frameLock.lock(); if latestTransfer[address] == sequence { frames[address] = frame }; frameLock.unlock()
            }
            if !handled { frameLock.lock(); frames[address] = nil; frameLock.unlock() }
            if handled, !keepsNativeFrames { return }
            syncGuest()
        }
        transfer.run(memory: memory)
    }
    deinit { lightingTables.deallocate(); fogTable.deallocate() }

    // Called when the game hands a finished frame to the display; publishes this frame's motion and keeps its uniforms for the next.
    func finishFrame() {
        guard motion.hasDraws else { return }
        onFinishFrame?()
        published = (appliedShift, topDepthReversed)
        appliedShift = .zero
        motion.finishFrame()
        frameIndex += 1
        // Within half an output pixel: an LCD pixel spans `internalScale` pixels of a GPU-rendered frame.
        let pixel = Float(metal == nil ? 1 : internalScale)
        jitter = emitsMotionInputs && jittersTopScreen ? SIMD2(Self.halton(frameIndex % 8 + 1, 2) - 0.5, Self.halton(frameIndex % 8 + 1, 3) - 0.5) / pixel : .zero
    }
    // The finished frame's top-screen geometry shift (native target pixels) and depth direction, for MetalFX.
    private(set) var published = (shift: SIMD2<Float>.zero, depthReversed: false)
    private var appliedShift = SIMD2<Float>.zero, topDepthReversed = false

    // Sub-pixel jitter for MetalFX temporal accumulation: a Halton(2,3) offset in LCD pixels, applied to top-screen viewports.
    // With Metal the renderer also writes exact per-pixel motion; the software path rasterizes it on the CPU.
    // Pre-scales bilinear-sampled textures 2x on the GPU (Metal only), so magnified textures stay sharp.
    var filtersTextures = false { didSet { metal?.textures.filters = filtersTextures } }
    // Replacement textures (Citra/Azahar pack layout) and texture dumping (Metal only).
    var texturePack: PICATexturePack? { didSet { metal?.textures.pack = texturePack } }
    var emitsMotionInputs = false { didSet { metal?.tracksMotion = emitsMotionInputs } }
    var jittersTopScreen = true
    private var frameIndex = 0
    private(set) var jitter = SIMD2<Float>.zero

    private static func halton(_ index: Int, _ base: Int) -> Float {
        var f: Float = 1, r: Float = 0, i = index
        while i > 0 { f /= Float(base); r += f * Float(i % base); i /= base }
        return r
    }

    private func drawState() -> PICADrawState {
        var state = PICADrawState(registers)
        if emitsMotionInputs, state.target.height == 400 {
            // LCD column runs along target y; LCD row runs against target x (which may be 2x supersampled).
            appliedShift = SIMD2(-jitter.y * Float(max(1, state.target.width / 240)), jitter.x)
            state.viewport.cornerX += appliedShift.x
            state.viewport.cornerY += appliedShift.y
            if state.merger.depthTestEnabled, state.merger.depthWrite { topDepthReversed = state.merger.depthFunc >= 6 }   // greater, gequal
        }
        return state
    }

    func processCommandList(address: UInt32, size: UInt32) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { busyNanoseconds += DispatchTime.now().uptimeNanoseconds - started }
        listCount += 1
        surfaces.beginCommandList()
        textures.invalidate()
        var next: (address: UInt32, size: UInt32)? = (address, size)
        while let list = next {
            next = nil
            var words = [UInt32](repeating: 0, count: Int(list.size) / 4)
            guard memory.copyOut(GPUState.virtualAddress(list.address), to: &words, count: words.count * 4) else { break }
            for write in PICACommandDecoder.decode(words).writes {
                apply(write)
                if let target = jump { jump = nil; next = target; break }
            }
        }
        backend.submit()
        surfaces.flush(memory)
    }

    // Makes guest memory hold every rendered result. The GSP service calls it before anything reads or writes that memory.
    func syncGuest() {
        backend.finish()
        surfaces.flush(memory)
    }

    private func apply(_ write: PICARegisterWrite) {
        let index = Int(write.register)
        guard index < PICAReg.count else { return }
        registers[index] = write.applying(to: registers[index])
        let value = write.value
        switch index {
        case PICAReg.drawArrays, PICAReg.drawElements: draw(indexed: index == PICAReg.drawElements)
        case PICAReg.defaultAttributeIndex: attributeWords.removeAll(); immediateAttribute = 0
        case PICAReg.defaultAttributeData...PICAReg.defaultAttributeData + 2: submitAttributeWord(value)
        case PICAReg.commandBufferTrigger, PICAReg.commandBufferTrigger + 1:
            let channel = index - PICAReg.commandBufferTrigger
            jump = (registers.physicalAddress(PICAReg.commandBufferAddress + channel), UInt32(registers.field(PICAReg.commandBufferSize + channel, 0, 20)) * 8)
        case PICAReg.topology: topology = registers.field(PICAReg.topology, 8, 2); immediate.topology = topology
        case PICAReg.restartPrimitive: immediate.reset()
        case PICAReg.uniformIndex: program.setUniformIndex(registers[index])
        case PICAReg.uniformData...PICAReg.uniformData + 7: program.appendUniform(value)
        case PICAReg.programOffset: program.setCodeOffset(registers[index])
        case PICAReg.programData...PICAReg.programData + 7: program.appendCode(value)
        case PICAReg.swizzleOffset: program.setSwizzleOffset(registers[index])
        case PICAReg.swizzleData...PICAReg.swizzleData + 7: program.appendSwizzle(value)
        case PICAReg.lightingTableData...PICAReg.lightingTableData + 7:
            backend.tablesWillChange()
            let index = registers.field(PICAReg.lightingTableIndex, 0, 8), table = registers.field(PICAReg.lightingTableIndex, 8, 5)
            if table < 24 { lightingTables[table * 256 + index] = value }
            registers[PICAReg.lightingTableIndex] = registers[PICAReg.lightingTableIndex] & ~0xFF | UInt32((index + 1) & 0xFF)
        case PICAReg.fogData...PICAReg.fogData + 7:
            backend.tablesWillChange()
            let index = registers.field(PICAReg.fogIndex, 0, 16)
            fogTable[index % 128] = value
            registers[PICAReg.fogIndex] = registers[PICAReg.fogIndex] & ~0xFFFF | UInt32((index + 1) & 0xFFFF)
        default: break
        }
    }

    // Three words encode one float24 vec4. Index 0xF selects immediate mode, any other index sets a default attribute.
    private func submitAttributeWord(_ word: UInt32) {
        attributeWords.append(word)
        guard attributeWords.count == 3 else { return }
        let x = attributeWords[2] & 0xFFFFFF
        let y = (attributeWords[1] & 0xFFFF) << 8 | attributeWords[2] >> 24
        let z = (attributeWords[0] & 0xFF) << 16 | attributeWords[1] >> 16
        let w = attributeWords[0] >> 8
        attributeWords.removeAll(keepingCapacity: true)
        let attribute = SIMD4(PICAMath.float24(x), PICAMath.float24(y), PICAMath.float24(z), PICAMath.float24(w))
        let target = registers.field(PICAReg.defaultAttributeIndex, 0, 4)
        if target < 0xF {
            defaultAttributes[target] = attribute
            registers[PICAReg.defaultAttributeIndex] += 1
            return
        }
        immediateVertex[immediateAttribute] = attribute
        guard immediateAttribute >= registers.field(0x242, 0, 4) else { immediateAttribute += 1; return }
        immediateAttribute = 0
        drawImmediateVertex()
    }

    private func drawImmediateVertex() {
        // The draw state is only decoded when this vertex completes a primitive.
        immediate.submit(immediateVertex) { a, b, c in
            let state = drawState()
            if metal != nil {
                let n = registers.field(PICAReg.inputConfig, 0, 4) + 1
                render(.mesh(mesh([a, b, c].flatMap { $0.prefix(n) }, indices: [0, 1, 2], previous: nil)), state)
                return
            }
            let layout = PICAVertexLayout(fixedAttributeCount: 16)
            let v = [a, b, c].map { shade([0], layout: layout, data: [], defaults: $0, uniforms: program.uniforms)[0] }
            var triangles: [PICATriangle] = []
            PICAClipper.clip(v[0], v[1], v[2], viewport: state.viewport, into: &triangles)
            render(.triangles(triangles), state)
        }
    }

    private func draw(indexed: Bool) {
        guard registers.field(PICAReg.useGeometryShader, 0, 2) != 2 else { skippedGeometryShaderDraws += 1; return }
        let count = Int(registers[PICAReg.vertexCount])
        guard count > 0, count <= 1 << 20 else { return }
        let state = drawState()
        var layout = PICAVertexLayout(registers)
        let first = indexed ? layout.indexOffset : Int(registers[PICAReg.vertexOffset])

        var ids: [Int]
        if indexed {
            let width = layout.indexIsShort ? 2 : 1
            var raw = [UInt8](repeating: 0, count: count * width)
            guard memory.copyOut(GPUState.virtualAddress(layout.base &+ UInt32(layout.indexOffset)), to: &raw, count: raw.count) else { return }
            ids = layout.indexIsShort ? (0..<count).map { Int(raw[$0 * 2]) | Int(raw[$0 * 2 + 1]) << 8 } : raw.map { Int($0) }
        } else {
            ids = Array(first..<first + count)
        }
        guard let data = layout.fetch(maxVertex: ids.max() ?? 0, memory: memory) else { return }

        // Indexed draws shade each distinct vertex once; `slots` is the triangle list over the shaded vertices.
        var unique = ids, slot: [Int32] = []
        if indexed {
            slot = [Int32](repeating: -1, count: (ids.max() ?? 0) + 1)
            unique = []
            for id in ids where slot[id] < 0 { slot[id] = Int32(unique.count); unique.append(id) }
        }
        var slots: [UInt32] = []
        slots.reserveCapacity(count)
        var assembler = PICAPrimitiveAssembler<UInt32>(topology: topology)
        for k in ids.indices { assembler.submit(UInt32(indexed ? Int(slot[ids[k]]) : k)) { slots += [$0, $1, $2] } }
        let previous = emitsMotionInputs && state.target.height == 400
            ? motion.previousUniforms(mesh: layout.meshIdentity, count: count, first: first, indexed: indexed, uniforms: program.uniforms) : nil

        let start = DispatchTime.now().uptimeNanoseconds
        if metal != nil {
            let attributes = inputs(unique, layout: layout, data: data)
            vertexNanoseconds += DispatchTime.now().uptimeNanoseconds - start
            render(.mesh(mesh(attributes, indices: slots, previous: previous)), state)
            return
        }
        var shaded = shade(unique, layout: layout, data: data, defaults: defaultAttributes, uniforms: program.uniforms)
        if let previous {
            let before = shade(unique, layout: layout, data: data, defaults: defaultAttributes, uniforms: previous)
            for i in shaded.indices where before[i].position.w > 0.00001 { shaded[i].previous = before[i].position }
        }
        vertexNanoseconds += DispatchTime.now().uptimeNanoseconds - start
        var triangles: [PICATriangle] = []
        for t in stride(from: 0, to: slots.count, by: 3) {
            PICAClipper.clip(shaded[Int(slots[t])], shaded[Int(slots[t + 1])], shaded[Int(slots[t + 2])], viewport: state.viewport, into: &triangles)
        }
        render(.triangles(triangles), state)
    }

    private func mesh(_ attributes: [SIMD4<Float>], indices: [UInt32], previous: [SIMD4<Float>]?) -> PICAMesh {
        PICAMesh(attributes: attributes, indices: indices, registers: registers, program: program, uniforms: program.uniforms, previous: previous)
    }

    // Raw shader inputs of `vertices` for the GPU: `inputCount` per vertex, before the input permutation.
    private func inputs(_ vertices: [Int], layout: PICAVertexLayout, data: [UInt8]) -> [SIMD4<Float>] {
        let n = registers.field(PICAReg.inputConfig, 0, 4) + 1
        var out = [SIMD4<Float>](repeating: .zero, count: vertices.count * n)
        var scratch = [SIMD4<Float>](repeating: .zero, count: 16)
        data.withUnsafeBytes { bytes in defaultAttributes.withUnsafeBufferPointer { defaults in
            scratch.withUnsafeMutableBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
                for (i, v) in vertices.enumerated() {
                    layout.load(vertex: v, data: bytes.baseAddress ?? UnsafeRawPointer(defaults.baseAddress!), length: bytes.count,
                                defaults: defaults.baseAddress!, output: s.baseAddress!)
                    for a in 0..<n { o[i * n + a] = s[a] }
                }
            }}
        }}
        return out
    }

    // Clip-space vertices shaded on the CPU (software backend).
    private func shade(_ vertices: [Int], layout: PICAVertexLayout, data: [UInt8], defaults: [SIMD4<Float>],
                       uniforms: [SIMD4<Float>]) -> [PICAClipVertex] {
        var out = [PICAClipVertex](repeating: PICAClipVertex(), count: vertices.count)
        vertices.withUnsafeBufferPointer { ids in data.withUnsafeBytes { bytes in defaults.withUnsafeBufferPointer { d in
            vertexProcessor.process(ids, layout: layout, data: bytes.baseAddress ?? UnsafeRawPointer(d.baseAddress!), length: bytes.count,
                                    defaults: d.baseAddress!, program: program, uniforms: uniforms, registers: registers, into: &out)
        }}}
        return out
    }

    private enum Primitives {
        case triangles([PICATriangle]), mesh(PICAMesh)
        var count: Int { switch self { case .triangles(let t): return t.count; case .mesh(let m): return m.indices.count / 3 } }
    }

    private func render(_ primitives: Primitives, _ state: PICADrawState) {
        guard primitives.count > 0 else { return }
        var state = state
        state.lighting.lut = UnsafePointer(lightingTables); state.fog.lut = UnsafePointer(fogTable)
        let target = state.target
        let color = target.colorAddress != 0 && target.width > 0
            ? surfaces.surface(address: target.colorAddress, width: target.width, height: target.height,
                               bytesPerPixel: target.bytesPerColorPixel, memory: memory) : nil
        let depth = target.depthAddress != 0 && target.width > 0
            ? surfaces.surface(address: target.depthAddress, width: target.width, height: target.height,
                               bytesPerPixel: target.bytesPerDepthPixel, memory: memory) : nil
        var decoded: [PICADecodedTexture?] = []
        for unit in state.textures {
            guard unit.enabled, unit.address != 0 else { decoded.append(nil); continue }
            let length = PICATextureFormat.byteCount(format: unit.format, width: unit.width, height: unit.height)
            if surfaces.isDirty(overlapping: unit.address, length: length) || metal?.hasUnsynced(unit.address, length: length) == true {
                renderToTextureCount += 1      // render to texture
                syncGuest()
                textures.invalidate()
            }
            decoded.append(textures.texture(unit, memory: memory))
        }
        switch primitives {
        case .triangles(let triangles):
            if emitsMotionInputs, state.target.height == 400 { motion.rasterize(triangles, state: state) }
            rasterizer.draw(triangles, state: state, color: color, depth: depth, textures: decoded)
        case .mesh(let mesh):
            metal?.draw(mesh, state: state, color: color, depth: depth, textures: decoded)
        }
        drawCount += 1
        let info = PICADrawInfo(state: state, triangleCount: primitives.count, color: color, depth: depth)
        lastDraw = info
        onDraw?(info)
    }
}
