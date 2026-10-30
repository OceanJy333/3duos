// input: guest texture bytes in the PICA 8x8 Morton-tiled layout, size and format.
// output: linear RGBA8 pixels (r in the low byte) whose row 0 is texture coordinate v = 0.
// pos: texture format decoding for all 14 PICA texture formats, including ETC1 and ETC1A4.

enum PICATextureFormat {
    // Bits per pixel for the format; ETC1 stores 4 bits and ETC1A4 8 bits per pixel.
    static func bitsPerPixel(_ format: Int) -> Int {
        switch format { case 0: return 32; case 1: return 24; case 2, 3, 4, 5, 6: return 16; case 7, 8, 9, 13: return 8; default: return 4 }
    }

    static func byteCount(format: Int, width: Int, height: Int) -> Int {
        (width + 7) / 8 * ((height + 7) / 8) * 64 * bitsPerPixel(format) / 8
    }

    @inline(__always) static func pack(_ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: UInt32) -> UInt32 { r | g << 8 | b << 16 | a << 24 }
    @inline(__always) static func expand4(_ v: UInt32) -> UInt32 { v << 4 | v }
    @inline(__always) static func expand5(_ v: UInt32) -> UInt32 { v << 3 | v >> 2 }
    @inline(__always) static func expand6(_ v: UInt32) -> UInt32 { v << 2 | v >> 4 }

    // Decodes one non-compressed pixel stored at `pixelIndex` of a tile.
    @inline(__always) static func pixel(_ format: Int, _ tile: UnsafePointer<UInt8>, _ index: Int) -> UInt32 {
        func half(_ at: Int) -> UInt32 { UInt32(tile[at]) | UInt32(tile[at + 1]) << 8 }
        switch format {
        case 0: return pack(UInt32(tile[index * 4 + 3]), UInt32(tile[index * 4 + 2]), UInt32(tile[index * 4 + 1]), UInt32(tile[index * 4]))
        case 1: return pack(UInt32(tile[index * 3 + 2]), UInt32(tile[index * 3 + 1]), UInt32(tile[index * 3]), 255)
        case 2:
            let v = half(index * 2)
            return pack(expand5(v >> 11), expand5((v >> 6) & 31), expand5((v >> 1) & 31), (v & 1) * 255)
        case 3:
            let v = half(index * 2)
            return pack(expand5(v >> 11), expand6((v >> 5) & 63), expand5(v & 31), 255)
        case 4:
            let v = half(index * 2)
            return pack(expand4(v >> 12), expand4((v >> 8) & 15), expand4((v >> 4) & 15), expand4(v & 15))
        case 5: let i = UInt32(tile[index * 2 + 1]); return pack(i, i, i, UInt32(tile[index * 2]))
        case 6: return pack(UInt32(tile[index * 2 + 1]), UInt32(tile[index * 2]), 0, 255)
        case 7: let i = UInt32(tile[index]); return pack(i, i, i, 255)
        case 8: return pack(0, 0, 0, UInt32(tile[index]))
        case 9: let i = expand4(UInt32(tile[index] >> 4)); return pack(i, i, i, expand4(UInt32(tile[index] & 15)))
        case 10:
            let v = UInt32(tile[index / 2] >> (index & 1 == 0 ? 0 : 4) & 15), i = expand4(v)
            return pack(i, i, i, 255)
        default:
            let v = UInt32(tile[index / 2] >> (index & 1 == 0 ? 0 : 4) & 15)
            return pack(0, 0, 0, expand4(v))
        }
    }

    static func decode(_ raw: UnsafePointer<UInt8>, width: Int, height: Int, format: Int, into pixels: UnsafeMutablePointer<UInt32>) {
        let tileBytes = 64 * bitsPerPixel(format) / 8
        for tileY in 0..<(height + 7) / 8 {
            for tileX in 0..<(width + 7) / 8 {
                let tile = raw + (tileY * ((width + 7) / 8) + tileX) * tileBytes
                for y in 0..<8 {
                    for x in 0..<8 {
                        let px = tileX * 8 + x, py = tileY * 8 + y
                        guard px < width, py < height else { continue }
                        let value = format >= 12 ? etc1Pixel(tile, x, y, hasAlpha: format == 13) : pixel(format, tile, PICAMath.morton(x, y))
                        pixels[(height - 1 - py) * width + px] = value
                    }
                }
            }
        }
    }

    private static let etcModifiers: [[Int]] = [[2, 8], [5, 17], [9, 29], [13, 42], [18, 60], [24, 80], [33, 106], [47, 183]]

    // An 8x8 ETC tile holds four 4x4 blocks (left to right, top to bottom), each with an optional 4-bit alpha plane.
    private static func etc1Pixel(_ tile: UnsafePointer<UInt8>, _ x: Int, _ y: Int, hasAlpha: Bool) -> UInt32 {
        let blockSize = hasAlpha ? 16 : 8
        let block = tile + (x / 4 + 2 * (y / 4)) * blockSize
        let bx = x % 4, by = y % 4
        var alpha: UInt32 = 255
        if hasAlpha {
            let nibble = 4 * bx + by
            alpha = expand4(UInt32(block[nibble / 2] >> (nibble & 1 == 0 ? 0 : 4) & 15))
        }
        let colorBlock = block + (hasAlpha ? 8 : 0)
        var data: UInt64 = 0
        for i in 0..<8 { data |= UInt64(colorBlock[i]) << UInt64(8 * i) }
        let texel = 4 * bx + by
        let flip = data >> 32 & 1 != 0, differential = data >> 33 & 1 != 0
        let second = (flip ? by : bx) >= 2
        var base = [0, 0, 0]
        for channel in 0..<3 {   // r, g, b
            let shift = UInt64(56 - 8 * channel)
            if differential {
                var value = Int(data >> (shift + 3) & 31)
                if second { let delta = Int(data >> shift & 7); value += delta >= 4 ? delta - 8 : delta }
                base[channel] = Int(expand5(UInt32(max(0, min(31, value)))))
            } else {
                base[channel] = Int(expand4(UInt32(data >> (second ? shift : shift + 4) & 15)))
            }
        }
        let table = Int(data >> (second ? 34 : 37) & 7)
        var modifier = etcModifiers[table][Int(data >> UInt64(texel) & 1)]
        if data >> UInt64(16 + texel) & 1 != 0 { modifier = -modifier }
        func channel(_ i: Int) -> UInt32 { UInt32(max(0, min(255, base[i] + modifier))) }
        return pack(channel(0), channel(1), channel(2), alpha)
    }
}
