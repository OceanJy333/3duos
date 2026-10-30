// input: vertex ids, the vertex layout, default attributes, the shader program and shader/output-map registers.
// output: clip-space vertices (software backend) with colors saturated and texture coordinates in their semantic slots.
// pos: runs the vertex shader for every vertex of a draw, in parallel chunks, and maps shader outputs to rasterizer inputs.
import Foundation

struct PICAClipVertex {
    var position = SIMD4<Float>(0, 0, 0, 1)
    var color = SIMD4<Float>(1, 1, 1, 1)
    var texture01 = SIMD4<Float>(1, 1, 1, 1)       // u0 v0 u1 v1
    var texture2W = SIMD4<Float>(1, 1, 1, 1)       // u2 v2 w0 (unused)
    var quaternion = SIMD4<Float>(0, 0, 0, 1)      // normal orientation for fragment lighting
    var view = SIMD4<Float>(0, 0, 0, 0)            // view vector xyz for fragment lighting
    var previous = SIMD4<Float>(0, 0, 0, 0)        // clip position under last frame's uniforms (w = 0: none); gives MetalFX motion

    mutating func lerp(_ other: PICAClipVertex, _ t: Float) {
        position += (other.position - position) * t
        color += (other.color - color) * t
        texture01 += (other.texture01 - texture01) * t
        texture2W += (other.texture2W - texture2W) * t
        quaternion += (other.quaternion - quaternion) * t
        view += (other.view - view) * t
        previous += (other.previous - previous) * t
    }
}

final class PICAVertexProcessor {
    private var units: [PICAShaderUnit] = []

    // Semantic slots: 0-3 position, 4-7 normal quaternion, 8-11 color, 12-15 texcoord0/1, 16 texcoord0 w, 18-20 view,
    // 22-23 texcoord2 (3dbrew vertex output map).
    func process(_ vertices: UnsafeBufferPointer<Int>, layout: PICAVertexLayout, data: UnsafeRawPointer, length: Int,
                 defaults: UnsafePointer<SIMD4<Float>>, program: PICAShaderProgram, uniforms: [SIMD4<Float>], registers r: PICARegisters,
                 into output: UnsafeMutablePointer<PICAClipVertex>) {
        let outputRegisters = (0..<16).filter { r[PICAReg.outputMask] >> UInt32($0) & 1 != 0 }
        let semanticCount = min(r.field(PICAReg.outputTotal, 0, 3), outputRegisters.count)
        let semantics = (0..<semanticCount).map { a in (0..<4).map { c in r.field(PICAReg.outputMap + a, 8 * c, 5) } }
        let permutation = UInt64(r[PICAReg.inputPermutation]) | UInt64(r[PICAReg.inputPermutation + 1]) << 32
        let inputCount = r.field(PICAReg.inputConfig, 0, 4) + 1
        let bools = r[PICAReg.boolUniforms]
        let ints = SIMD4(r[PICAReg.intUniforms], r[PICAReg.intUniforms + 1], r[PICAReg.intUniforms + 2], r[PICAReg.intUniforms + 3])
        let entry = r.field(PICAReg.entryPoint, 0, 16)
        // Waking cores costs more than shading a small draw: only large draws are spread, in 512-vertex chunks.
        let chunkSize = 512, chunks = (vertices.count + chunkSize - 1) / chunkSize
        let workers = max(1, min(chunks, 4))
        while units.count < workers { units.append(PICAShaderUnit()) }

        program.code.withUnsafeBufferPointer { code in program.swizzles.withUnsafeBufferPointer { swizzles in
        uniforms.withUnsafeBufferPointer { uniforms in
            let shade = { (worker: Int) in
                let unit = self.units[worker]
                let slots = UnsafeMutablePointer<Float>.allocate(capacity: 32)
                let attributes = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: 16)
                defer { slots.deallocate(); attributes.deallocate() }
                for chunk in stride(from: worker, to: chunks, by: workers) {
                    for i in chunk * chunkSize..<min(vertices.count, (chunk + 1) * chunkSize) {
                        layout.load(vertex: vertices[i], data: data, length: length, defaults: defaults, output: attributes)
                        for a in 0..<inputCount { unit.file[Int((permutation >> UInt64(4 * a)) & 15)] = attributes[a] }
                        unit.run(code: code.baseAddress!, swizzles: swizzles.baseAddress!, uniforms: uniforms.baseAddress!,
                                 bools: bools, ints: ints, entry: entry)
                        slots.initialize(repeating: 1, count: 32)   // outputs the map leaves unset read as 1
                        for a in 0..<semanticCount {
                            let value = unit.file[32 + outputRegisters[a]]
                            for c in 0..<4 { slots[semantics[a][c]] = value[c] }
                        }
                        var v = PICAClipVertex()
                        v.position = SIMD4(slots[0], slots[1], slots[2], slots[3])
                        // The hardware takes the absolute value and saturates vertex colors before interpolation.
                        let c = SIMD4<Float>(slots[8], slots[9], slots[10], slots[11])
                        v.color = pointwiseMin(c.replacing(with: -c, where: c .< 0), SIMD4(repeating: 1))
                        v.texture01 = SIMD4(slots[12], slots[13], slots[14], slots[15])
                        v.texture2W = SIMD4(slots[22], slots[23], slots[16], 0)
                        v.quaternion = SIMD4(slots[4], slots[5], slots[6], slots[7])
                        v.view = SIMD4(slots[18], slots[19], slots[20], 0)
                        output[i] = v
                    }
                }
            }
            if workers == 1 { shade(0) } else { DispatchQueue.concurrentPerform(iterations: workers, execute: shade) }
        }}}
    }
}
