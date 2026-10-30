// input: the attribute-buffer registers 0x200-0x227 and vertex data copied out of guest memory.
// output: per-vertex shader input attributes (up to 16 float4) with format conversion and default values applied.
// pos: vertex fetch stage in front of the shader interpreter.
import Foundation

struct PICAVertexLayout {
    let base: UInt32                       // physical address that attribute-loader and index offsets are relative to
    let attributeCount: Int
    let indexOffset: Int, indexIsShort: Bool
    private var isFixed = [Bool](repeating: true, count: 16)
    private var source = [Int](repeating: 0, count: 12), stride = [Int](repeating: 0, count: 12)
    private var format = [Int](repeating: 0, count: 12), elements = [Int](repeating: 0, count: 12)
    // Each loader is an independent buffer; they may sit in different memory regions (e.g. VRAM base with FCRAM offsets).
    private var loaderStart = [UInt32](repeating: 0, count: 12), loaderEnd = [Int](repeating: 0, count: 12)
    private var loaderOf = [Int](repeating: -1, count: 12)

    // Identifies the mesh a draw reads: its buffers and index data, not the vertex range inside them.
    var meshIdentity: Int {
        var hasher = Hasher()
        hasher.combine(base); hasher.combine(indexOffset)
        for i in 0..<12 { hasher.combine(loaderStart[i]); hasher.combine(loaderEnd[i]) }
        return hasher.finalize()
    }

    init(_ r: PICARegisters) {
        base = ((r[PICAReg.attributeBase] >> 1) & 0x0FFF_FFFF) &* 16
        attributeCount = r.field(PICAReg.attributeFormatsHigh, 28, 4) + 1
        indexOffset = r.field(PICAReg.indexArray, 0, 28)
        indexIsShort = r.field(PICAReg.indexArray, 31, 1) != 0
        let fixedMask = r.field(PICAReg.attributeFormatsHigh, 16, 12)
        for i in 0..<12 {
            isFixed[i] = fixedMask >> i & 1 != 0
            let word = r[i < 8 ? PICAReg.attributeFormats : PICAReg.attributeFormatsHigh] >> UInt32(4 * (i % 8))
            format[i] = Int(word & 3); elements[i] = Int((word >> 2) & 3) + 1
        }
        for loader in 0..<12 {
            let registers = PICAReg.attributeLoaders + 3 * loader
            let low = UInt64(r[registers + 1]) | UInt64(r[registers + 2] & 0xFFFF) << 32
            let componentCount = r.field(registers + 2, 28, 4), byteCount = r.field(registers + 2, 16, 8)
            loaderStart[loader] = base &+ (r[registers] & 0x0FFF_FFFF)
            var offset = 0
            for component in 0..<min(componentCount, 12) {
                let attribute = Int((low >> UInt64(4 * component)) & 15)
                if attribute < 12 {
                    let size = Self.elementSize(format[attribute])
                    offset = (offset + size - 1) / size * size
                    source[attribute] = offset                  // relative to the loader until `fetch` places it in the arena
                    stride[attribute] = byteCount
                    loaderOf[attribute] = loader
                    offset += size * elements[attribute]
                    loaderEnd[loader] = offset
                } else {
                    offset = (offset + 3) & ~3
                    offset += (attribute - 11) * 4      // 12...15 are 4, 8, 12 and 16 bytes of padding
                }
            }
        }
    }

    // Layout for immediate-mode vertices: every attribute comes from the default-attribute registers.
    init(fixedAttributeCount: Int) {
        base = 0; attributeCount = fixedAttributeCount; indexOffset = 0; indexIsShort = false
    }

    private static func elementSize(_ format: Int) -> Int { format == 3 ? 4 : format == 2 ? 2 : 1 }

    func isFetched(_ attribute: Int) -> Bool { attribute < 12 && !isFixed[attribute] && stride[attribute] > 0 }

    // Copies the buffer of every loader that feeds a fetched attribute (vertices 0...maxVertex) into one contiguous arena and
    // points the attributes into it. Returns nil when the buffers exceed 64 MiB or cannot be read.
    mutating func fetch(maxVertex: Int, memory: PagedMemory) -> [UInt8]? {
        var arena: [UInt8] = []
        var placed = [Int](repeating: -1, count: 12)
        for attribute in 0..<min(attributeCount, 12) where isFetched(attribute) {
            let loader = loaderOf[attribute]
            if placed[loader] < 0 {
                let length = stride[attribute] * maxVertex + loaderEnd[loader]
                guard arena.count + length <= 1 << 26 else { return nil }
                var bytes = [UInt8](repeating: 0, count: length)
                guard memory.copyOut(GPUState.virtualAddress(loaderStart[loader]), to: &bytes, count: length) else { return nil }
                placed[loader] = arena.count
                arena += bytes
            }
            source[attribute] += placed[loader]
        }
        return arena
    }

    // Fills `output[0..<attributeCount]`. Attributes that read outside `data` stay at (0, 0, 0, 1).
    func load(vertex: Int, data: UnsafeRawPointer, length: Int, defaults: UnsafePointer<SIMD4<Float>>,
              output: UnsafeMutablePointer<SIMD4<Float>>) {
        for i in 0..<attributeCount {
            guard i < 12, isFetched(i) else { output[i] = defaults[i]; continue }
            var value = SIMD4<Float>(0, 0, 0, 1)
            let size = Self.elementSize(format[i]), at = source[i] + stride[i] * vertex
            if at + size * elements[i] <= length {
                for c in 0..<elements[i] {
                    let p = data + at + c * size
                    switch format[i] {
                    case 0: value[c] = Float(p.loadUnaligned(as: Int8.self))
                    case 1: value[c] = Float(p.loadUnaligned(as: UInt8.self))
                    case 2: value[c] = Float(p.loadUnaligned(as: Int16.self))
                    default: value[c] = p.loadUnaligned(as: Float.self)
                    }
                }
            }
            output[i] = value
        }
    }
}
