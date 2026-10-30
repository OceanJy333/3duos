// input: a shaded fragment color, its depth, and the destination color/depth/stencil values.
// output: alpha, stencil and depth test results, the blended color, and updated depth/stencil words.
// pos: per-pixel output merger stage that follows the texture combiner.

struct PICAMergerPipeline {
    let merger: PICAOutputMerger
    let depthFormat: Int
    let depthBits: Int
    let depthStencilWrite: Bool

    @inline(__always) static func compare(_ function: Int, _ a: UInt32, _ b: UInt32) -> Bool {
        switch function {
        case 0: return false
        case 1: return true
        case 2: return a == b
        case 3: return a != b
        case 4: return a < b
        case 5: return a <= b
        case 6: return a > b
        default: return a >= b
        }
    }

    @inline(__always) func alphaPasses(_ alpha: Int32) -> Bool {
        !merger.alphaTestEnabled || Self.compare(merger.alphaFunc, UInt32(alpha), UInt32(merger.alphaRef))
    }

    @inline(__always) private static func stencilAction(_ action: Int, _ old: UInt8, _ reference: UInt8) -> UInt8 {
        switch action {
        case 0: return old
        case 1: return 0
        case 2: return reference
        case 3: return min(old, 254) + 1
        case 4: return max(old, 1) - 1
        case 5: return ~old
        case 6: return old &+ 1
        default: return old &- 1
        }
    }

    // Runs the stencil and depth tests for one pixel of a D16/D24/D24S8 buffer and applies their writes.
    @inline(__always) func depthStencilPasses(_ p: UnsafeMutablePointer<UInt8>, depth z: UInt32) -> Bool {
        let hasStencil = merger.stencilEnabled && depthFormat == 3
        var old: UInt8 = 0
        func updateStencil(_ action: Int) {
            guard depthStencilWrite else { return }
            let new = Self.stencilAction(action, old, merger.stencilRef)
            p[3] = new & merger.stencilWriteMask | old & ~merger.stencilWriteMask
        }
        if hasStencil {
            old = p[3]
            let pass = Self.compare(merger.stencilFunc, UInt32(merger.stencilRef & merger.stencilInputMask), UInt32(old & merger.stencilInputMask))
            if !pass { updateStencil(merger.stencilFail); return false }
        }
        if merger.depthTestEnabled, !Self.compare(merger.depthFunc, z, PICADepthFormat.read(p, depthFormat) & 0xFFFFFF) {
            if hasStencil { updateStencil(merger.stencilDepthFail) }
            return false
        }
        if depthStencilWrite, merger.depthWrite { PICADepthFormat.write(p, depthFormat, depth: z) }
        if hasStencil { updateStencil(merger.stencilPass) }
        return true
    }

    // Early depth test used when nothing after the combiner can discard the fragment.
    var canTestDepthEarly: Bool { !merger.alphaTestEnabled && !merger.stencilEnabled }

    // Blending (or the logic op) returns the source unchanged in every channel: ONE/ZERO with add, subtract or max, or copy.
    var replacesDestination: Bool {
        guard merger.colorMask == 15 else { return false }
        guard merger.blendEnabled else { return merger.logicOp == 3 }
        let keeps = [0, 1, 4]
        return merger.sourceRGB == 1 && merger.destRGB == 0 && merger.sourceAlpha == 1 && merger.destAlpha == 0
            && keeps.contains(merger.equationRGB) && keeps.contains(merger.equationAlpha)
    }

    @inline(__always) private func factor(_ id: Int, _ s: PICAColor, _ d: PICAColor) -> PICAColor {
        let one = PICAColor(repeating: 255)
        switch id {
        case 0: return PICAColor(repeating: 0)
        case 1: return one
        case 2: return s
        case 3: return one &- s
        case 4: return d
        case 5: return one &- d
        case 6: return PICAColor(repeating: s.w)
        case 7: return one &- PICAColor(repeating: s.w)
        case 8: return PICAColor(repeating: d.w)
        case 9: return one &- PICAColor(repeating: d.w)
        case 10: return merger.blendColor
        case 11: return one &- merger.blendColor
        case 12: return PICAColor(repeating: merger.blendColor.w)
        case 13: return one &- PICAColor(repeating: merger.blendColor.w)
        default: let saturated = min(s.w, 255 - d.w); return PICAColor(saturated, saturated, saturated, 255)
        }
    }

    @inline(__always) private static func equation(_ id: Int, _ s: PICAColor, _ d: PICAColor) -> PICAColor {
        switch id {
        case 0: return (s &+ d) / 255
        case 1: return (s &- d) / 255
        case 2: return (d &- s) / 255
        case 3: return pointwiseMin(s, d) / 255
        default: return pointwiseMax(s, d) / 255
        }
    }

    @inline(__always) private static func logic(_ op: Int, _ s: PICAColor, _ d: PICAColor) -> PICAColor {
        let mask = PICAColor(repeating: 255)
        switch op {
        case 0: return PICAColor(repeating: 0)
        case 1: return s & d
        case 2: return s & ~d & mask
        case 3: return s
        case 4: return mask
        case 5: return ~s & mask
        case 6: return d
        case 7: return ~d & mask
        case 8: return ~(s & d) & mask
        case 9: return s | d
        case 10: return ~(s | d) & mask
        case 11: return s ^ d
        case 12: return ~(s ^ d) & mask
        case 13: return ~s & d
        case 14: return (s | ~d) & mask
        default: return (~s | d) & mask
        }
    }

    // Final color including blending (or the logic op when blending is off) and the per-channel write mask.
    @inline(__always) func blend(_ source: PICAColor, over destination: PICAColor) -> PICAColor {
        var result: PICAColor
        if merger.blendEnabled {
            var sf = factor(merger.sourceRGB, source, destination), df = factor(merger.destRGB, source, destination)
            sf.w = factor(merger.sourceAlpha, source, destination).w
            df.w = factor(merger.destAlpha, source, destination).w
            let s = source &* sf, d = destination &* df
            result = Self.equation(merger.equationRGB, s, d)
            if merger.equationAlpha != merger.equationRGB { result.w = Self.equation(merger.equationAlpha, s, d).w }
            result = pointwiseMin(pointwiseMax(result, PICAColor(repeating: 0)), PICAColor(repeating: 255))
        } else {
            result = Self.logic(merger.logicOp, source, destination)
        }
        let mask = merger.colorMask
        if mask == 15 { return result }
        for lane in 0..<4 where mask >> UInt8(lane) & 1 == 0 { result[lane] = destination[lane] }
        return result
    }
}
