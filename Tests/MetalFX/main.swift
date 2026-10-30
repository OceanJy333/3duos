// Input: a synthetic panning scene rendered on the CPU, scale factor as optional argument.
// Output: PSNR of every MetalFX mode against the native high-resolution scene, and interpolation against its midpoint.
// Pos: standalone MetalFX pipeline check, independent of the app.
import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let width = 400, height = 240
let scale = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 2

// Pixel colour at sub-pixel time `t` (frames); `sample` positions the pixel centre in input pixels.
func scene(_ x: Double, _ y: Double, _ t: Double) -> [UInt8] {
    let u = x + 3 * t
    let checker = (Int(floor(u / 6)) + Int(floor(y / 6))) & 1 == 0
    var r = 0.25 + 0.5 * x / Double(width), g = 0.3 + 0.4 * y / Double(height), b = checker ? 0.85 : 0.2
    let dx = x - (120 + 5 * t), dy = y - 120
    if dx * dx + dy * dy < 40 * 40 { (r, g, b) = (0.95, 0.15, 0.1) }
    return [UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), 255]
}

// `shift` moves the geometry by that many input pixels, the way the PICA renderer jitters its viewport.
func render(scale s: Int, t: Double, shift: SIMD2<Double> = .zero) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: width * s * height * s * 4)
    for y in 0..<height * s {
        for x in 0..<width * s {
            let p = scene((Double(x) + 0.5) / Double(s) - 0.5 - shift.x, (Double(y) + 0.5) / Double(s) - 0.5 - shift.y, t)
            out.replaceSubrange((y * width * s + x) * 4..<(y * width * s + x) * 4 + 4, with: p)
        }
    }
    return out
}

func bilinear(_ low: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: width * scale * height * scale * 4)
    for y in 0..<height * scale {
        for x in 0..<width * scale {
            let fx = max(0, min(Double(width - 1), (Double(x) + 0.5) / Double(scale) - 0.5))
            let fy = max(0, min(Double(height - 1), (Double(y) + 0.5) / Double(scale) - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
            let ax = fx - Double(x0), ay = fy - Double(y0)
            for c in 0..<3 {
                let top = Double(low[(y0 * width + x0) * 4 + c]) * (1 - ax) + Double(low[(y0 * width + x1) * 4 + c]) * ax
                let bottom = Double(low[(y1 * width + x0) * 4 + c]) * (1 - ax) + Double(low[(y1 * width + x1) * 4 + c]) * ax
                out[(y * width * scale + x) * 4 + c] = UInt8(top * (1 - ay) + bottom * ay)
            }
        }
    }
    return out
}

func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var sum = 0.0
    for i in stride(from: 0, to: a.count, by: 4) {
        for c in 0..<3 { let d = Double(a[i + c]) - Double(b[i + c]); sum += d * d }
    }
    return 10 * log10(255 * 255 / max(sum / Double(a.count / 4 * 3), 1e-9))
}

func readback(_ texture: MTLTexture, waiting fence: MTLFence?) -> [UInt8] {
    let bytes = texture.width * texture.height * 4
    let buffer = device.makeBuffer(length: bytes, options: .storageModeShared)!
    let command = queue.makeCommandBuffer()!
    let blit = command.makeBlitCommandEncoder()!
    if let fence { blit.waitForFence(fence) }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
              to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 4,
              destinationBytesPerImage: bytes)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt8.self, capacity: bytes), count: bytes))
}

func run(_ mode: MetalFXMode, interpolate: Bool) throws -> Bool {
    let name = mode.title + (interpolate ? " + Frame Interpolation" : "")
    let pipeline: MetalFXScreenPipeline
    do {
        pipeline = try MetalFXScreenPipeline(device: device, width: width, height: height, outWidth: width * scale, outHeight: height * scale,
                                             mode: mode, interpolates: interpolate)
    } catch MetalFXError.unsupported(let what) {
        print("SKIP \(name): \(what) unsupported on \(device.name)")
        return true
    }
    let frames = 16
    var last: [UInt8] = [], mid: [UInt8] = []
    for n in 0..<frames {
        let low = render(scale: 1, t: Double(n))
        low.withUnsafeBytes { pipeline.upload(rgba: $0.baseAddress!) }
        let command = queue.makeCommandBuffer()!
        pipeline.encode(commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        precondition(command.status == .completed, "\(name): \(String(describing: command.error))")
        if n == frames - 1 {
            last = readback(pipeline.output, waiting: pipeline.fence)
            if let interpolated = pipeline.interpolated { mid = readback(interpolated, waiting: pipeline.fence) }
        }
    }
    let truth = render(scale: scale, t: Double(frames - 1))
    let baseline = bilinear(render(scale: 1, t: Double(frames - 1)))
    let score = psnr(last, truth), base = psnr(baseline, truth)
    print(String(format: "%@: frame PSNR %.2f dB (bilinear %.2f dB)", name, score, base))
    var ok = score > base - 3
    if interpolate {
        let midTruth = render(scale: scale, t: Double(frames) - 1.5)
        let blend = zip(bilinear(render(scale: 1, t: Double(frames) - 2)), baseline).map { UInt8((Int($0) + Int($1)) / 2) }
        let interpolatedScore = psnr(mid, midTruth), blendScore = psnr(blend, midTruth), copyScore = psnr(last, midTruth)
        print(String(format: "  midpoint PSNR %.2f dB (cross-fade %.2f dB, current frame %.2f dB)",
                     interpolatedScore, blendScore, copyScore))
        if let dir = ProcessInfo.processInfo.environment["DUMP_DIR"] {
            for (label, pixels) in [("mid", mid), ("last", last), ("truth", midTruth)] {
                var ppm = Data("P6\n\(width * scale) \(height * scale)\n255\n".utf8)
                for i in stride(from: 0, to: pixels.count, by: 4) { ppm.append(contentsOf: pixels[i..<i + 3]) }
                try ppm.write(to: URL(fileURLWithPath: "\(dir)/\(mode.title)-\(label).ppm"))
            }
        }
        ok = ok && interpolatedScore > copyScore && interpolatedScore > blendScore
    }
    return ok
}

// A static scene rendered with Halton jitter: MetalFX must be told the same offset the geometry moved by.
func jitterScore(sign: Float) throws -> Double {
    let pipeline = try MetalFXScreenPipeline(device: device, width: width, height: height, outWidth: width * scale,
                                             outHeight: height * scale, mode: .temporal, interpolates: false)
    func halton(_ i: Int, _ b: Int) -> Double { var f = 1.0, r = 0.0, i = i; while i > 0 { f /= Double(b); r += f * Double(i % b); i /= b }; return r }
    let zero = [SIMD2<Float>](repeating: .zero, count: width * height)
    for n in 0..<24 {
        let j = SIMD2(halton(n % 8 + 1, 2) - 0.5, halton(n % 8 + 1, 3) - 0.5)
        render(scale: 1, t: 0, shift: j).withUnsafeBytes { pipeline.upload(rgba: $0.baseAddress!, motion: zero) }
        pipeline.jitter = SIMD2<Float>(j) * sign
        let command = queue.makeCommandBuffer()!
        pipeline.encode(commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
    }
    return psnr(readback(pipeline.output, waiting: nil), render(scale: scale, t: 0))
}

var passed = true
for (mode, interpolate) in [(MetalFXMode.spatial, false), (.temporal, false), (.temporal, true)] {
    passed = try run(mode, interpolate: interpolate) && passed
}
let same = try jitterScore(sign: 1), opposite = try jitterScore(sign: -1)
print(String(format: "Jitter: offset = geometry shift %.2f dB, negated %.2f dB", same, opposite))
passed = passed && same > opposite
print(passed ? "PASS: MetalFX pipeline on \(device.name), scale \(scale)" : "FAIL")
exit(passed ? 0 : 1)
