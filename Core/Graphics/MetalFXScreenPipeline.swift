// Input: frames of one 3DS screen in presentation order: CPU RGBA8 at LCD size (test scenes, software frames), or GPU frames
//        with exact depth, motion and reactive mask at the internal resolution.
// Output: a texture at the display's native size per frame and, when enabled, the interpolated frame halfway before it.
// Pos: MetalFX stage between the frame sources and MetalScreenPresenter; owns every scaler input texture.
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

// Temporal reconstructs from jittered history and exact motion; spatial filters one frame. MetalFX's denoised scaler is left
// out: it targets ray-tracing noise, which a rasterized 3DS frame does not have, and only adds blur and trails.
enum MetalFXMode: Int, CaseIterable {
    case off, spatial, temporal

    var title: String {
        switch self {
        case .off: return "Off"
        case .spatial: return "Spatial"
        case .temporal: return "Temporal"
        }
    }
}

enum MetalFXError: Error {
    case unsupported(String), invalidConfiguration, resourceFailed(String)
}

// Frames without renderer motion (CPU frames) get it from block matching between successive frames.
private let kernelSource = """
#include <metal_stdlib>
using namespace metal;
constant int radius = 8;
inline float luma(float4 c) { return dot(c.rgb, float3(0.299, 0.587, 0.114)); }
kernel void estimateMotion(texture2d<float, access::read> current [[texture(0)]],
                           texture2d<float, access::read> previous [[texture(1)]],
                           texture2d<float, access::write> motion [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(current.get_width(), current.get_height());
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    float patch[25];
    for (int i = 0; i < 25; i++) {
        patch[i] = luma(current.read(uint2(clamp(int2(gid) + int2(i % 5 - 2, i / 5 - 2), 0, size - 1))));
    }
    float best = 1e9;
    int2 vector = int2(0);
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            float cost = 0.002 * float(abs(dx) + abs(dy));
            for (int i = 0; i < 25; i++) {
                int2 at = clamp(int2(gid) + int2(i % 5 - 2, i / 5 - 2) + int2(dx, dy), 0, size - 1);
                cost += abs(patch[i] - luma(previous.read(uint2(at))));
            }
            if (cost < best) { best = cost; vector = int2(dx, dy); }
        }
    }
    motion.write(float4(float2(vector), 0, 0), gid);
}
"""

#if canImport(MetalFX)
final class MetalFXScreenPipeline {
    let mode: MetalFXMode
    let width: Int     // input size
    let height: Int
    let color: MTLTexture
    let output: MTLTexture
    // Frames between the previous output and `output`: [1/2] at 2x, none otherwise.
    let phases: [MTLTexture]
    // MetalFX updates this after writing `output` and `phases`; encoders that read them must wait on it.
    let fence: MTLFence?
    var jitter = SIMD2<Float>.zero     // sub-pixel offset the renderer applied, in input pixels
    var depthReversed = false          // nearer is larger (the game tests depth with greater)
    private let previous: MTLTexture?
    private let previousOutput: MTLTexture?
    private let motion: MTLTexture?
    private let depth: MTLTexture?
    private let reactive: MTLTexture?
    private let motionPipeline: MTLComputePipelineState
    private var encodeScaler: (MTLCommandBuffer, Bool) -> Void = { _, _ in }
    private var encodeInterpolator: ((MTLCommandBuffer, Bool) -> Void)?
    private var frameIndex = 0
    private var hasRealMotion = false

    // The renderer jitters only when this holds; unresolved jitter would show as shaking.
    static func supportsTemporal(_ device: MTLDevice) -> Bool { MTLFXTemporalScalerDescriptor.supportsDevice(device) }

    init(device: MTLDevice, width: Int, height: Int, outWidth: Int, outHeight: Int, mode: MetalFXMode,
         frameMultiple: Int = 1, framesPerSecond: Float = 30) throws {
        guard mode != .off, [1, 2].contains(frameMultiple), !(frameMultiple > 1 && mode == .spatial) else {
            throw MetalFXError.invalidConfiguration
        }
        let interpolates = frameMultiple > 1
        self.mode = mode
        self.width = width
        self.height = height
        let library = try device.makeLibrary(source: kernelSource, options: nil)
        guard let function = library.makeFunction(name: "estimateMotion") else { throw MetalFXError.resourceFailed("kernels") }
        motionPipeline = try device.makeComputePipelineState(function: function)

        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage,
                     _ storage: MTLStorageMode = .shared) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage.union(.shaderRead)
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d) else { throw MetalFXError.resourceFailed("\(format)") }
            return t
        }
        func fill<T>(_ t: MTLTexture, _ value: T) {
            let pixels = [T](repeating: value, count: t.width * t.height)
            pixels.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: t.width * MemoryLayout<T>.stride)
            }
        }

        if mode == .spatial {
            guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { throw MetalFXError.unsupported("Spatial") }
            let d = MTLFXSpatialScalerDescriptor()
            d.colorTextureFormat = .rgba8Unorm; d.outputTextureFormat = .rgba8Unorm
            d.inputWidth = width; d.inputHeight = height; d.outputWidth = outWidth; d.outputHeight = outHeight
            d.colorProcessingMode = .perceptual
            guard let scaler = d.makeSpatialScaler(device: device) else { throw MetalFXError.resourceFailed("Spatial") }
            color = try texture(.rgba8Unorm, width, height, scaler.colorTextureUsage)
            output = try texture(.rgba8Unorm, outWidth, outHeight, scaler.outputTextureUsage, .private)
            (motion, depth, reactive, previous, previousOutput, fence) = (nil, nil, nil, nil, nil, nil); phases = []
            let (colorTexture, outputTexture) = (color, output)
            encodeScaler = { commandBuffer, _ in
                scaler.colorTexture = colorTexture; scaler.outputTexture = outputTexture
                scaler.encode(commandBuffer: commandBuffer)
            }
            return
        }

        guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else { throw MetalFXError.unsupported("Temporal") }
        // The scaler and interpolator share internal resources, so MetalFX needs one fence to order them.
        let fence = interpolates ? device.makeFence() : nil
        self.fence = fence
        let d = MTLFXTemporalScalerDescriptor()
        d.colorTextureFormat = .rgba8Unorm; d.depthTextureFormat = .r32Float
        d.motionTextureFormat = .rg16Float; d.outputTextureFormat = .rgba8Unorm
        d.isReactiveMaskTextureEnabled = true; d.reactiveMaskTextureFormat = .r8Unorm
        d.inputWidth = width; d.inputHeight = height; d.outputWidth = outWidth; d.outputHeight = outHeight
        d.isAutoExposureEnabled = true
        guard let scaler = d.makeTemporalScaler(device: device) else { throw MetalFXError.resourceFailed("Temporal") }
        scaler.fence = fence
        color = try texture(.rgba8Unorm, width, height, scaler.colorTextureUsage)
        output = try texture(.rgba8Unorm, outWidth, outHeight, scaler.outputTextureUsage, .private)
        let motion = try texture(.rg16Float, width, height, scaler.motionTextureUsage.union(.shaderWrite))
        let depth = try texture(.r32Float, width, height, scaler.depthTextureUsage)
        let reactive = try texture(.r8Unorm, width, height, [])
        fill(depth, Float(0.5)); fill(reactive, UInt8(0))
        previous = try texture(.rgba8Unorm, width, height, [], .private)
        (self.motion, self.depth, self.reactive) = (motion, depth, reactive)

        if interpolates {
            // MetalFX only makes the frame halfway between two successive inputs, so a 30 fps game shows at 60.
            guard MTLFXFrameInterpolatorDescriptor.supportsDevice(device) else { throw MetalFXError.unsupported("Frame Interpolation") }
            func interpolator(linkedTo scaler: (any MTLFXFrameInterpolatableScaler)?) throws -> MTLFXFrameInterpolator {
                let f = MTLFXFrameInterpolatorDescriptor()
                f.scaler = scaler
                f.colorTextureFormat = .rgba8Unorm; f.depthTextureFormat = .r32Float
                f.motionTextureFormat = .rg16Float; f.outputTextureFormat = .rgba8Unorm
                f.inputWidth = width; f.inputHeight = height; f.outputWidth = outWidth; f.outputHeight = outHeight
                guard let made = f.makeFrameInterpolator(device: device) else { throw MetalFXError.resourceFailed("Frame Interpolation") }
                made.fence = fence
                return made
            }
            let half = try interpolator(linkedTo: scaler)
            let mid = try texture(.rgba8Unorm, outWidth, outHeight, half.outputTextureUsage, .private)
            let previousUpscaled = try texture(.rgba8Unorm, outWidth, outHeight, half.colorTextureUsage, .private)
            (phases, previousOutput) = ([mid], previousUpscaled)
            let current = output
            encodeInterpolator = { [unowned self] commandBuffer, reset in
                half.colorTexture = current; half.prevColorTexture = previousUpscaled
                half.depthTexture = depth; half.motionTexture = motion; half.outputTexture = mid
                half.motionVectorScaleX = 1; half.motionVectorScaleY = 1
                half.deltaTime = 1 / framesPerSecond
                half.nearPlane = 0.1; half.farPlane = 1
                half.fieldOfView = 1; half.aspectRatio = Float(width) / Float(height)
                half.isDepthReversed = depthReversed
                half.shouldResetHistory = reset
                half.encode(commandBuffer: commandBuffer)
            }
        } else {
            (phases, previousOutput) = ([], nil)
        }
        let (colorTexture, outputTexture) = (color, output)
        encodeScaler = { [unowned self] commandBuffer, reset in
            scaler.colorTexture = colorTexture; scaler.depthTexture = depth; scaler.motionTexture = motion
            scaler.reactiveMaskTexture = reactive; scaler.outputTexture = outputTexture
            scaler.inputContentWidth = width; scaler.inputContentHeight = height
            scaler.jitterOffsetX = jitter.x; scaler.jitterOffsetY = jitter.y
            scaler.motionVectorScaleX = 1; scaler.motionVectorScaleY = 1
            scaler.isDepthReversed = depthReversed
            scaler.reset = reset
            scaler.encode(commandBuffer: commandBuffer)
        }
    }

    // `depth` is per-pixel depth in 0...1, row-major like `rgba`; nil keeps the constant plane.
    // `motion` is previous minus current position per pixel in input pixels; nil falls back to block matching.
    func upload(rgba: UnsafeRawPointer, depth: [Float]? = nil, motion: [SIMD2<Float>]? = nil) {
        hasRealMotion = false
        if let motion, motion.count == width * height, let motionTexture = self.motion {
            let packed = motion.map { SIMD2<Float16>(Float16($0.x), Float16($0.y)) }
            packed.withUnsafeBytes { motionTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            hasRealMotion = true
        }
        color.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: rgba, bytesPerRow: width * 4)
        if let depth, depth.count == width * height, let depthTexture = self.depth {
            depth.withUnsafeBytes { depthTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        }
    }

    // GPU textures at the input size: motion (rg16Float, input pixels) and reactive mask (r8Unorm) come from the renderer
    // and are exact; without them the content is treated as static.
    func upload(color source: MTLTexture, depth sourceDepth: MTLTexture?, motion sourceMotion: MTLTexture?,
                reactive sourceReactive: MTLTexture?, commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: color)
        if let sourceDepth, let depth { blit.copy(from: sourceDepth, to: depth) }
        if let motion, let reactive {
            if let sourceMotion { blit.copy(from: sourceMotion, to: motion) } else { blit.fill(motion) }
            if let sourceReactive { blit.copy(from: sourceReactive, to: reactive) } else { blit.fill(reactive) }
        }
        blit.endEncoding()
        hasRealMotion = true
    }

    // Reads `color` and the stored previous frame, then stores `color` as the new previous frame.
    func encode(commandBuffer: MTLCommandBuffer) {
        if !hasRealMotion, let motion, let previous, let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(motionPipeline)
            encoder.setTexture(color, index: 0)
            encoder.setTexture(frameIndex == 0 ? color : previous, index: 1)
            encoder.setTexture(motion, index: 2)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        encodeScaler(commandBuffer, frameIndex == 0)
        encodeInterpolator?(commandBuffer, frameIndex == 0)
        if let previous, let blit = commandBuffer.makeBlitCommandEncoder() {
            if !hasRealMotion { blit.copy(from: color, to: previous) }   // only block matching reads it
            if let previousOutput { blit.copy(from: output, to: previousOutput) }
            blit.endEncoding()
        }
        frameIndex += 1
    }
}

private extension MTLBlitCommandEncoder {
    // Zeroes a shared texture (motion: none, reactive: history allowed).
    func fill(_ texture: MTLTexture) {
        let bytes = texture.pixelFormat == .rg16Float ? 4 : 1
        let buffer = device.makeBuffer(length: texture.width * texture.height * bytes, options: .storageModeShared)!
        copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: texture.width * bytes, sourceBytesPerImage: buffer.length,
             sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: texture, destinationSlice: 0,
             destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    }
}
#else
// The iOS Simulator SDK has no MetalFX: same interface, never available, so frames are drawn as rendered.
final class MetalFXScreenPipeline {
    let mode: MetalFXMode, width: Int, height: Int
    let color: MTLTexture, output: MTLTexture, phases: [MTLTexture] = [], fence: MTLFence? = nil
    var jitter = SIMD2<Float>.zero, depthReversed = false
    static func supportsTemporal(_ device: MTLDevice) -> Bool { false }
    init(device: MTLDevice, width: Int, height: Int, outWidth: Int, outHeight: Int, mode: MetalFXMode,
         frameMultiple: Int = 1, framesPerSecond: Float = 30) throws { throw MetalFXError.unsupported("MetalFX") }
    func upload(rgba: UnsafeRawPointer, depth: [Float]? = nil, motion: [SIMD2<Float>]? = nil) {}
    func upload(color: MTLTexture, depth: MTLTexture?, motion: MTLTexture?, reactive: MTLTexture?, commandBuffer: MTLCommandBuffer) {}
    func encode(commandBuffer: MTLCommandBuffer) {}
}
#endif
