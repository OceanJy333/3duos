// Input: TDS_BENCH=1 in the launch environment.
// Output: device log lines with the GPU time of the MetalFX stages at the game's sizes, each frame's work run alone.
// Pos: diagnostic started by RootController; separates scaler and interpolation cost from contention with the renderer.
import Metal

enum MetalFXBench {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["TDS_BENCH"] != nil else { return }
        DispatchQueue.global().async {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
            let (w, h, ow, oh) = (1200, 720, 1718, 1031)
            func texture(_ format: MTLPixelFormat) -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
                return device.makeTexture(descriptor: d)!
            }
            let inputs = (texture(.rgba8Unorm), texture(.r32Float), texture(.rg16Float), texture(.r8Unorm))
            for multiple in [1, 2, 4] {
                guard let pipeline = try? MetalFXScreenPipeline(device: device, width: w, height: h, outWidth: ow, outHeight: oh,
                                                                mode: .temporal, frameMultiple: multiple) else { continue }
                var times: [Double] = []
                for _ in 0..<40 {
                    let command = queue.makeCommandBuffer()!
                    pipeline.upload(color: inputs.0, depth: inputs.1, motion: inputs.2, reactive: inputs.3, commandBuffer: command)
                    pipeline.encode(commandBuffer: command)
                    command.commit(); command.waitUntilCompleted()
                    times.append((command.gpuEndTime - command.gpuStartTime) * 1000)
                }
                let sorted = times.suffix(30).sorted()
                NSLog("3duos bench: MetalFX temporal %dx %d×%d→%d×%d · median %.2f ms · p90 %.2f ms per source frame",
                      multiple, w, h, ow, oh, sorted[15], sorted[27])
            }
        }
    }
}
