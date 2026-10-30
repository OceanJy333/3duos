// input: raw PICA register bit patterns, pixel coordinates and guest memory regions.
// output: decoded floats, Morton-order tile offsets, and bulk guest-memory copies.
// pos: numeric and memory helpers shared by the PICA shader, rasterizer and texture decoders.
import Foundation

enum PICAMath {
    // 1.7.16 float24 used by shader uniforms and viewport registers (exponent bias 63).
    @inline(__always) static func float24(_ raw: UInt32) -> Float {
        let sign = (raw >> 23) & 1, exponent = (raw >> 16) & 0x7F, mantissa = raw & 0xFFFF
        if exponent == 0 { return Float(bitPattern: sign << 31) }
        if exponent == 0x7F { return Float(bitPattern: sign << 31 | 0xFF << 23 | mantissa << 7) }
        return Float(bitPattern: sign << 31 | (exponent + 64) << 23 | mantissa << 7)
    }

    // Small PICA floats (f16 is 10 mantissa / 5 exponent bits, f20 is 12 / 7): sign above the exponent, IEEE-like bias.
    static func float(_ raw: UInt32, mantissa m: UInt32, exponent e: UInt32) -> Float {
        let sign = (raw >> (m + e)) & 1, exponent = (raw >> m) & ((1 << e) - 1), fraction = raw & ((1 << m) - 1)
        guard raw & ((1 << (m + e)) - 1) != 0 else { return Float(bitPattern: sign << 31) }
        let biased = exponent == (1 << e) - 1 ? 255 : exponent + 128 - (1 << (e - 1))
        return Float(bitPattern: sign << 31 | biased << 23 | fraction << (23 - m))
    }

    // Float to Int that never traps: NaN becomes 0 and huge values saturate at +-1,000,000.
    @inline(__always) static func integer(_ f: Float) -> Int {
        f > -1e6 ? (f < 1e6 ? Int(f) : 1_000_000) : (f.isNaN ? 0 : -1_000_000)
    }

    // Index of a pixel inside its 8x8 tile: x and y bits interleaved, x in the even positions.
    @inline(__always) static func morton(_ x: Int, _ y: Int) -> Int {
        (x & 1) | (y & 1) << 1 | (x & 2) << 1 | (y & 2) << 2 | (x & 4) << 2 | (y & 4) << 3
    }

    // Pixel index (not byte offset) of (x, y) in a width-wide image stored as 8x8 Morton tiles.
    @inline(__always) static func tiledIndex(_ x: Int, _ y: Int, width: Int) -> Int {
        (x & ~7) * 8 + morton(x, y) + (y & ~7) * width
    }
}

extension PagedMemory {
    // Copies `count` guest bytes into `destination`; false when any page is unmapped.
    func copyOut(_ address: UInt32, to destination: UnsafeMutableRawPointer, count: Int) -> Bool {
        transfer(address, count) { page, pageOffset, done, length in
            destination.advanced(by: done).copyMemory(from: page.bytes + pageOffset, byteCount: length)
        }
    }

    // True when `count` guest bytes equal `bytes`, compared in place; false also when a page is unmapped.
    func matches(_ address: UInt32, _ bytes: UnsafeRawPointer, count: Int) -> Bool {
        var same = true
        return transfer(address, count) { page, pageOffset, done, length in
            if same { same = memcmp(page.bytes + pageOffset, bytes + done, length) == 0 }
        } && same
    }

    func copyIn(_ address: UInt32, from source: UnsafeRawPointer, count: Int) -> Bool {
        transfer(address, count) { page, pageOffset, done, length in
            (page.bytes + pageOffset).update(from: source.advanced(by: done).assumingMemoryBound(to: UInt8.self), count: length)
        }
    }

    private func transfer(_ address: UInt32, _ count: Int, _ body: (MemoryPage, Int, Int, Int) -> Void) -> Bool {
        guard count > 0, UInt64(address) + UInt64(count) <= 1 << 32 else { return count == 0 }
        let first = Int(address >> 12), last = Int((UInt64(address) + UInt64(count) - 1) >> 12)
        guard (first...last).allSatisfy({ page($0) != nil }) else { return false }
        var done = 0, offset = Int(address & 0xFFF)
        for index in first...last {
            let length = min(4096 - offset, count - done)
            body(page(index)!, offset, done, length)
            done += length
            offset = 0
        }
        return true
    }
}
