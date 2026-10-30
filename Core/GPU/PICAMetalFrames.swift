// input: GX memory fills, display transfers and other guest writes, as physical addresses.
// output: GPU targets cleared or marked for re-upload, and the high-res LCD frame (color + depth) the app presents.
// pos: the Metal backend's side of the GSP command queue; PICARenderer forwards these calls.
import Foundation
import Metal

// A display transfer rendered at the internal resolution. `color` is .rgba8Unorm in LCD orientation, (screen width x 240)
// times `scale`, row 0 the top LCD row; `depth` is .r32Float of the same size (PICA depth 0...1). The GPU work is complete.
// Top screen only: `motion` (.rg16Float, previous minus current in pixels of this frame), `reactive` (.r8Unorm), `layer`,
// `jitter` (the sub-pixel shift of its geometry, in LCD pixels) and the depth direction, for MetalFX.
struct PICAHighResFrame {
    let color: MTLTexture
    let depth: MTLTexture?
    let scale: Int
    let sequence: Int
    var motion: MTLTexture?, reactive: MTLTexture?
    var layer: MTLTexture?   // UI drawn over the scene: premultiplied rgb, alpha = scene transmittance; shown after MetalFX
    var jitter = SIMD2<Float>.zero
    var depthReversed = false
}

extension PICAMetalBackend {
    // GX commands carry virtual addresses, PICA registers physical ones: compare both as virtual.
    private func overlapping(_ start: UInt32, _ length: Int) -> [Target] {
        let start = UInt64(GPUState.virtualAddress(start))
        return targets.filter {
            let address = UInt64(GPUState.virtualAddress($0.address))
            return address < start + UInt64(length) && start < address + UInt64($0.byteCount)
        }
    }

    // A memory fill: a target it covers whole is cleared on the GPU; one it touches in part is re-uploaded before its next draw.
    func fill(start: UInt32, end: UInt32, value: UInt32, width: UInt32) {
        let start = GPUState.virtualAddress(start), end = UInt64(start) + UInt64(end - start)
        for t in overlapping(start, Int(end) - Int(start)) {
            let address = GPUState.virtualAddress(t.address)
            guard start <= address, end >= UInt64(address) + UInt64(t.byteCount), !t.drawn else { t.stale = true; continue }
            let pass = MTLRenderPassDescriptor()
            if t.isDepth {
                let depth = t.format == 0 ? value & 0xFFFF : value & 0xFF_FFFF
                pass.depthAttachment.texture = t.texture; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = Double(depth) / 16_777_216
                pass.stencilAttachment.texture = t.texture; pass.stencilAttachment.loadAction = .clear; pass.stencilAttachment.storeAction = .store
                pass.stencilAttachment.clearStencil = t.format == 3 ? value >> 24 : 0
            } else {
                // Fill patterns are stored bytes; decode them the way the target reads them.
                var bytes = [UInt8](repeating: 0, count: 4)
                for i in 0..<4 { bytes[i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i % Int([2, 3, 4, 4][Int(width & 3)])))) }
                let c = bytes.withUnsafeBufferPointer { PICAColorFormat.read($0.baseAddress!, t.format) }
                pass.colorAttachments[0].texture = t.texture; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(c & 255) / 255, green: Double(c >> 8 & 255) / 255,
                                                                    blue: Double(c >> 16 & 255) / 255, alpha: Double(c >> 24) / 255)
            }
            endEncoder()
            clearMotion(t, in: pass)    // the game clears its frame: the motion planes start over with it
            t.stale = false
        }
    }

    // Guest bytes of a range changed outside the renderer (DMA, copies, transfers into a target).
    func guestWritten(_ start: UInt32, length: Int) { for t in overlapping(start, length) { t.stale = true } }

    // Renders the high-res LCD image of a display transfer whose source is a GPU color target. Returns nil otherwise.
    // `publish` runs on Metal's completion thread once the frame is rendered.
    // `shift` is the jitter the renderer applied to the source's geometry, in its native pixels.
    func lcdFrame(_ transfer: DisplayTransfer, sequence: Int, shift: SIMD2<Float>, depthReversed: Bool, publish: @escaping (PICAHighResFrame) -> Void) -> Bool {
        let scaling = (transfer.flags >> 24) & 3, scaleX = scaling >= 1 ? 2 : 1, scaleY = scaling == 2 ? 2 : 1
        let lcdWidth = transfer.outputHeight / scaleY
        guard lcdWidth == 400 || lcdWidth == 320, transfer.outputWidth / scaleX == 240, transfer.flags & 2 == 0,
              let source = targets.first(where: { !$0.isDepth && GPUState.virtualAddress($0.address) == GPUState.virtualAddress(transfer.input) && $0.width == transfer.inputWidth && $0.height == transfer.inputHeight })
        else { return false }
        let depth = targets.first { $0.isDepth && $0.width == source.width && $0.height == source.height && $0.lastPartner === source }
        let size = (lcdWidth * scale, 240 * scale)
        func make(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.0, height: size.1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let color = make(.rgba8Unorm), depthPlane = make(.r32Float)
        let motion = source.motion.map { _ in make(.rg16Float) }, reactive = source.motion.map { _ in make(.r8Unorm) }
        let layer = source.layer.map { _ in make(.rgba8Unorm) }
        endEncoder()
        let commandBuffer = makeCommandBuffer()
        guard let e = commandBuffer.makeComputeCommandEncoder() else { return false }
        e.setComputePipelineState(kernels.lcd)
        e.setTexture(source.texture, index: 0); e.setTexture(depth?.texture, index: 1)
        e.setTexture(color, index: 2); e.setTexture(depthPlane, index: 3)
        e.setTexture(source.motion, index: 4); e.setTexture(source.reactive, index: 5); e.setTexture(motion, index: 6); e.setTexture(reactive, index: 7)
        e.setTexture(source.layer, index: 8); e.setTexture(layer, index: 9)
        var info = (Int32(transfer.inputHeight), Int32(transfer.outputHeight / scaleY), Int32(scaleX), Int32(scaleY),
                    Int32(transfer.flags & 1), Int32(scale), Int32(lcdWidth), Int32(depth == nil ? 0 : 1),
                    Float(depth.map { $0.format == 0 ? 65535 : 16_777_215 } ?? 1), Int32(motion == nil ? 0 : 1))
        e.setBytes(&info, length: MemoryLayout.size(ofValue: info), index: 0)
        e.dispatchThreads(MTLSize(width: size.0, height: size.1, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e.endEncoding()
        if source.layerUsed { mergeLayer(source) }
        var frame = PICAHighResFrame(color: color, depth: depth == nil ? nil : depthPlane, scale: scale, sequence: sequence)
        if motion != nil {
            // The same target-to-LCD mapping lcdTransfer applies to pixels: LCD column runs against target y (with the flip), row against x.
            let flip: Float = transfer.flags & 1 != 0 ? 1 : -1
            (frame.motion, frame.reactive, frame.layer, frame.depthReversed) = (motion, reactive, layer, depthReversed)
            frame.jitter = SIMD2(flip * shift.y / Float(scaleY), -shift.x / Float(scaleX))
        }
        commandBuffer.addCompletedHandler { _ in publish(frame) }
        submit()
        return true
    }

    // Composites `target`'s UI layer into it and empties the layer: under a later 3D draw, at write-back, and once the LCD image
    // is taken (the guest's copy of the frame then shows its UI). The caller has ended the render encoder.
    func mergeLayer(_ target: Target) {
        guard let layer = target.layer else { return }
        target.layerUsed = false
        let commandBuffer = makeCommandBuffer(), merge = MTLRenderPassDescriptor()
        merge.colorAttachments[0].texture = target.texture; merge.colorAttachments[0].loadAction = .load; merge.colorAttachments[0].storeAction = .store
        if let e = commandBuffer.makeRenderCommandEncoder(descriptor: merge) {
            e.setRenderPipelineState(uploads.layer); e.setFragmentTexture(layer, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
        }
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = layer; clear.colorAttachments[0].loadAction = .clear; clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        commandBuffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
    }
}
