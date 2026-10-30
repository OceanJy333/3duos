// input: lighting registers 0x140-0x1D9, the 24x256 lighting lookup tables, an interpolated normal quaternion and view vector.
// output: the primary (diffuse) and secondary (specular) fragment colors that TEV sources 1 and 2 read.
// pos: fixed-function fragment lighting, run per pixel by the rasterizer before the texture combiner (Citra sw_lighting).
import simd

struct PICALight {
    var specular0 = SIMD3<Float>(), specular1 = SIMD3<Float>(), diffuse = SIMD3<Float>(), ambient = SIMD3<Float>()
    var position = SIMD3<Float>(), spot = SIMD3<Float>()
    var directional = false, twoSided = false, geometric0 = false, geometric1 = false
    var distanceBias: Float = 0, distanceScale: Float = 0
    var index = 0                                   // hardware light slot; selects its spot and distance tables
    var spotEnabled = false, distanceEnabled = false, shadowed = false
}

// One lookup-table input: which angle feeds it, whether it uses |x|, its scale, and the table it reads.
struct PICALightingInput {
    var enabled = false, source = 0, absolute = true, scale: Float = 1, table = 0
}

struct PICALightingState {
    var enabled = false
    var lights: [PICALight] = []
    var globalAmbient = SIMD3<Float>()
    var config = 0, clampHighlights = false, primaryAlpha = false, secondaryAlpha = false
    var distribution0 = PICALightingInput(), distribution1 = PICALightingInput(), fresnel = PICALightingInput()
    var reflect = (PICALightingInput(), PICALightingInput(), PICALightingInput())
    var spot = PICALightingInput()
    var lut: UnsafePointer<UInt32>?                // 24 tables of 256 entries, owned by the renderer

    init() {}

    init(_ r: PICARegisters) {
        enabled = r.field(0x8F, 0, 1) == 1 && r.field(0x1C6, 0, 1) == 0   // LIGHTING_ENABLE0 and not LIGHTING_ENABLE1-disable
        guard enabled else { return }
        let config0 = r[0x1C3], config1 = r[0x1C4], absolute = r[0x1D0], inputs = r[0x1D1], scales = r[0x1D2]
        config = Int((config0 >> 4) & 15)
        primaryAlpha = config0 >> 2 & 1 != 0; secondaryAlpha = config0 >> 3 & 1 != 0
        clampHighlights = config0 >> 27 & 1 != 0
        globalAmbient = Self.color(r[0x1C0])
        func input(_ field: UInt32, disabledBit: Int, supported: Bool, table: Int) -> PICALightingInput {
            var i = PICALightingInput()
            i.enabled = supported && (disabledBit < 0 || config1 >> UInt32(disabledBit) & 1 == 0)
            i.source = Int((inputs >> field) & 7)
            i.absolute = (absolute >> (field + 1)) & 1 == 0
            i.scale = [1, 2, 4, 8, 1, 1, 0.25, 0.5][Int((scales >> field) & 7)]
            i.table = table
            return i
        }
        let c = config
        distribution0 = input(0, disabledBit: 16, supported: c != 1, table: 0)
        distribution1 = input(4, disabledBit: 17, supported: c != 0 && c != 1 && c != 5, table: 1)
        spot = input(8, disabledBit: -1, supported: c != 2 && c != 3, table: 8)
        fresnel = input(12, disabledBit: 19, supported: c != 0 && c != 2 && c != 4, table: 3)
        let rgb = c == 4 || c == 5 || c == 8
        reflect = (input(24, disabledBit: 20, supported: c != 3, table: 6), input(20, disabledBit: 21, supported: rgb, table: 5),
                   input(16, disabledBit: 22, supported: rgb, table: 4))
        for slot in 0...Int(r[0x1C2] & 7) {
            let index = Int((r[0x1D9] >> UInt32(4 * slot)) & 7), base = 0x140 + 0x10 * index
            var l = PICALight()
            l.index = index
            l.specular0 = Self.color(r[base]); l.specular1 = Self.color(r[base + 1])
            l.diffuse = Self.color(r[base + 2]); l.ambient = Self.color(r[base + 3])
            l.position = SIMD3(PICAMath.float(r[base + 4] & 0xFFFF, mantissa: 10, exponent: 5),
                               PICAMath.float(r[base + 4] >> 16, mantissa: 10, exponent: 5),
                               PICAMath.float(r[base + 5] & 0xFFFF, mantissa: 10, exponent: 5))
            func s13(_ v: UInt32) -> Float { Float(Int32(bitPattern: v << 19) >> 19) / 2047 }
            l.spot = SIMD3(s13(r[base + 6]), s13(r[base + 6] >> 16), s13(r[base + 7]))
            let flags = r[base + 9]
            l.directional = flags & 1 != 0; l.twoSided = flags & 2 != 0; l.geometric0 = flags & 4 != 0; l.geometric1 = flags & 8 != 0
            l.distanceBias = PICAMath.float(r[base + 10] & 0xFFFFF, mantissa: 12, exponent: 7)
            l.distanceScale = PICAMath.float(r[base + 11] & 0xFFFFF, mantissa: 12, exponent: 7)
            l.spotEnabled = spot.enabled && config1 >> UInt32(8 + index) & 1 == 0
            l.distanceEnabled = config1 >> UInt32(24 + index) & 1 == 0
            lights.append(l)
        }
    }

    // Light colors hold 10-bit channels (blue low) in 0...255 units that may exceed 1.0.
    private static func color(_ v: UInt32) -> SIMD3<Float> {
        SIMD3(Float((v >> 20) & 0x3FF), Float((v >> 10) & 0x3FF), Float(v & 0x3FF)) / 255
    }
}

struct PICALightingPipeline {
    let state: PICALightingState
    let lights: UnsafePointer<PICALight>
    let lut: UnsafePointer<UInt32>

    // Entry: 12-bit value in 0.0.12, 11-bit difference to the next entry with a sign bit, both in units of 1/4095 and 1/2047.
    @inline(__always) private func sample(_ table: Int, _ index: Int, _ delta: Float) -> Float {
        let e = lut[table * 256 + index]
        let difference = Float((e >> 12) & 0x7FF) / 2047
        return Float(e & 0xFFF) / 4095 + (e >> 23 & 1 != 0 ? -difference : difference) * delta
    }

    @inline(__always) private func lookup(_ input: PICALightingInput, _ value: Float, table: Int, twoSided: Bool) -> Float {
        var v = value
        let index: Int, delta: Float
        if input.absolute {
            v = twoSided ? abs(v) : max(v, 0)
            let i = min(max((v * 256).rounded(.down), 0), 255)
            index = Int(i); delta = v * 256 - i
        } else {
            let i = min(max((v * 128).rounded(.down), -128), 127)
            index = Int(UInt8(bitPattern: Int8(i))); delta = v * 128 - i
        }
        return input.scale * sample(table, index, delta)
    }

    @inline(__always) private static func rotate(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let u = SIMD3(q.x, q.y, q.z)
        return v + 2 * cross(u, cross(u, v) + v * q.w)
    }

    // `quaternion` and `view` are already perspective-interpolated; returns colors in 0...255.
    @inline(__always) func evaluate(quaternion: SIMD4<Float>, view: SIMD3<Float>) -> (PICAColor, PICAColor) {
        let q = quaternion / (quaternion * quaternion).sum().squareRoot()
        let normal = Self.rotate(q, SIMD3(0, 0, 1))
        let normView = normalize(view)
        var diffuse = SIMD4<Float>(0, 0, 0, 1), specular = SIMD4<Float>(0, 0, 0, 1)
        for i in 0..<state.lights.count {
            let light = lights[i]
            var lightVector = light.directional ? light.position : light.position + view
            let length = (lightVector * lightVector).sum().squareRoot()
            lightVector /= length
            let half = normView + lightVector
            let halfNormalized = normalize(half)
            func angle(_ source: Int) -> Float {
                switch source {
                case 0: return dot(normal, halfNormalized)
                case 1: return dot(normView, halfNormalized)
                case 2: return dot(normal, normView)
                case 3: return dot(lightVector, normal)
                case 4: return dot(lightVector, light.spot)
                default: return 0   // CP needs a tangent (config 7 bump mapping), not supported
                }
            }
            func value(_ input: PICALightingInput, table: Int? = nil) -> Float {
                lookup(input, angle(input.source), table: table ?? input.table, twoSided: light.twoSided)
            }
            var distance: Float = 1
            if light.distanceEnabled {
                let at = min(max(light.distanceScale * length + light.distanceBias, 0), 1)
                let index = min(max((at * 256).rounded(.down), 0), 255)
                distance = sample(16 + light.index, Int(index), at * 256 - index)
            }
            let spot = light.spotEnabled ? value(state.spot, table: 8 + light.index) : 1
            var specular0 = (state.distribution0.enabled ? value(state.distribution0) : 1) * light.specular0
            var reflect = SIMD3<Float>(repeating: state.reflect.0.enabled ? value(state.reflect.0) : 1)
            if state.reflect.1.enabled { reflect.y = value(state.reflect.1) }
            if state.reflect.2.enabled { reflect.z = value(state.reflect.2) }
            var specular1 = (state.distribution1.enabled ? value(state.distribution1) : 1) * reflect * light.specular1
            if i == state.lights.count - 1, state.fresnel.enabled {
                let f = value(state.fresnel)
                if state.primaryAlpha { diffuse.w = f }
                if state.secondaryAlpha { specular.w = f }
            }
            var d = dot(lightVector, normal)
            d = light.twoSided ? abs(d) : max(d, 0)
            let clamp: Float = state.clampHighlights && d == 0 ? 0 : 1
            if light.geometric0 || light.geometric1 {
                let g = (half * half).sum()
                let factor = g == 0 ? 0 : min(d / g, 1)
                if light.geometric0 { specular0 *= factor }
                if light.geometric1 { specular1 *= factor }
            }
            let lit = (light.diffuse * d + light.ambient) * distance * spot
            let shine = (specular0 + specular1) * clamp * distance * spot
            diffuse += SIMD4(lit, 0); specular += SIMD4(shine, 0)
        }
        diffuse += SIMD4(state.globalAmbient, 0)
        func color(_ c: SIMD4<Float>) -> PICAColor {
            @inline(__always) func lane(_ f: Float) -> Int32 { f > 0 ? Int32(min(f, 1) * 255) : 0 }
            return PICAColor(lane(c.x), lane(c.y), lane(c.z), lane(c.w))
        }
        return (color(diffuse), color(specular))
    }
}
