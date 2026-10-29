// input: synthetic clip-space XY vertices from the PICA register bridge
// output: RGBA8 offscreen render target bytes
// pos: native Metal smoke-test renderer; not an emulation of PICA shaders or raster state

import Foundation
import Metal

enum PICASyntheticMetalError: Error {
    case noDevice, resourceCreation, commandFailed
}

enum PICASyntheticMetal {
    static func render(_ vertices: [PICAPosition], width: Int, height: Int) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PICASyntheticMetalError.noDevice }
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 vertexMain(uint id [[vertex_id]], const device packed_float2 *p [[buffer(0)]]) {
            return float4(p[id].x, p[id].y, 0, 1);
        }
        fragment float4 fragmentMain() { return float4(1, 0, 0, 1); }
        """, options: nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "vertexMain")
        pipeline.fragmentFunction = library.makeFunction(name: "fragmentMain")
        pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
        let state = try device.makeRenderPipelineState(descriptor: pipeline)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer() else {
            throw PICASyntheticMetalError.resourceCreation
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw PICASyntheticMetalError.resourceCreation }
        encoder.setRenderPipelineState(state)
        if !vertices.isEmpty {
            let data = vertices.flatMap { [$0.x, $0.y] }
            guard let buffer = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.size) else {
                throw PICASyntheticMetalError.resourceCreation
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? PICASyntheticMetalError.commandFailed }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }
}
