// Input: decoded landscape RGBA8 frame and an externally sized CAMetalLayer.
// Output: an asynchronously submitted frame to that layer.
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
        fragment float4 screenFragment(Varying in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler pixels(coord::normalized, address::clamp_to_edge, filter::nearest);
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
    }

    @discardableResult
    func present(_ frame: DecodedScreenFrame) -> Bool {
        let width = frame.screen.width
        guard frame.rgba.count == width * 240 * 4,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer() else { return false }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: 240, mipmapped: false)
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return false }
        frame.rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, 240), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        return true
    }
}
