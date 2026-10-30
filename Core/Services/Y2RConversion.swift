// input: a Y2R conversion configuration (formats, coefficients, CDMA buffers) and guest memory holding the YUV planes.
// output: RGB pixels written into the guest receive buffer.
// pos: the colour-space hardware behind y2r:u (follows Cytrus core/hw/y2r.cpp, bit-exact with the console).
import Foundation

// One CDMA channel: `size` payload bytes move in `unit`-byte pieces, `gap` bytes are skipped between pieces.
struct Y2RBuffer {
    var address: UInt32 = 0, size: UInt32 = 0, unit: Int = 0, gap: Int = 0
}

struct Y2RConfig {
    var inputFormat: UInt8 = 0     // 0/1 YUV422/420 8-bit planes, 2/3 the same with 16-bit samples, 4 interleaved YUYV
    var outputFormat: UInt8 = 0    // 0 RGBA8, 1 RGB8, 2 RGB5A1, 3 RGB565
    var rotation: UInt8 = 0        // clockwise quarter turns, applied to each 8-line strip
    var blockAlignment: UInt8 = 0  // 0 linear, 1 PICA 8x8 tiles
    var lineWidth: UInt16 = 0
    var lines: UInt16 = 0
    var coefficients = [Int16](repeating: 0, count: 8)
    var alpha: UInt16 = 0
    var srcY = Y2RBuffer(), srcU = Y2RBuffer(), srcV = Y2RBuffer(), srcYUYV = Y2RBuffer(), dst = Y2RBuffer()
}

enum Y2RConversion {
    private static let linear = Array(0..<64)
    private static let morton = [
        0, 1, 4, 5, 16, 17, 20, 21, 2, 3, 6, 7, 18, 19, 22, 23, 8, 9, 12, 13, 24, 25, 28, 29, 10, 11, 14, 15, 26, 27, 30, 31,
        32, 33, 36, 37, 48, 49, 52, 53, 34, 35, 38, 39, 50, 51, 54, 55, 40, 41, 44, 45, 56, 57, 60, 61, 42, 43, 46, 47, 58, 59, 62, 63,
    ]

    // The hardware works on one 8-line strip at a time: receive, decode, rotate, encode, send.
    static func run(_ config: Y2RConfig, memory: PagedMemory) throws {
        var cvt = config
        let width = Int(cvt.lineWidth), numTiles = width / 8, format = Int(cvt.inputFormat)
        let remap = cvt.blockAlignment == 0 ? linear : morton
        let c = cvt.coefficients.map(Int.init)
        var tiles = [[UInt32]](repeating: [UInt32](repeating: 0, count: 64), count: numTiles)
        var tmp = [UInt32](repeating: 0, count: 64)   // keeps its old contents between tiles, like the hardware buffer
        var strip = 0
        while strip < Int(cvt.lines) {
            let rowHeight = min(Int(cvt.lines) - strip, 8), rowData = rowHeight * width
            strip += 8
            var planeY: [UInt8], planeU: [UInt8] = [], planeV: [UInt8] = []
            if format == 4 {
                planeY = try receive(memory, rowData * 2, 1, &cvt.srcYUYV)
            } else {
                let n = format >= 2 ? 2 : 1, chroma = format % 2 == 0 ? 2 : 4
                planeY = try receive(memory, rowData, n, &cvt.srcY)
                planeU = try receive(memory, rowData / chroma, n, &cvt.srcU)
                planeV = try receive(memory, rowData / chroma, n, &cvt.srcV)
            }
            for y in 0..<rowHeight {
                for x in 0..<width {
                    let Y: Int, U: Int, V: Int
                    if format == 4 {
                        let i = (y * width + x / 2 * 2) * 2
                        Y = Int(planeY[(y * width + x) * 2]); U = Int(planeY[i + 1]); V = Int(planeY[i + 3])
                    } else {
                        let i = format % 2 == 0 ? (y * width + x) / 2 : (y / 2 * width + x) / 2
                        Y = Int(planeY[y * width + x]); U = Int(planeU[i]); V = Int(planeV[i])
                    }
                    let cY = c[0] * Y
                    let r = ((cY + c[1] * V) >> 3) + c[5] + 0x18
                    let g = ((cY - c[2] * V - c[3] * U) >> 3) + c[6] + 0x18
                    let b = ((cY + c[4] * U) >> 3) + c[7] + 0x18
                    tiles[x / 8][y * 8 + x % 8] = UInt32(clamp(r >> 5)) << 24 | UInt32(clamp(g >> 5)) << 16 | UInt32(clamp(b >> 5)) << 8
                }
            }
            var out = [UInt32](repeating: 0, count: numTiles * 64)
            var base = 0
            for i in 0..<numTiles {
                // 180 and 270 turns also reverse the tile order, since each tile is rotated on its own.
                let tile = tiles[cvt.rotation >= 2 ? numTiles - i - 1 : i]
                let order: [Int]
                switch cvt.rotation {
                case 0: order = Array(0..<rowHeight * 8)
                case 1: order = (0..<8).flatMap { x in (0..<rowHeight).reversed().map { $0 * 8 + x } }
                case 2: order = Array((0..<rowHeight * 8).reversed())
                default: order = (0..<8).reversed().flatMap { x in (0..<rowHeight).map { $0 * 8 + x } }
                }
                for (k, source) in order.enumerated() { tmp[remap[k]] = tile[source] }
                if cvt.blockAlignment == 0 {
                    let stripWidth = cvt.rotation % 2 == 0 ? width : 8
                    for y in 0..<rowHeight { for x in 0..<8 { out[base + y * stripWidth + x] = tmp[y * 8 + x] } }
                    base += cvt.rotation % 2 == 0 ? 8 : 8 * rowHeight
                } else {
                    for k in 0..<64 { out[base + k] = tmp[k] }
                    base += 64
                }
            }
            try send(memory, out, rowData, cvt.outputFormat, UInt8(truncatingIfNeeded: cvt.alpha), &cvt.dst)
        }
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }

    // Simulated incoming CDMA. 16-bit formats keep only the low byte of each sample.
    private static func receive(_ memory: PagedMemory, _ amount: Int, _ n: Int, _ buffer: inout Y2RBuffer) throws -> [UInt8] {
        var result: [UInt8] = []
        while result.count < amount {
            let input = try memory.readBytes(buffer.address, count: buffer.unit)
            result += stride(from: 0, to: input.count, by: n).map { input[$0] }
            buffer.address &+= UInt32(buffer.unit + buffer.gap)
            buffer.size &-= UInt32(buffer.unit)
        }
        return result
    }

    // Simulated outgoing CDMA, one transfer unit of encoded pixels at a time.
    private static func send(_ memory: PagedMemory, _ pixels: [UInt32], _ count: Int, _ format: UInt8, _ alpha: UInt8, _ buffer: inout Y2RBuffer) throws {
        var next = 0
        while next < count {
            var unit: [UInt8] = []
            while unit.count < buffer.unit {
                let color = pixels[next]
                next += 1
                let r = UInt8(truncatingIfNeeded: color >> 24), g = UInt8(truncatingIfNeeded: color >> 16), b = UInt8(truncatingIfNeeded: color >> 8)
                switch format {
                case 0: unit += [alpha, b, g, r]
                case 1: unit += [b, g, r]
                case 2:
                    let value = UInt16(r >> 3) << 11 | UInt16(g >> 3) << 6 | UInt16(b >> 3) << 1 | UInt16(alpha >> 7)
                    unit += [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
                default:
                    let value = UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
                    unit += [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
                }
            }
            try memory.writeBytes(buffer.address, unit)
            buffer.address &+= UInt32(buffer.unit + buffer.gap)
            buffer.size &-= UInt32(buffer.unit)
        }
    }
}
