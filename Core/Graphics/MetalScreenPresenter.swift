// Input: decoded LCD frames or GPU frames at the internal resolution, a MetalFX mode, and an externally sized CAMetalLayer.
// Output: frames submitted to that layer at its native pixel size: drawn as is, or MetalFX reconstructed and interpolated,
//         with the game's UI layer composited on top; counts of frames that reached the screen and MetalFX GPU time.
// Pos: Metal display endpoint, independent of the emulation and UI layers.
import Foundation
import Metal
import QuartzCore

enum MetalPresenterError: Error {
    case deviceUnavailable
    case queueUnavailable
    case shaderUnavailable
}

final class MetalScreenPresenter {
    private let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let layerPipeline: MTLRenderPipelineState   // UI layer over the scene: rgb = layer.rgb + scene * layer.a
    private var uiLayer: MTLTexture?                    // the shown game frame's UI layer
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState
    private var effects: MetalFXScreenPipeline?
    private var mode = MetalFXMode.off, wantsFrameMultiple = 1
    private var encodedSequence = -1, shownImage = -1
    private let statsLock = NSLock()
    private var stats = (shown: 0, gpuSeconds: 0.0, encodes: 0)

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalPresenterError.deviceUnavailable }
        guard let queue = device.makeCommandQueue() else { throw MetalPresenterError.queueUnavailable }
        self.layer = layer
        self.device = device
        self.queue = queue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Varying { float4 position [[position]]; float2 uv; };
        vertex Varying screenVertex(uint id [[vertex_id]]) {
            float2 positions[] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            float2 uvs[] = { float2(0,1), float2(2,1), float2(0,-1) };
            return { float4(positions[id], 0, 1), uvs[id] };
        }
        fragment float4 screenFragment(Varying in [[stage_in]], texture2d<float> image [[texture(0)]],
                                       sampler pixels [[sampler(0)]]) {
            return image.sample(pixels, in.uv);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "screenVertex"),
              let fragment = library.makeFunction(name: "screenFragment") else {
            throw MetalPresenterError.shaderUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true; blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .sourceAlpha
        blend.sourceAlphaBlendFactor = .zero; blend.destinationAlphaBlendFactor = .one
        layerPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let samplers = [MTLSamplerMinMagFilter.nearest, .linear].map { filter -> MTLSamplerState? in
            let sampler = MTLSamplerDescriptor()
            sampler.minFilter = filter
            sampler.magFilter = filter
            return device.makeSamplerState(descriptor: sampler)
        }
        guard let nearest = samplers[0], let linear = samplers[1] else { throw MetalPresenterError.shaderUnavailable }
        self.nearest = nearest
        self.linear = linear
    }

    func configureMetalFX(mode: MetalFXMode, frameMultiple: Int) {
        self.mode = mode
        wantsFrameMultiple = frameMultiple
        effects = nil
    }

    var frameMultiple: Int { (effects?.phases.count ?? 0) + 1 }

    // Frames that reached the screen and mean MetalFX GPU time per source frame since the last call.
    func takeStats() -> (shown: Int, gpuMilliseconds: Double) {
        statsLock.lock(); defer { statsLock.unlock() }
        let taken = (stats.shown, stats.encodes > 0 ? stats.gpuSeconds * 1000 / Double(stats.encodes) : 0)
        stats = (0, 0, 0)
        return taken
    }
    var scaling: String? { effects.map { "\($0.width)×\($0.height)→\($0.output.width)×\($0.output.height)" } }

    // MetalFX writes straight into the display's pixel grid: the drawable size fitted to the input aspect, at most 3x
    // (its limit) and never below the input (it does not downscale). Rebuilt when either size changes.
    private func effects(width: Int, height: Int) -> MetalFXScreenPipeline? {
        let drawable = layer.drawableSize
        let scale = max(1, min(3, drawable.width / CGFloat(width), drawable.height / CGFloat(height)))
        guard mode != .off, !(mode == .spatial && scale == 1) else { return nil }
        let out = (Int((CGFloat(width) * scale).rounded()), Int((CGFloat(height) * scale).rounded()))
        if let effects, effects.width == width, effects.height == height, effects.output.width == out.0, effects.output.height == out.1 { return effects }
        do {
            effects = try MetalFXScreenPipeline(device: device, width: width, height: height, outWidth: out.0, outHeight: out.1,
                                                mode: mode, frameMultiple: wantsFrameMultiple)
        } catch {
            NSLog("3duos MetalFX %@ unavailable: %@", mode.title, "\(error)")
            mode = .off
            effects = nil
        }
        return effects
    }

    // Encodes a new source frame and shows the first of its images; `presentEncoded(slot: 1, of: 2)` half a source interval
    // later shows the frame itself.
    @discardableResult
    func present(_ frame: DecodedScreenFrame) -> Bool {
        let width = frame.screen.width
        guard frame.rgba.count == width * 240 * 4, let command = queue.makeCommandBuffer() else { return false }
        uiLayer = nil
        if let effects = effects(width: width, height: 240) {
            effects.jitter = frame.jitter
            frame.rgba.withUnsafeBytes { effects.upload(rgba: $0.baseAddress!, depth: frame.depth, motion: frame.motion) }
            encode(effects, into: command)
            shownImage = -1
            return presentEncoded(slot: 0, of: 2)
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: 240, mipmapped: false)
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return false }
        frame.rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, 240), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
        }
        return draw(texture, fence: nil, sampler: nearest, command: command)
    }

    // Called every display refresh with the frame on screen and the refresh's place in its hold (`slot` of `slots`). A new
    // game frame goes through MetalFX once with the renderer's exact jitter, depth, motion and reactive mask; each refresh
    // then shows the interpolated image nearest its time, ending on the frame itself. Nothing is drawn when that image
    // is already on screen.
    @discardableResult
    func present(_ frame: PICAHighResFrame, slot: Int, of slots: Int) -> Bool {
        if frame.sequence != encodedSequence {
            encodedSequence = frame.sequence
            shownImage = -1
            uiLayer = frame.layer
            guard let effects = effects(width: frame.color.width, height: frame.color.height) else {
                guard let command = queue.makeCommandBuffer() else { return false }
                return draw(frame.color, fence: nil, sampler: linear, command: command)
            }
            guard let command = queue.makeCommandBuffer() else { return false }
            effects.jitter = frame.jitter * Float(frame.scale)
            effects.depthReversed = frame.depthReversed
            effects.upload(color: frame.color, depth: frame.depth, motion: frame.motion, reactive: frame.reactive, commandBuffer: command)
            encode(effects, into: command)
        }
        return presentEncoded(slot: slot, of: slots)
    }

    // Of the frame's images (interpolated ones, then the frame), shows the one whose time is the end of this slot.
    @discardableResult
    func presentEncoded(slot: Int, of slots: Int) -> Bool {
        guard let effects else { return false }
        let images = effects.phases + [effects.output]
        let index = ((slot + 1) * images.count + slots - 1) / slots - 1
        guard index != shownImage, let command = queue.makeCommandBuffer() else { return false }
        shownImage = index
        return draw(images[index], fence: effects.fence, sampler: linear, command: command)
    }

    private func encode(_ effects: MetalFXScreenPipeline, into command: MTLCommandBuffer) {
        command.label = "MetalFX"
        effects.encode(commandBuffer: command)
        command.addCompletedHandler { [weak self] done in
            guard let self else { return }
            statsLock.lock(); stats.gpuSeconds += done.gpuEndTime - done.gpuStartTime; stats.encodes += 1; statsLock.unlock()
        }
        command.commit()
    }

    private func draw(_ texture: MTLTexture, fence: MTLFence?, sampler: MTLSamplerState,
                      command: MTLCommandBuffer) -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Present"
        if let fence { encoder.waitForFence(fence, before: .fragment) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // Text and HUD skip MetalFX: drawn once, unjittered, over the upscaled or interpolated scene at the display's resolution.
        if let uiLayer {
            encoder.setRenderPipelineState(layerPipeline)
            encoder.setFragmentTexture(uiLayer, index: 0)
            encoder.setFragmentSamplerState(linear, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        #if targetEnvironment(simulator)   // its SDK has no presented handler: count submissions
        statsLock.lock(); stats.shown += 1; statsLock.unlock()
        #else
        drawable.addPresentedHandler { [weak self] shown in
            guard let self, shown.presentedTime > 0 else { return }
            statsLock.lock(); stats.shown += 1; statsLock.unlock()
        }
        #endif
        command.present(drawable)
        command.commit()
        return true
    }
}
