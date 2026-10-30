// input: interpolated vertex color and texture coordinates, decoded textures, and the six TEV stage settings.
// output: the 8-bit RGBA fragment color produced by the texture combiner chain.
// pos: per-pixel texturing and texture environment stage; lighting is in PICALighting, procedural textures are not implemented.

typealias PICAColor = SIMD4<Int32>

// A texture unit resolved for rasterization: decoded pixels plus the wrap and filter mode.
struct PICASampler {
    var pixels: UnsafePointer<UInt32>?
    var width: Int32 = 0, height: Int32 = 0
    var wrapS: Int32 = 0, wrapT: Int32 = 0
    var linear = false
    var border: UInt32 = 0

    @inline(__always) static func unpack(_ c: UInt32) -> PICAColor {
        PICAColor(Int32(c & 255), Int32((c >> 8) & 255), Int32((c >> 16) & 255), Int32(c >> 24))
    }

    // Texel index along one axis after wrapping, or -1 for the border color. PICA texture sizes are powers of two.
    @inline(__always) private static func wrap(_ mode: Int32, _ c: Int, _ size: Int) -> Int {
        @inline(__always) func modulo(_ c: Int) -> Int { size & (size - 1) == 0 ? c & (size - 1) : (c % size + size) % size }
        switch mode {
        case 0: return min(max(c, 0), size - 1)
        case 1: return c >= 0 && c < size ? c : -1
        case 3:   // mirrored repeat: period 2 * size
            let m = (c % (2 * size) + 2 * size) % (2 * size)
            return m >= size ? 2 * size - 1 - m : m
        case 4: return c < 0 ? modulo(c) : min(c, size - 1)
        case 5: return c < 0 ? modulo(c) : (c >= size ? -1 : c)
        default: return modulo(c)
        }
    }

    @inline(__always) private func texel(_ x: Int, _ y: Int) -> PICAColor {
        x < 0 || y < 0 ? Self.unpack(border) : Self.unpack(pixels![y * Int(width) + x])
    }

    @inline(__always) func sample(u: Float, v: Float) -> PICAColor {
        let x = u * Float(width), y = v * Float(height), w = Int(width), h = Int(height)
        guard linear else {
            return texel(Self.wrap(wrapS, PICAMath.integer(x.rounded(.down)), w), Self.wrap(wrapT, PICAMath.integer(y.rounded(.down)), h))
        }
        let fx = x - 0.5, fy = y - 0.5
        let x0 = fx.rounded(.down), y0 = fy.rounded(.down)
        let wx = Int32(PICAMath.integer((fx - x0) * 256)), wy = Int32(PICAMath.integer((fy - y0) * 256))
        let ix = PICAMath.integer(x0), iy = PICAMath.integer(y0)
        let sx0 = Self.wrap(wrapS, ix, w), sx1 = Self.wrap(wrapS, ix + 1, w)
        let sy0 = Self.wrap(wrapT, iy, h), sy1 = Self.wrap(wrapT, iy + 1, h)
        let top = texel(sx0, sy0) &* (256 - wx) &+ texel(sx1, sy0) &* wx
        let bottom = texel(sx0, sy1) &* (256 - wx) &+ texel(sx1, sy1) &* wx
        return (top &* (256 - wy) &+ bottom &* wy) &>> 16
    }
}

struct PICATevPipeline {
    let stages: UnsafePointer<PICATevStage>?      // bound when the draw runs
    let stageCount: Int
    let bufferColor: PICAColor

    @inline(__always) private static func divide255(_ x: PICAColor) -> PICAColor {
        let t = x &+ 1
        return (t &+ (t &>> 8)) &>> 8
    }

    @inline(__always) private static func invert(_ v: PICAColor) -> PICAColor { PICAColor(repeating: 255) &- v }

    @inline(__always) private static func colorModifier(_ m: UInt8, _ v: PICAColor) -> PICAColor {
        switch m {
        case 1: return invert(v)
        case 2: return PICAColor(repeating: v.w)
        case 3: return invert(PICAColor(repeating: v.w))
        case 4: return PICAColor(repeating: v.x)
        case 5: return invert(PICAColor(repeating: v.x))
        case 8: return PICAColor(repeating: v.y)
        case 9: return invert(PICAColor(repeating: v.y))
        case 12: return PICAColor(repeating: v.z)
        case 13: return invert(PICAColor(repeating: v.z))
        default: return v
        }
    }

    @inline(__always) private static func alphaModifier(_ m: UInt8, _ v: PICAColor) -> Int32 {
        let channel: Int32
        switch m >> 1 { case 0: channel = v.w; case 1: channel = v.x; case 2: channel = v.y; default: channel = v.z }
        return m & 1 == 0 ? channel : 255 - channel
    }

    @inline(__always) private static func combine(_ op: UInt8, _ a: PICAColor, _ b: PICAColor, _ c: PICAColor) -> PICAColor {
        let zero = PICAColor(repeating: 0), full = PICAColor(repeating: 255)
        switch op {
        case 0: return a
        case 1: return divide255(a &* b)
        case 2: return pointwiseMin(a &+ b, full)
        case 3: return pointwiseMin(pointwiseMax(a &+ b &- 128, zero), full)
        case 4: return divide255(a &* c &+ b &* (full &- c))
        case 5: return pointwiseMax(a &- b, zero)
        case 6, 7:
            let product = (a &* 2 &- 255) &* (b &* 2 &- 255) &+ 128
            let sum = product.x / 256 + product.y / 256 + product.z / 256
            return PICAColor(repeating: min(max(sum, 0), 255))
        case 8: return pointwiseMin((a &* b &+ c &* 255) / 255, full)
        default: return divide255(pointwiseMin(a &+ b, full) &* c)
        }
    }

    // `primary` is the interpolated vertex color; `textures` the three sampled units (texture 3 is not supported).
    // `lit` holds the primary and secondary fragment-lighting colors (sources 1 and 2).
    @inline(__always) func evaluate(primary: PICAColor, lit: (PICAColor, PICAColor), textures: (PICAColor, PICAColor, PICAColor)) -> PICAColor {
        var output = PICAColor(repeating: 0), buffer = PICAColor(repeating: 0), nextBuffer = bufferColor
        for index in 0..<stageCount {
            let stage = stages.unsafelyUnwrapped[index]
            @inline(__always) func source(_ id: UInt8) -> PICAColor {
                switch id {
                case 0: return primary
                case 1: return lit.0
                case 2: return lit.1
                case 3: return textures.0
                case 4: return textures.1
                case 5: return textures.2
                case 0xD: return buffer
                case 0xE: return stage.constant
                case 0xF: return output
                default: return PICAColor(repeating: 0)
                }
            }
            // Stage 0 has no previous result; the hardware feeds its third source in instead.
            let first = index == 0 && stage.colorSource.0 == 0xF ? stage.colorSource.2 : stage.colorSource.0
            let second = index == 0 && stage.colorSource.1 == 0xF ? stage.colorSource.2 : stage.colorSource.1
            let colorInputs = (Self.colorModifier(stage.colorModifier.0, source(first)),
                               Self.colorModifier(stage.colorModifier.1, source(second)),
                               Self.colorModifier(stage.colorModifier.2, source(stage.colorSource.2)))
            var color = Self.combine(stage.colorOp, colorInputs.0, colorInputs.1, colorInputs.2)
            var alpha: Int32
            if stage.colorOp == 7 {
                alpha = color.x
            } else {
                let a = PICAColor(repeating: Self.alphaModifier(stage.alphaModifier.0, source(stage.alphaSource.0)))
                let b = PICAColor(repeating: Self.alphaModifier(stage.alphaModifier.1, source(stage.alphaSource.1)))
                let c = PICAColor(repeating: Self.alphaModifier(stage.alphaModifier.2, source(stage.alphaSource.2)))
                alpha = Self.combine(stage.alphaOp, a, b, c).x
            }
            color = pointwiseMin(color &* stage.colorScale, PICAColor(repeating: 255))
            alpha = min(alpha * stage.alphaScale, 255)
            output = PICAColor(color.x, color.y, color.z, alpha)
            buffer = nextBuffer
            if stage.updatesBufferColor { nextBuffer = PICAColor(output.x, output.y, output.z, nextBuffer.w) }
            if stage.updatesBufferAlpha { nextBuffer.w = output.w }
        }
        return output
    }
}
