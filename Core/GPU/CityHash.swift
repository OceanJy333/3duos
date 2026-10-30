// input: a byte buffer.
// output: its CityHash64 (Google CityHash v1.0.3, MIT license, as used by Citra/Azahar for texture names).
// pos: hash behind PICATexturePack, so packs made for Citra/Azahar match textures here.

enum CityHash {
    private static let k0: UInt64 = 0xc3a5_c85c_97cb_3127, k1: UInt64 = 0xb492_b66f_be98_f273, k2: UInt64 = 0x9ae1_6a3b_2f90_404f

    static func hash64(_ s: UnsafeRawBufferPointer) -> UInt64 {
        let len = s.count
        func fetch64(_ i: Int) -> UInt64 { s.loadUnaligned(fromByteOffset: i, as: UInt64.self) }
        func fetch32(_ i: Int) -> UInt64 { UInt64(s.loadUnaligned(fromByteOffset: i, as: UInt32.self)) }
        func rotate(_ v: UInt64, _ shift: UInt64) -> UInt64 { shift == 0 ? v : (v >> shift) | (v << (64 - shift)) }
        func shiftMix(_ v: UInt64) -> UInt64 { v ^ (v >> 47) }
        func hash16(_ u: UInt64, _ v: UInt64, _ mul: UInt64 = 0x9ddf_ea08_eb38_2d69) -> UInt64 {
            var a = (u ^ v) &* mul; a ^= a >> 47
            var b = (v ^ a) &* mul; b ^= b >> 47
            return b &* mul
        }
        func weak(_ i: Int, _ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) {
            let w = fetch64(i), x = fetch64(i + 8), y = fetch64(i + 16), z = fetch64(i + 24)
            var a = a &+ w
            var b = rotate(b &+ a &+ z, 21)
            let c = a
            a = a &+ x &+ y
            b = b &+ rotate(a, 44)
            return (a &+ z, b &+ c)
        }
        let n = UInt64(len)
        if len <= 16 {
            if len >= 8 {
                let mul = k2 &+ n &* 2, a = fetch64(0) &+ k2, b = fetch64(len - 8)
                return hash16(rotate(b, 37) &* mul &+ a, (rotate(a, 25) &+ b) &* mul, mul)
            }
            if len >= 4 { return hash16(n &+ (fetch32(0) << 3), fetch32(len - 4), k2 &+ n &* 2) }
            if len > 0 {
                let y = UInt32(s[0]) &+ (UInt32(s[len >> 1]) << 8), z = UInt32(len) &+ (UInt32(s[len - 1]) << 2)
                return shiftMix(UInt64(y) &* k2 ^ UInt64(z) &* k0) &* k2
            }
            return k2
        }
        if len <= 32 {
            let mul = k2 &+ n &* 2, a = fetch64(0) &* k1, b = fetch64(8), c = fetch64(len - 8) &* mul, d = fetch64(len - 16) &* k2
            return hash16(rotate(a &+ b, 43) &+ rotate(c, 30) &+ d, a &+ rotate(b &+ k2, 18) &+ c, mul)
        }
        if len <= 64 {
            let mul = k2 &+ n &* 2
            var a = fetch64(0) &* k2, b = fetch64(8)
            let c = fetch64(len - 24), d = fetch64(len - 32), e = fetch64(16) &* k2, f = fetch64(24) &* 9
            let g = fetch64(len - 8), h = fetch64(len - 16) &* mul
            let u = rotate(a &+ g, 43) &+ (rotate(b, 30) &+ c) &* 9, v = ((a &+ g) ^ d) &+ f &+ 1
            let w = ((u &+ v) &* mul).byteSwapped &+ h, x = rotate(e &+ f, 42) &+ c
            let y = (((v &+ w) &* mul).byteSwapped &+ g) &* mul, z = e &+ f &+ c
            a = ((x &+ z) &* mul &+ y).byteSwapped &+ b
            b = shiftMix((z &+ a) &* mul &+ d &+ h) &* mul
            return b &+ x
        }
        var x = fetch64(len - 40), y = fetch64(len - 16) &+ fetch64(len - 56)
        var z = hash16(fetch64(len - 48) &+ n, fetch64(len - 24))
        var v = weak(len - 64, n, z), w = weak(len - 32, y &+ k1, x)
        x = x &* k1 &+ fetch64(0)
        var at = 0, remaining = (len - 1) & ~63
        repeat {
            x = rotate(x &+ y &+ v.0 &+ fetch64(at + 8), 37) &* k1
            y = rotate(y &+ v.1 &+ fetch64(at + 48), 42) &* k1
            x ^= w.1
            y = y &+ v.0 &+ fetch64(at + 40)
            z = rotate(z &+ w.0, 33) &* k1
            v = weak(at, v.1 &* k1, x &+ w.0)
            w = weak(at + 32, z &+ w.1, y &+ fetch64(at + 16))
            swap(&z, &x)
            at += 64; remaining -= 64
        } while remaining != 0
        return hash16(hash16(v.0, w.0) &+ shiftMix(y) &* k1 &+ z, hash16(v.1, w.1) &+ x)
    }
}
