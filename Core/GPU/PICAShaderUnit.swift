// input: shader program words, swizzle table, uniforms and a vertex's input registers.
// output: the 16 output registers of one shader run (float32 stands in for the hardware float24).
// pos: PICA vertex shader interpreter. Geometry-shader instructions (EMIT, SETEMIT) are accepted and ignored.
import Foundation

final class PICAShaderUnit {
    // Register file: input 0..<16, temporary 16..<32, output 32..<48. Float uniforms are passed per run.
    let file = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: 48)
    private var address = SIMD3<Int32>(repeating: 0)       // a0.x, a0.y, aL
    private var conditionX = false, conditionY = false
    private let ifStack = UnsafeMutablePointer<SIMD2<Int>>.allocate(capacity: 16)      // else address, end address
    private let callStack = UnsafeMutablePointer<SIMD2<Int>>.allocate(capacity: 16)    // end address, return address
    private let loopStack = UnsafeMutablePointer<SIMD4<Int>>.allocate(capacity: 16)    // entry, end, counter|increment<<8, previous aL
    private static let one = SIMD4<Float>(repeating: 1)

    init() { file.initialize(repeating: .zero, count: 48) }
    deinit { file.deallocate(); ifStack.deallocate(); callStack.deallocate(); loopStack.deallocate() }

    @inline(__always) private static func multiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        let product = a * b
        let nan = product .!= product
        // The hardware returns 0 for 0 * infinity instead of NaN.
        if any(nan) { return product.replacing(with: 0, where: nan .& .!((a .!= a) .| (b .!= b))) }
        return product
    }

    private static func integer(_ f: Float) -> Int32 { f.isNaN ? 0 : Int32(max(-1e9, min(1e9, f))) }

    @inline(__always) private static func swizzle(_ v: SIMD4<Float>, _ pattern: UInt32, _ shift: UInt32, negate: Bool) -> SIMD4<Float> {
        let r = SIMD4(v[Int((pattern >> (shift + 6)) & 3)], v[Int((pattern >> (shift + 4)) & 3)],
                      v[Int((pattern >> (shift + 2)) & 3)], v[Int((pattern >> shift) & 3)])
        return negate ? -r : r
    }

    // Runs from `entry` until END. `ints` holds the four int uniforms (x, y, z in the low bytes); `bools` the 16 bool uniforms.
    func run(code: UnsafePointer<UInt32>, swizzles: UnsafePointer<UInt32>, uniforms: UnsafePointer<SIMD4<Float>>,
             bools: UInt32, ints: SIMD4<UInt32>, entry: Int) {
        address = .zero
        conditionX = false; conditionY = false
        var ifCount = 0, callCount = 0, loopCount = 0
        var pc = entry
        var budget = 1 << 16   // guards against runaway programs built from partially uploaded code

        @inline(__always) func read(_ register: Int, _ addressIndex: Int) -> SIMD4<Float> {
            if register < 0x20 { return file[register] }
            guard addressIndex != 0 else { return uniforms[register - 0x20] }
            let offset = Int(address[addressIndex - 1])
            let index = (register - 0x20 + (offset < -128 || offset > 127 ? 0 : offset)) & 0x7F
            return index >= 96 ? Self.one : uniforms[index]
        }
        @inline(__always) func write(_ destination: Int, _ value: SIMD4<Float>, mask: UInt32) {
            let slot = destination < 0x10 ? 32 + destination : destination
            if mask == 0xF { file[slot] = value; return }
            for i in 0..<4 where mask & (8 >> UInt32(i)) != 0 { file[slot][i] = value[i] }
        }
        @inline(__always) func test(_ hex: UInt32) -> Bool {
            let x = ((hex >> 25) & 1 != 0) == conditionX, y = ((hex >> 24) & 1 != 0) == conditionY
            switch (hex >> 22) & 3 { case 0: return x || y; case 1: return x && y; case 2: return x; default: return y }
        }
        func compare(_ op: UInt32, _ a: Float, _ b: Float) -> Bool {
            switch op { case 0: return a == b; case 1: return a != b; case 2: return a < b; case 3: return a <= b
            case 4: return a > b; case 5: return a >= b; default: return false }
        }

        while budget > 0 {
            budget -= 1
            let old = pc
            let hex = pc < Self.programLimit ? code[pc] : 0x22 << 26
            let op = Int(hex >> 26)
            var isBreak = false
            var done = false
            switch op {
            case 0x00...0x1F, 0x2E, 0x2F:
                let pattern = swizzles[Int(hex & 0x7F)]
                let inverted = op >= 0x18 && op <= 0x1B
                let index = Int((hex >> 19) & 3)
                let r1 = inverted ? Int((hex >> 14) & 0x1F) : Int((hex >> 12) & 0x7F)
                let r2 = inverted ? Int((hex >> 7) & 0x7F) : Int((hex >> 7) & 0x1F)
                let a = Self.swizzle(read(r1, inverted ? 0 : index), pattern, 5, negate: pattern & 0x10 != 0)
                let b = Self.swizzle(read(r2, inverted ? index : 0), pattern, 14, negate: pattern & 0x2000 != 0)
                let destination = Int((hex >> 21) & 0x1F), mask = pattern & 0xF
                switch op {
                case 0x00: write(destination, a + b, mask: mask)
                case 0x01: write(destination, SIMD4(repeating: a.x * b.x + a.y * b.y + a.z * b.z), mask: mask)
                case 0x02: write(destination, SIMD4(repeating: (a * b).sum()), mask: mask)
                case 0x03, 0x18:
                    write(destination, SIMD4(repeating: a.x * b.x + a.y * b.y + a.z * b.z + b.w), mask: mask)
                case 0x04, 0x19: write(destination, SIMD4(1, a.y * b.y, a.z, b.w), mask: mask)
                case 0x05: write(destination, SIMD4(repeating: exp2(a.x)), mask: mask)
                case 0x06: write(destination, SIMD4(repeating: log2(a.x)), mask: mask)
                case 0x07:
                    let power = a.z > 0 ? pow(max(a.y, 0), min(max(a.w, -128), 128)) : 0
                    write(destination, SIMD4(1, max(a.x, 0), a.x > 0 ? power : 0, 1), mask: mask)
                case 0x08: write(destination, Self.multiply(a, b), mask: mask)
                case 0x09, 0x1A: write(destination, SIMD4<Float>(repeating: 0).replacing(with: 1, where: a .>= b), mask: mask)
                case 0x0A, 0x1B: write(destination, SIMD4<Float>(repeating: 0).replacing(with: 1, where: a .< b), mask: mask)
                case 0x0B: write(destination, a.rounded(.down), mask: mask)
                case 0x0C: write(destination, b.replacing(with: a, where: a .> b), mask: mask)
                case 0x0D: write(destination, b.replacing(with: a, where: a .< b), mask: mask)
                case 0x0E: write(destination, SIMD4(repeating: 1 / a.x), mask: mask)
                case 0x0F: write(destination, SIMD4(repeating: 1 / a.x.squareRoot()), mask: mask)
                case 0x12:
                    if mask & 8 != 0 { address.x = Self.integer(a.x) }
                    if mask & 4 != 0 { address.y = Self.integer(a.y) }
                case 0x13: write(destination, a, mask: mask)
                case 0x2E, 0x2F:
                    conditionX = compare((hex >> 24) & 7, a.x, b.x); conditionY = compare((hex >> 21) & 7, a.y, b.y)
                default: break   // unassigned opcodes
                }
            case 0x30...0x3F:
                let pattern = swizzles[Int(hex & 0x1F)]
                let inverted = op < 0x38
                let index = Int((hex >> 22) & 3)
                let r1 = Int((hex >> 17) & 0x1F)
                let r2 = inverted ? Int((hex >> 12) & 0x1F) : Int((hex >> 10) & 0x7F)
                let r3 = inverted ? Int((hex >> 5) & 0x7F) : Int((hex >> 5) & 0x1F)
                let a = Self.swizzle(read(r1, 0), pattern, 5, negate: pattern & 0x10 != 0)
                let b = Self.swizzle(read(r2, inverted ? 0 : index), pattern, 14, negate: pattern & 0x2000 != 0)
                let c = Self.swizzle(read(r3, inverted ? index : 0), pattern, 23, negate: pattern & 0x400000 != 0)
                write(Int((hex >> 24) & 0x1F), Self.multiply(a, b) + c, mask: pattern & 0xF)
            case 0x22: done = true
            case 0x20: isBreak = true
            case 0x23: isBreak = test(hex)
            case 0x24, 0x25, 0x26:
                let taken = op == 0x24 || (op == 0x25 ? test(hex) : (bools >> ((hex >> 22) & 0xF)) & 1 != 0)
                if taken {
                    if callCount < 16 { callStack[callCount] = SIMD2(Int((hex >> 10) & 0xFFF) + Int(hex & 0xFF), pc + 1); callCount += 1 }
                    pc = Int((hex >> 10) & 0xFFF) - 1
                }
            case 0x27, 0x28:
                let taken = op == 0x28 ? test(hex) : (bools >> ((hex >> 22) & 0xF)) & 1 != 0
                let target = Int((hex >> 10) & 0xFFF)
                if taken {
                    if ifCount < 16 { ifStack[ifCount] = SIMD2(target, target + Int(hex & 0xFF)); ifCount += 1 }
                } else {
                    pc = target - 1
                }
            case 0x29:
                let parameters = ints[Int((hex >> 22) & 3)]
                let counter = Int(parameters & 0xFF), initial = Int32((parameters >> 8) & 0xFF), step = Int((parameters >> 16) & 0xFF)
                if loopCount < 16 {
                    loopStack[loopCount] = SIMD4(pc + 1, Int((hex >> 10) & 0xFFF) + 1, counter | step << 8, Int(address.z))
                    loopCount += 1
                }
                address.z = initial
            case 0x2C: if test(hex) { pc = Int((hex >> 10) & 0xFFF) - 1 }
            case 0x2D: if ((bools >> ((hex >> 22) & 0xF)) & 1 != 0) == ((hex & 1) == 0) { pc = Int((hex >> 10) & 0xFFF) - 1 }
            default: break // NOP, EMIT, SETEMIT
            }
            if done { return }
            pc += 1

            // Scopes close in the order CALL, IF, LOOP; a jump at the end of a scope is never taken.
            var next = old + 1
            for i in 0..<4 {
                guard callCount > 0, callStack[callCount - 1].x == next else { break }
                if i < 3 { pc = callStack[callCount - 1].y; next = pc }
                callCount -= 1
            }
            if ifCount > 0, ifStack[ifCount - 1].x == old + 1 {
                pc = ifStack[ifCount - 1].y
                ifCount -= 1
            }
            if loopCount > 0, loopStack[loopCount - 1].y == old + 1 || isBreak {
                var entryState = loopStack[loopCount - 1]
                address.z &+= Int32(entryState.z >> 8)
                if !isBreak, entryState.z & 0xFF != 0 {
                    entryState.z -= 1
                    loopStack[loopCount - 1] = entryState
                    pc = entryState.x
                } else {
                    pc = entryState.y
                    if loopCount > 1 { address.z = Int32(entryState.w) }
                    loopCount -= 1
                }
            }
        }
    }

    private static let programLimit = PICAShaderProgram.size - 1
}
