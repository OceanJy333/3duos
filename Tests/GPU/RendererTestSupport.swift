// input: nothing; helpers only.
// output: command-list builder, PICA bit encoders, independent tiled-buffer readers and a shader assembler.
// pos: shared support for the PICA renderer checks; written without using the code under test where a layout is verified.
import Foundation

var rendererAssertions = 0
func rcheck(_ condition: @autoclosure () -> Bool, _ description: String, line: UInt = #line) {
    rendererAssertions += 1
    if !condition() { fatalError("\(description) (RendererChecks line \(line))") }
}
func rclose(_ a: Int, _ b: Int, _ tolerance: Int, _ description: String, line: UInt = #line) {
    rcheck(abs(a - b) <= tolerance, "\(description): got \(a), expected \(b) +-\(tolerance)", line: line)
}

// Independent float24 encoder (1 sign, 7 exponent biased by 63, 16 mantissa bits).
func f24(_ value: Float) -> UInt32 {
    if value == 0 { return 0 }
    let bits = value.bitPattern
    let exponent = Int((bits >> 23) & 0xFF) - 127 + 63
    return (bits >> 31) << 23 | UInt32(exponent) << 16 | (bits >> 7) & 0xFFFF
}

// Three words holding four float24 values, w first.
func packUniform(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> [UInt32] {
    let (X, Y, Z, W) = (f24(x), f24(y), f24(z), f24(w))
    return [W << 8 | (Z >> 16) & 0xFF, (Z & 0xFFFF) << 16 | (Y >> 8) & 0xFFFF, (Y & 0xFF) << 24 | X]
}

struct CommandList {
    var words: [UInt32] = []
    mutating func write(_ register: Int, _ value: UInt32) {
        words += [value, UInt32(register) | 0xF << 16]
    }
    // The same register receives every value (shader program, swizzle and uniform uploads).
    mutating func upload(_ register: Int, _ values: [UInt32]) {
        words += [values[0], UInt32(register) | 0xF << 16 | UInt32(values.count - 1) << 20] + values.dropFirst()
        if words.count % 2 != 0 { words.append(0) }
    }
    // Consecutive registers starting at `register`.
    mutating func writeRange(_ register: Int, _ values: [UInt32]) {
        words += [values[0], UInt32(register) | 0xF << 16 | UInt32(values.count - 1) << 20 | 0x8000_0000] + values.dropFirst()
        if words.count % 2 != 0 { words.append(0) }
    }
}

// Pixel offset in an 8x8-tiled buffer using the classic lookup tables.
func tiledByteOffset(_ x: Int, _ y: Int, width: Int, bytes: Int) -> Int {
    let xlut = [0x00, 0x01, 0x04, 0x05, 0x10, 0x11, 0x14, 0x15], ylut = [0x00, 0x02, 0x08, 0x0A, 0x20, 0x22, 0x28, 0x2A]
    return (xlut[x % 8] + ylut[y % 8] + (x & ~7) * 8 + (y & ~7) * width) * bytes
}

// Shader assembler (3dbrew "Shader Instruction Set"); source registers: 0x00 input, 0x10 temporary, 0x20 uniform.
enum Asm {
    static let identity1: UInt32 = 0 << 11 | 1 << 9 | 2 << 7 | 3 << 5
    static let identity2: UInt32 = 0 << 20 | 1 << 18 | 2 << 16 | 3 << 14
    static func descriptor(mask: UInt32 = 0xF, negate1: Bool = false, src1: [UInt32] = [0, 1, 2, 3], src2: [UInt32] = [0, 1, 2, 3]) -> UInt32 {
        mask | (negate1 ? 0x10 : 0) | src1[0] << 11 | src1[1] << 9 | src1[2] << 7 | src1[3] << 5
            | src2[0] << 20 | src2[1] << 18 | src2[2] << 16 | src2[3] << 14 | 0 << 29 | 1 << 27 | 2 << 25 | 3 << 23
    }
    static func arith(_ op: UInt32, dest: UInt32, src1: UInt32, src2: UInt32 = 0, desc: UInt32 = 0, index: UInt32 = 0) -> UInt32 {
        op << 26 | dest << 21 | index << 19 | src1 << 12 | src2 << 7 | desc
    }
    static func mad(dest: UInt32, src1: UInt32, src2: UInt32, src3: UInt32, desc: UInt32) -> UInt32 {
        0x38 << 26 | dest << 24 | src1 << 17 | src2 << 10 | src3 << 5 | desc
    }
    static func flow(_ op: UInt32, target: UInt32 = 0, count: UInt32 = 0, selector: UInt32 = 0) -> UInt32 {
        op << 26 | selector << 22 | target << 10 | count
    }
    // cmp x/y comparison codes: 0 ==, 1 !=, 2 <, 3 <=, 4 >, 5 >=
    static func cmp(_ x: UInt32, _ y: UInt32, src1: UInt32, src2: UInt32, desc: UInt32) -> UInt32 {
        0x2E << 26 | x << 24 | y << 21 | src1 << 12 | src2 << 7 | desc
    }
    static let end: UInt32 = 0x22 << 26
}
