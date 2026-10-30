// input: display-transfer and texture-copy parameters from GX commands, and the guest memory they address.
// output: converted pixels written to the target buffer (8x8 Morton tiles in, tiled or linear out, optional 2x downscale).
// pos: GPU post-processing stage that turns PICA render targets into the LCD framebuffers.
import Foundation

struct DisplayTransfer {
    var input: UInt32
    var output: UInt32
    var inputWidth: Int, inputHeight: Int
    var outputWidth: Int, outputHeight: Int
    var flags: UInt32

    init(words: [UInt32]) {
        input = words[1]; output = words[2]
        inputWidth = Int(words[3] & 0xFFFF); inputHeight = Int(words[3] >> 16)
        outputWidth = Int(words[4] & 0xFFFF); outputHeight = Int(words[4] >> 16)
        flags = words[5]
    }

    private static func bytesPerPixel(_ format: UInt32) -> Int { [4, 3, 2, 2, 2][Int(min(format, 4))] }

    // Pixel order inside an 8x8 tile: x and y bits interleaved, x in the even positions.
    private static func mortonOffset(_ x: Int, _ y: Int, bytes: Int) -> Int {
        var index = 0
        for bit in 0..<3 { index |= ((x >> bit) & 1) << (2 * bit) | ((y >> bit) & 1) << (2 * bit + 1) }
        return ((x & ~7) * 8 + index) * bytes
    }

    // RGBA8 bytes hold A,B,G,R and RGB8 holds B,G,R in memory.
    private static func decode(_ p: UnsafePointer<UInt8>, format: UInt32) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        switch format {
        case 0: return (p[3], p[2], p[1], p[0])
        case 1: return (p[2], p[1], p[0], 255)
        default:
            let v = UInt16(p[0]) | UInt16(p[1]) << 8
            switch format {
            case 2: return (UInt8(truncatingIfNeeded: (v >> 11) << 3), UInt8(truncatingIfNeeded: ((v >> 5) & 63) << 2), UInt8(truncatingIfNeeded: (v & 31) << 3), 255)
            case 3: return (UInt8(truncatingIfNeeded: (v >> 11) << 3), UInt8(truncatingIfNeeded: ((v >> 6) & 31) << 3), UInt8(truncatingIfNeeded: ((v >> 1) & 31) << 3), v & 1 != 0 ? 255 : 0)
            default: return (UInt8(truncatingIfNeeded: (v >> 12) * 17), UInt8(truncatingIfNeeded: ((v >> 8) & 15) * 17), UInt8(truncatingIfNeeded: ((v >> 4) & 15) * 17), UInt8(truncatingIfNeeded: (v & 15) * 17))
            }
        }
    }

    private static func encode(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), format: UInt32, into p: UnsafeMutablePointer<UInt8>) {
        switch format {
        case 0: p[0] = c.a; p[1] = c.b; p[2] = c.g; p[3] = c.r
        case 1: p[0] = c.b; p[1] = c.g; p[2] = c.r
        default:
            let v: UInt16
            switch format {
            case 2: v = UInt16(c.r >> 3) << 11 | UInt16(c.g >> 2) << 5 | UInt16(c.b >> 3)
            case 3: v = UInt16(c.r >> 3) << 11 | UInt16(c.g >> 3) << 6 | UInt16(c.b >> 3) << 1 | (c.a >= 128 ? 1 : 0)
            default: v = UInt16(c.r >> 4) << 12 | UInt16(c.g >> 4) << 8 | UInt16(c.b >> 4) << 4 | UInt16(c.a >> 4)
            }
            p[0] = UInt8(v & 0xFF); p[1] = UInt8(v >> 8)
        }
    }

    nonisolated(unsafe) static var onRun: ((DisplayTransfer, [UInt8]) -> Void)?

    // Flags: bit 0 flip, bit 1 linear input (tiled output), bit 5 keep the layout, bits 24-25 box-filter downscale
    // (1: 2x1, 2: 2x2; the filtered pixels are the next ones in the source tile, as on hardware and in Citra).
    func run(memory: PagedMemory) {
        let inFormat = (flags >> 8) & 7, outFormat = (flags >> 12) & 7
        let inBytes = Self.bytesPerPixel(inFormat), outBytes = Self.bytesPerPixel(outFormat)
        let scaling = (flags >> 24) & 3, scaleX = scaling >= 1 ? 2 : 1, scaleY = scaling == 2 ? 2 : 1
        // With downscaling the output dimension register names the size before scaling.
        let outputWidth = outputWidth / scaleX, outputHeight = outputHeight / scaleY
        guard inputWidth > 0, outputWidth > 0, outputHeight > 0,
              let source = try? memory.readBytes(GPUState.virtualAddress(input), count: inputWidth * inputHeight * inBytes) else { return }
        let inputLinear = flags & 2 != 0, keepLayout = flags & 0x20 != 0, flip = flags & 1 != 0
        let sourceTiled = !inputLinear, targetTiled = inputLinear != keepLayout
        let samples = scaling == 0 ? 1 : scaling == 1 ? 2 : 4
        func offset(_ x: Int, _ y: Int, tiled: Bool, width: Int, bytes: Int) -> Int {
            tiled ? Self.mortonOffset(x, y, bytes: bytes) + (y & ~7) * width * bytes : (x + y * width) * bytes
        }
        var target = [UInt8](repeating: 0, count: outputWidth * outputHeight * outBytes)
        source.withUnsafeBufferPointer { src in
            target.withUnsafeMutableBufferPointer { dst in
                for y in 0..<outputHeight {
                    let row = flip ? outputHeight - 1 - y : y
                    let sy = y * scaleY
                    guard sy < inputHeight else { continue }
                    for x in 0..<outputWidth {
                        let sx = x * scaleX
                        guard sx < inputWidth else { continue }
                        let from = src.baseAddress! + offset(sx, sy, tiled: sourceTiled, width: inputWidth, bytes: inBytes)
                        var c = Self.decode(from, format: inFormat)
                        if samples > 1 {
                            var sum = (Int(c.r), Int(c.g), Int(c.b), Int(c.a))
                            for i in 1..<samples {
                                let n = Self.decode(from + i * inBytes, format: inFormat)
                                sum = (sum.0 + Int(n.r), sum.1 + Int(n.g), sum.2 + Int(n.b), sum.3 + Int(n.a))
                            }
                            c = (UInt8(sum.0 / samples), UInt8(sum.1 / samples), UInt8(sum.2 / samples), UInt8(sum.3 / samples))
                        }
                        let to = offset(x, row, tiled: targetTiled, width: outputWidth, bytes: outBytes)
                        Self.encode(c, format: outFormat, into: dst.baseAddress! + to)
                    }
                }
            }
        }
        try? memory.writeBytes(GPUState.virtualAddress(output), target)
        Self.onRun?(self, source)
    }
}

enum TextureCopy {
    // Sizes are in bytes, widths and gaps in 16-byte units; every line copies `width` bytes, then skips the gap.
    static func run(words: [UInt32], memory: PagedMemory) {
        var remaining = Int(words[3])
        let inWidth = Int(words[4] & 0xFFFF) * 16, inGap = Int(words[4] >> 16) * 16
        let outWidth = Int(words[5] & 0xFFFF) * 16, outGap = Int(words[5] >> 16) * 16
        var from = GPUState.virtualAddress(words[1]), to = GPUState.virtualAddress(words[2])
        guard inWidth > 0, outWidth > 0 else { return }
        while remaining > 0 {
            let count = min(inWidth, outWidth, remaining)
            if let bytes = try? memory.readBytes(from, count: count) { try? memory.writeBytes(to, bytes) }
            remaining -= count
            from += UInt32(count + (count == inWidth ? inGap : 0))
            to += UInt32(count + (count == outWidth ? outGap : 0))
        }
    }
}
