// input: meshes (raw attributes + indices + shader state) and decoded draw state from PICARenderer, guest-surface mirrors
//        and decoded textures.
// output: draws shaded and rendered on the GPU into render targets kept at `scale` x native resolution; native copies written back into
//         the mirrors on `finish` so guest memory stays correct.
// pos: the Metal PICAPixelBackend. Targets live on the GPU between command lists; PICAMetalFrames adds fills and LCD frames.
import Foundation
import Metal

final class PICAMetalBackend: PICAPixelBackend {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let scale: Int
    private let library: MTLLibrary
    private let vertexFunction: MTLFunction
    private var pipelines: [PICAMetalState.PipelineKey: MTLRenderPipelineState] = [:]
    private var depthStates: [PICAMetalState.DepthKey: MTLDepthStencilState] = [:]
    let kernels: (color: MTLComputePipelineState, depth: MTLComputePipelineState, lcd: MTLComputePipelineState)
    let uploads: (color: MTLRenderPipelineState, depth: MTLRenderPipelineState)
    private let dummyTexture: MTLTexture

    // A render target on the GPU, keyed by guest address, size and format.
    final class Target {
        let address: UInt32, width: Int, height: Int, format: Int, isDepth: Bool
        let texture: MTLTexture
        let stencil: MTLTexture?
        var mirror: PICASurface?
        var stale = true            // guest bytes changed behind the GPU's back: upload from the mirror before drawing
        var drawn = false           // queued draws write it
        var gpuNewer = false        // the GPU copy is newer than the mirror; written back only when the guest needs it
        var unsynced = false        // submitted write-back not yet copied into the mirror
        let staging: MTLBuffer      // native write-back, shared with the CPU
        weak var lastPartner: Target?   // the color target a depth target was last drawn with
        var motion: MTLTexture?, reactive: MTLTexture?   // top-screen MetalFX inputs, same size as `texture`
        init(_ s: PICASurface, format: Int, isDepth: Bool, texture: MTLTexture) {
            address = s.address; width = s.width; height = s.height; self.format = format; self.isDepth = isDepth
            self.texture = texture
            staging = texture.device.makeBuffer(length: s.width * ((s.height + 7) & ~7) * s.bytesPerPixel, options: .storageModeShared)!
            stencil = isDepth ? texture.makeTextureView(pixelFormat: .x32_stencil8) : nil
        }
        var byteCount: Int { width * ((height + 7) & ~7) * (isDepth ? [2, 2, 3, 4][format & 3] : [4, 3, 2, 2, 2][min(format, 4)]) }
    }
    private(set) var targets: [Target] = []
    var tracksMotion = false   // top-screen color targets (400 rows) get MetalFX motion and reactive attachments

    var commandBuffer: MTLCommandBuffer?
    private var encoder: MTLRenderCommandEncoder?
    private var encoderTargets: (Target?, Target?)
    // Vertex/table arenas in rotation, so a new batch can be written while earlier ones are still on the GPU.
    private var arenas: [(buffer: MTLBuffer, user: MTLCommandBuffer?)]
    private var arenaIndex = 0
    private var arena: MTLBuffer {
        if let user = arenas[arenaIndex].user { user.waitUntilCompleted(); arenas[arenaIndex].user = nil }
        return arenas[arenaIndex].buffer
    }
    private var arenaOffset = 0
    private var lutOffset = -1, fogOffset = -1, programOffset = -1, programVersion = -1
    private var textureCache: [ObjectIdentifier: (source: PICADecodedTexture, version: Int, texture: MTLTexture)] = [:]
    private(set) var waitNanoseconds: UInt64 = 0   // time the emulation thread waited for the GPU
    // GPU execution time of completed command buffers (written on Metal's completion thread).
    final class Statistics {
        private let lock = NSLock()
        private var seconds = 0.0, count = 0
        func add(_ s: Double) { lock.lock(); seconds += max(0, s); count += 1; lock.unlock() }
        var snapshot: (nanoseconds: UInt64, submissions: Int) { lock.lock(); defer { lock.unlock() }; return (UInt64(seconds * 1e9), count) }
    }
    let statistics = Statistics()

    init?(scale: Int, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: PICAMetalShaders.draw + PICAMetalShaders.kernels, options: nil),
              let arena = device.makeBuffer(length: 8 << 20, options: .storageModeShared) else { return nil }
        let options = MTLCompileOptions(); options.mathMode = .safe
        guard let vertex = (try? device.makeLibrary(source: PICAMetalVertex.source, options: options))?.makeFunction(name: "shadeVertex") else { return nil }
        self.device = device; self.queue = queue; self.library = library; self.vertexFunction = vertex; self.scale = max(1, min(4, scale))
        arenas = [(arena, nil)] + (0..<2).map { _ in (device.makeBuffer(length: 8 << 20, options: .storageModeShared)!, nil) }
        func compute(_ name: String) -> MTLComputePipelineState? { try? device.makeComputePipelineState(function: library.makeFunction(name: name)!) }
        func upload(_ fragment: String, depth: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "uploadVertex"); d.fragmentFunction = library.makeFunction(name: fragment)
            if depth { d.depthAttachmentPixelFormat = .depth32Float_stencil8; d.stencilAttachmentPixelFormat = .depth32Float_stencil8 }
            else { d.colorAttachments[0].pixelFormat = .rgba8Unorm }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let c = compute("writeBackColor"), let z = compute("writeBackDepth"), let l = compute("lcdTransfer"),
              let uc = upload("uploadColor", depth: false), let uz = upload("uploadDepth", depth: true) else { return nil }
        kernels = (c, z, l); uploads = (uc, uz)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: 1, height: 1, mipmapped: false)
        dummyTexture = device.makeTexture(descriptor: d)!
    }

    func makeCommandBuffer() -> MTLCommandBuffer {
        if let commandBuffer { return commandBuffer }
        let b = queue.makeCommandBuffer()!
        commandBuffer = b
        return b
    }

    func target(_ s: PICASurface, format: Int, isDepth: Bool) -> Target {
        if let t = targets.first(where: { $0.address == s.address && $0.width == s.width && $0.height == s.height && $0.format == format && $0.isDepth == isDepth }) {
            t.mirror = s
            return t
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: isDepth ? .depth32Float_stencil8 : .rgba8Unorm,
                                                         width: s.width * scale, height: s.height * scale, mipmapped: false)
        d.usage = isDepth ? [.renderTarget, .shaderRead, .pixelFormatView] : [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = Target(s, format: format, isDepth: isDepth, texture: device.makeTexture(descriptor: d)!)
        t.mirror = s
        if targets.count >= 16 {
            if targets[0].gpuNewer || targets[0].unsynced { finish() }   // its results must reach the mirror first
            targets.removeFirst()
        }
        targets.append(t)
        return t
    }

    func draw(_ mesh: PICAMesh, state: PICADrawState, color: PICASurface?, depth: PICASurface?, textures: [PICADecodedTexture?]) {
        guard !mesh.indices.isEmpty, state.target.width > 0, state.target.height > 0, color != nil || depth != nil else { return }
        let colorTarget = color.map { target($0, format: state.target.colorFormat, isDepth: false) }
        let depthTarget = depth.map { target($0, format: state.target.depthFormat, isDepth: true) }
        for t in [colorTarget, depthTarget] { if let t, t.stale { endEncoder(); upload(t) } }
        if tracksMotion, let c = colorTarget, c.height == 400, c.motion == nil { endEncoder(); addMotion(c) }
        let vertexBytes = mesh.attributes.count * 16, indexBytes = mesh.indices.count * 4, programBytes = PICAShaderProgram.size * 8
        // Worst case incl. program and both tables (alignment padding included); a full arena starts the next one, which re-copies them.
        let needed = ((vertexBytes + 255) & ~255) + ((indexBytes + 255) & ~255) + programBytes + 24 * 256 * 4 + 512
        if arenaOffset + needed > arena.length { submit() }
        if needed > arena.length { arenas[arenaIndex].buffer = device.makeBuffer(length: needed, options: .storageModeShared)! }
        let tables = state.lighting.enabled && lutOffset < 0 ? 24 * 256 * 4 : 0, fogTable = state.fog.enabled && fogOffset < 0 ? 512 : 0
        if encoder == nil || encoderTargets.0 !== colorTarget || encoderTargets.1 !== depthTarget { beginEncoder(colorTarget, depthTarget) }
        guard let encoder else { return }
        for t in [colorTarget, depthTarget] { t?.drawn = true; t?.gpuNewer = true }
        depthTarget?.lastPartner = colorTarget

        if tables > 0, let lut = state.lighting.lut { lutOffset = copy(lut, count: 24 * 256) }
        if fogTable > 0, let fog = state.fog.lut { fogOffset = copy(fog, count: 128) }
        if programOffset < 0 || programVersion != mesh.program.version {
            programVersion = mesh.program.version
            programOffset = mesh.program.code.withUnsafeBufferPointer { copy($0.baseAddress!, count: PICAShaderProgram.size) }
            _ = mesh.program.swizzles.withUnsafeBufferPointer { copy($0.baseAddress!, count: PICAShaderProgram.size) }
        }
        let vertexOffset = arenaOffset
        mesh.attributes.withUnsafeBytes { (arena.contents() + vertexOffset).copyMemory(from: $0.baseAddress!, byteCount: vertexBytes) }
        arenaOffset += (vertexBytes + 255) & ~255
        let indexOffset = arenaOffset
        mesh.indices.withUnsafeBytes { (arena.contents() + indexOffset).copyMemory(from: $0.baseAddress!, byteCount: indexBytes) }
        arenaOffset += (indexBytes + 255) & ~255
        encoder.setVertexBuffer(arena, offset: vertexOffset, index: 0)
        encoder.setVertexBuffer(arena, offset: programOffset, index: 2)
        let shader = PICAMetalVertex.block(mesh, viewport: state.viewport, width: state.target.width, height: state.target.height)
        shader.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }

        let key = PICAMetalState.pipelineKey(state, hasColor: colorTarget != nil, hasDepth: depthTarget != nil, motion: colorTarget?.motion != nil)
        encoder.setRenderPipelineState(pipeline(key))
        encoder.setDepthStencilState(depthState(PICAMetalState.depthKey(state)))
        encoder.setStencilReferenceValue(UInt32(state.merger.stencilRef))
        let b = state.merger.blendColor
        encoder.setBlendColor(red: Float(b.x) / 255, green: Float(b.y) / 255, blue: Float(b.z) / 255, alpha: Float(b.w) / 255)
        var scissor = MTLScissorRect(x: 0, y: 0, width: state.target.width * scale, height: state.target.height * scale)
        if state.viewport.scissorMode == 3 {
            let s = state.viewport.scissor
            let x0 = min(max(s[0], 0), state.target.width), y0 = min(max(s[1], 0), state.target.height)
            let x1 = min(max(s[2] + 1, x0), state.target.width), y1 = min(max(s[3] + 1, y0), state.target.height)
            scissor = MTLScissorRect(x: x0 * scale, y: y0 * scale, width: (x1 - x0) * scale, height: (y1 - y0) * scale)
            if scissor.width == 0 || scissor.height == 0 { return }
        }
        encoder.setScissorRect(scissor)
        let uniforms = PICAMetalState.uniforms(state, textures: textures, scale: scale)
        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setFragmentBuffer(arena, offset: max(lutOffset, 0), index: 2)
        encoder.setFragmentBuffer(arena, offset: max(fogOffset, 0), index: 3)
        let v = state.viewport, m = state.merger
        var motionInfo = (SIMD4(v.halfWidth, v.halfHeight, v.cornerX, v.cornerY), Int32(m.blendEnabled ? 1 : 0), Int32(m.sourceRGB == 6 ? 1 : 0))
        encoder.setFragmentBytes(&motionInfo, length: MemoryLayout.size(ofValue: motionInfo), index: 4)
        for unit in 0..<3 { encoder.setFragmentTexture(textures[unit].map(texture) ?? dummyTexture, index: unit) }
        // cullMode 1 keeps clockwise triangles of the y-down target, 2 counter-clockwise ones.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(state.viewport.cullMode == 1 ? .back : state.viewport.cullMode == 2 ? .front : .none)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count, indexType: .uint32, indexBuffer: arena, indexBufferOffset: indexOffset)
    }

    // The lighting and fog tables are about to change: the next draw that needs them copies them again.
    func tablesWillChange() { lutOffset = -1; fogOffset = -1 }

    private func copy(_ table: UnsafePointer<UInt32>, count: Int) -> Int {
        let at = arenaOffset
        (arena.contents() + at).copyMemory(from: table, byteCount: count * 4)
        arenaOffset += (count * 4 + 255) & ~255
        return at
    }

    private func beginEncoder(_ color: Target?, _ depth: Target?) {
        endEncoder()
        let pass = MTLRenderPassDescriptor()
        for (i, texture) in [color?.texture, color?.motion, color?.reactive].enumerated() {
            guard let texture else { continue }
            pass.colorAttachments[i].texture = texture; pass.colorAttachments[i].loadAction = .load; pass.colorAttachments[i].storeAction = .store
        }
        if let depth {
            pass.depthAttachment.texture = depth.texture; pass.depthAttachment.loadAction = .load; pass.depthAttachment.storeAction = .store
            pass.stencilAttachment.texture = depth.texture; pass.stencilAttachment.loadAction = .load; pass.stencilAttachment.storeAction = .store
        }
        encoder = makeCommandBuffer().makeRenderCommandEncoder(descriptor: pass)
        encoderTargets = (color, depth)
    }

    func endEncoder() { encoder?.endEncoding(); encoder = nil; encoderTargets = (nil, nil) }

    // Motion and reactive planes for a top-screen target, cleared: no motion, history trusted.
    private func addMotion(_ t: Target) {
        func make(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: t.texture.width, height: t.texture.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        t.motion = make(.rg16Float); t.reactive = make(.r8Unorm)
        clearMotion(t, in: MTLRenderPassDescriptor())
    }

    // Adds clears of `t`'s motion planes to `pass` (attachments 1 and 2) and runs it.
    func clearMotion(_ t: Target, in pass: MTLRenderPassDescriptor) {
        for (i, texture) in [t.motion, t.reactive].enumerated() {
            guard let texture else { continue }
            pass.colorAttachments[i + 1].texture = texture; pass.colorAttachments[i + 1].loadAction = .clear
            pass.colorAttachments[i + 1].clearColor = MTLClearColor(); pass.colorAttachments[i + 1].storeAction = .store
        }
        makeCommandBuffer().makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    // Copies the guest bytes of a target into its GPU texture (nearest upscale).
    private func upload(_ t: Target) {
        guard let mirror = t.mirror,
              let source = device.makeBuffer(bytes: mirror.bytes, length: t.byteCount, options: .storageModeShared) else { return }
        let pass = MTLRenderPassDescriptor()
        if t.isDepth {
            pass.depthAttachment.texture = t.texture; pass.depthAttachment.storeAction = .store
            pass.stencilAttachment.texture = t.texture; pass.stencilAttachment.storeAction = .store
        } else {
            pass.colorAttachments[0].texture = t.texture; pass.colorAttachments[0].storeAction = .store
        }
        let e = makeCommandBuffer().makeRenderCommandEncoder(descriptor: pass)!
        e.setRenderPipelineState(t.isDepth ? uploads.depth : uploads.color)
        if t.isDepth {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .always; d.isDepthWriteEnabled = true
            let s = MTLStencilDescriptor(); s.depthStencilPassOperation = .replace; d.frontFaceStencil = s; d.backFaceStencil = s
            e.setDepthStencilState(device.makeDepthStencilState(descriptor: d))
        }
        var info = SIMD4<Int32>(Int32(t.width), Int32(t.height), Int32(t.format), Int32(scale))
        e.setFragmentBuffer(source, offset: 0, index: 0)
        e.setFragmentBytes(&info, length: 16, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        t.stale = false
    }

    // Commits the queued GPU work without waiting for it. Native write-back copies are added only for `finish`: the game
    // rarely reads its render targets back, and the displayed frame comes straight from the GPU targets.
    func submit() { commit(writeBack: false) }

    private func commit(writeBack: Bool) {
        guard let commandBuffer else { return }
        endEncoder()
        for t in targets { t.drawn = false }
        if writeBack, targets.contains(where: { $0.gpuNewer }), let compute = commandBuffer.makeComputeCommandEncoder() {
            for t in targets where t.gpuNewer {
                compute.setComputePipelineState(t.isDepth ? kernels.depth : kernels.color)
                compute.setTexture(t.texture, index: 0)
                if let stencil = t.stencil { compute.setTexture(stencil, index: 1) }
                compute.setBuffer(t.staging, offset: 0, index: 0)
                var info = SIMD4<Int32>(Int32(t.width), Int32(t.height), Int32(t.format), Int32(scale))
                compute.setBytes(&info, length: 16, index: 1)
                compute.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                t.gpuNewer = false; t.unsynced = true
            }
            compute.endEncoding()
        }
        commandBuffer.addCompletedHandler { [statistics] b in statistics.add(b.gpuEndTime - b.gpuStartTime) }
        commandBuffer.commit()
        arenas[arenaIndex].user = commandBuffer
        self.commandBuffer = nil
        arenaIndex = (arenaIndex + 1) % arenas.count
        arenaOffset = 0; lutOffset = -1; fogOffset = -1; programOffset = -1
    }

    // Targets whose GPU results have not reached their mirrors yet overlap this guest range.
    func hasUnsynced(_ start: UInt32, length: Int) -> Bool {
        targets.contains { ($0.unsynced || $0.gpuNewer) && UInt64($0.address) < UInt64(start) + UInt64(length) && UInt64(start) < UInt64($0.address) + UInt64($0.byteCount) }
    }

    // Submits, waits for the GPU and copies every write-back into its mirror (marked dirty, so the renderer writes it to guest memory).
    func finish() {
        if commandBuffer == nil, targets.contains(where: { $0.gpuNewer }) { _ = makeCommandBuffer() }
        commit(writeBack: true)
        let waitStart = DispatchTime.now().uptimeNanoseconds
        for i in arenas.indices { arenas[i].user?.waitUntilCompleted(); arenas[i].user = nil }
        waitNanoseconds += DispatchTime.now().uptimeNanoseconds - waitStart
        for t in targets where t.unsynced {
            if let mirror = t.mirror {
                mirror.bytes.update(from: t.staging.contents().assumingMemoryBound(to: UInt8.self), count: t.byteCount)
                mirror.markDirty()
            }
            t.unsynced = false
        }
    }

    private func pipeline(_ key: PICAMetalState.PipelineKey) -> MTLRenderPipelineState {
        if let p = pipelines[key] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertexFunction; d.fragmentFunction = library.makeFunction(name: "drawFragment")
        PICAMetalState.describe(key, into: d)
        let p = try! device.makeRenderPipelineState(descriptor: d)
        pipelines[key] = p
        return p
    }

    private func depthState(_ key: PICAMetalState.DepthKey) -> MTLDepthStencilState {
        if let s = depthStates[key] { return s }
        let s = device.makeDepthStencilState(descriptor: PICAMetalState.describe(key))!
        depthStates[key] = s
        return s
    }

    private func texture(_ t: PICADecodedTexture) -> MTLTexture {
        let id = ObjectIdentifier(t)
        if let entry = textureCache[id], entry.source === t, entry.version == t.version { return entry.texture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: t.width, height: t.height, mipmapped: false)
        let texture = device.makeTexture(descriptor: d)!      // a new texture: queued GPU work may still read the old one
        texture.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, withBytes: t.pixels, bytesPerRow: t.width * 4)
        if textureCache.count > 512 { textureCache.removeAll() }
        textureCache[id] = (t, t.version, texture)
        return texture
    }
}
