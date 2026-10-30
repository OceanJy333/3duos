// input: decoded PICA textures (RGBA8 texels) and each draw unit's filter mode.
// output: Metal textures for the draw fragment function; with `filters` on, bilinear-sampled textures up to 512 texels are
//         pre-scaled 2x once by an anti-ringing Catmull-Rom kernel, so magnified texels stay sharp without halos.
//         A texture pack's replacement image, when there is one, is bound instead (any size; never filtered).
// pos: texture side of PICAMetalBackend. Nearest-sampled textures (text, UI, pixel art) are never filtered.
import Metal

final class PICAMetalTextures {
    private let device: MTLDevice, queue: MTLCommandQueue
    private let upscale: MTLComputePipelineState?
    private var cache: [ObjectIdentifier: (source: PICADecodedTexture, version: Int, texture: MTLTexture, filtered: MTLTexture?, replaced: Bool)] = [:]
    var filters = false
    var pack: PICATexturePack?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device; self.queue = queue
        upscale = (try? device.makeLibrary(source: Self.source, options: nil))?.makeFunction(name: "upscaleTexture")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
    }

    // The texture a unit samples; queued draws may still read an older one, so every change makes a new texture.
    func texture(_ t: PICADecodedTexture, linear: Bool) -> MTLTexture {
        let id = ObjectIdentifier(t)
        var entry = cache[id]
        if entry == nil || entry!.source !== t || entry!.version != t.version {
            let hash = pack.map { _ in t.contentHash }
            if let hash { pack?.dump(hash: hash, width: t.width, height: t.height, format: t.format, pixels: t.pixels) }
            let image = hash.flatMap { pack?.image($0) }
            let width = image?.width ?? t.width, height = image?.height ?? t.height
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: width, height: height, mipmapped: false)
            let texture = device.makeTexture(descriptor: d)!
            if let image { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: image.pixels, bytesPerRow: width * 4) }
            else { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: t.pixels, bytesPerRow: width * 4) }
            if cache.count > 512 { cache.removeAll() }
            entry = (t, t.version, texture, nil, image != nil)
        }
        guard filters, !entry!.replaced, linear, max(t.width, t.height) <= 512, let upscale else { cache[id] = entry; return entry!.texture }
        if entry!.filtered == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: t.width * 2, height: t.height * 2, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            let filtered = device.makeTexture(descriptor: d)!
            // Committed ahead of the draw batch on the same queue, so it runs first.
            let command = queue.makeCommandBuffer()!, e = command.makeComputeCommandEncoder()!
            e.setComputePipelineState(upscale)
            e.setTexture(entry!.texture, index: 0); e.setTexture(filtered, index: 1)
            e.dispatchThreads(MTLSize(width: t.width * 2, height: t.height * 2, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e.endEncoding(); command.commit()
            entry!.filtered = filtered
        }
        cache[id] = entry
        return entry!.filtered!
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // 2x Catmull-Rom; each output is clamped to its four nearest source texels, so edges get sharper without ringing.
    // Borders clamp to the edge: a texture may be sampled with any wrap mode.
    kernel void upscaleTexture(texture2d<uint, access::read> src [[texture(0)]], texture2d<uint, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int2 size = int2(src.get_width(), src.get_height());
        float2 s = (float2(gid) + 0.5) / 2 - 0.5, f = floor(s), t = s - f;
        float4 wx = float4(((-0.5 * t.x + 1) * t.x - 0.5) * t.x, (1.5 * t.x - 2.5) * t.x * t.x + 1, ((-1.5 * t.x + 2) * t.x + 0.5) * t.x, (0.5 * t.x - 0.5) * t.x * t.x);
        float4 wy = float4(((-0.5 * t.y + 1) * t.y - 0.5) * t.y, (1.5 * t.y - 2.5) * t.y * t.y + 1, ((-1.5 * t.y + 2) * t.y + 0.5) * t.y, (0.5 * t.y - 0.5) * t.y * t.y);
        float4 sum = 0, lo = 255, hi = 0;
        for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
            float4 c = float4(src.read(uint2(clamp(int2(f) + int2(i - 1, j - 1), int2(0), size - 1))));
            sum += c * wx[i] * wy[j];
            if ((i == 1 || i == 2) && (j == 1 || j == 2)) { lo = min(lo, c); hi = max(hi, c); }
        }
        dst.write(uint4(clamp(sum, lo, hi) + 0.5), gid);
    }
    """
}
