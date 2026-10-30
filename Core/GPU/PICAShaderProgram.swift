// input: shader program words, swizzle patterns and uniform words written through the 0x2B0-0x2DD registers.
// output: program memory, swizzle table and float uniforms that the vertex shader interpreter reads.
// pos: write-side state of the (vertex) shader unit; PICACommandProcessor feeds it, PICAShaderUnit consumes it.

final class PICAShaderProgram {
    static let size = 4096
    private(set) var code = [UInt32](repeating: 0, count: size)
    private(set) var swizzles = [UInt32](repeating: 0, count: size)
    private(set) var uniforms = [SIMD4<Float>](repeating: .zero, count: 96)
    private(set) var version = 0   // changes with every code or swizzle word, so the GPU copy is refreshed
    private var codeOffset = 0, swizzleOffset = 0
    private var uniformIndex = 0, uniformIsFloat32 = false
    private var queue: [UInt32] = []

    func setCodeOffset(_ value: UInt32) { codeOffset = Int(value & 0xFFFF) }
    func setSwizzleOffset(_ value: UInt32) { swizzleOffset = Int(value & 0xFFFF) }

    func appendCode(_ word: UInt32) {
        guard codeOffset < Self.size else { return }
        code[codeOffset] = word
        version += 1
        codeOffset += 1
    }

    func appendSwizzle(_ word: UInt32) {
        guard swizzleOffset < Self.size else { return }
        swizzles[swizzleOffset] = word
        version += 1
        swizzleOffset += 1
    }

    func setUniformIndex(_ value: UInt32) {
        uniformIndex = Int(value & 0x7F)
        uniformIsFloat32 = value >> 31 != 0
        queue.removeAll(keepingCapacity: true)
    }

    // Four float24 values arrive packed in three words (w first), or four float32 values in four words.
    func appendUniform(_ word: UInt32) {
        queue.append(word)
        guard queue.count == (uniformIsFloat32 ? 4 : 3) else { return }
        defer { queue.removeAll(keepingCapacity: true) }
        let value: SIMD4<Float>
        if uniformIsFloat32 {
            value = SIMD4(Float(bitPattern: queue[3]), Float(bitPattern: queue[2]), Float(bitPattern: queue[1]), Float(bitPattern: queue[0]))
        } else {
            let x = queue[2] & 0xFFFFFF
            let y = (queue[1] & 0xFFFF) << 8 | queue[2] >> 24
            let z = (queue[0] & 0xFF) << 16 | queue[1] >> 16
            let w = queue[0] >> 8
            value = SIMD4(PICAMath.float24(x), PICAMath.float24(y), PICAMath.float24(z), PICAMath.float24(w))
        }
        guard uniformIndex < uniforms.count else { return }   // out-of-range indices (0x7F) are ignored by the hardware
        uniforms[uniformIndex] = value
        uniformIndex += 1
    }
}
