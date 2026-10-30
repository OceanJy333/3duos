// Input: decoded LCD frames or GPU frames at the internal resolution, a MetalFX mode, and an externally sized CAMetalLayer.
// Output: frames submitted to that layer at its native pixel size: drawn as is, or MetalFX reconstructed and interpolated.
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
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState
    private var effects: MetalFXScreenPipeline?
    private var mode = MetalFXMode.off, wantsInterpolation = false
    private var shownSequence = -1, owesRealFrame = false

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

    func configureMetalFX(mode: MetalFXMode, interpolates: Bool) {
        self.mode = mode
        wantsInterpolation = interpolates
        effects = nil
    }

    var interpolates: Bool { effects?.interpolated != nil }
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
                                                mode: mode, interpolates: wantsInterpolation)
        } catch {
            NSLog("3duos MetalFX %@ unavailable: %@", mode.title, "\(error)")
            mode = .off
            effects = nil
        }
        return effects
    }

    // Shows the new source frame. With interpolation this is the frame halfway to the previous one;
    // call `presentUpscaled()` half a source interval later to show the frame itself.
    @discardableResult
    func present(_ frame: DecodedScreenFrame) -> Bool {
        let width = frame.screen.width
        guard frame.rgba.count == width * 240 * 4, let command = queue.makeCommandBuffer() else { return false }
        if let effects = effects(width: width, height: 240) {
            effects.jitter = frame.jitter
            frame.rgba.withUnsafeBytes { effects.upload(rgba: $0.baseAddress!, depth: frame.depth, motion: frame.motion) }
            effects.encode(commandBuffer: command)
            return draw(effects.interpolated ?? effects.output, fence: effects.fence, sampler: linear, command: command)
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

    // Called every display refresh with the latest GPU frame. A new game frame goes through MetalFX with the renderer's exact
    // jitter, depth, motion and reactive mask; with interpolation the next refresh, without a new frame, shows the real one.
    @discardableResult
    func present(_ frame: PICAHighResFrame) -> Bool {
        guard frame.sequence != shownSequence else {
            guard owesRealFrame else { return false }
            owesRealFrame = false
            return presentUpscaled()
        }
        shownSequence = frame.sequence
        guard let command = queue.makeCommandBuffer() else { return false }
        guard let effects = effects(width: frame.color.width, height: frame.color.height) else {
            return draw(frame.color, fence: nil, sampler: linear, command: command)
        }
        effects.jitter = frame.jitter * Float(frame.scale)
        effects.depthReversed = frame.depthReversed
        effects.upload(color: frame.color, depth: frame.depth, motion: frame.motion, reactive: frame.reactive, commandBuffer: command)
        effects.encode(commandBuffer: command)
        owesRealFrame = effects.interpolated != nil
        return draw(effects.interpolated ?? effects.output, fence: effects.fence, sampler: linear, command: command)
    }

    @discardableResult
    func presentUpscaled() -> Bool {
        guard let effects, let command = queue.makeCommandBuffer() else { return false }
        return draw(effects.output, fence: effects.fence, sampler: linear, command: command)
    }

    private func draw(_ texture: MTLTexture, fence: MTLFence?, sampler: MTLSamplerState,
                      command: MTLCommandBuffer) -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let fence { encoder.waitForFence(fence, before: .fragment) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        return true
    }
}
