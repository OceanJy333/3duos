// input: handcrafted PICA command words and previous register values
// output: executable assertions for decoding, termination and malformed input
// pos: GPU decoder tests, run with swiftc alongside 3duos/Core/GPU/*.swift

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !condition() { fatalError(description) }
}
func header(_ register: UInt32, mask: UInt32 = 0xF, extra: UInt32 = 0, consecutive: Bool = false) -> UInt32 {
    register | (mask << 16) | (extra << 20) | (consecutive ? 0x8000_0000 : 0)
}

let single = PICACommandDecoder.decode([0xAABB_CCDD, header(0x107, mask: 0x5)])
check(single.stop == .exhausted && single.wordOffset == 2, "single command exhausted")
check(single.writes == [PICARegisterWrite(register: 0x107, value: 0xAABB_CCDD, byteMask: 5)], "single write")
check(single.writes[0].applying(to: 0x1122_3344) == 0x11BB_33DD, "byte mask 0101")
check(PICARegisterWrite(register: 0, value: 0xFFFF_FFFF, byteMask: 0).applying(to: 0x1234_5678) == 0x1234_5678, "zero mask")
check(PICARegisterWrite(register: 0, value: 0xFFFF_FFFF, byteMask: 15).applying(to: 0) == 0xFFFF_FFFF, "full mask")

// Format example: https://www.3dbrew.org/wiki/GPU/Internal_Registers
let consecutive = PICACommandDecoder.decode([0xAAAA_AAAA, 0x802F_011C, 0xBBBB_BBBB, 0xCCCC_CCCC])
check(consecutive.writes.map(\.register) == [0x11C, 0x11D, 0x11E], "consecutive registers")
check(consecutive.writes.map(\.value) == [0xAAAA_AAAA, 0xBBBB_BBBB, 0xCCCC_CCCC], "consecutive values")
let repeated = PICACommandDecoder.decode([1, header(0x220, extra: 1), 2, 0xDEAD_BEEF, 3, header(0x221)])
check(repeated.writes.map(\.register) == [0x220, 0x220, 0x221], "same-register writes and next aligned command")
check(repeated.writes.map(\.value) == [1, 2, 3] && repeated.wordOffset == 6, "padding ignored")

let final = PICACommandDecoder.decode([9, header(0xF, extra: 2, consecutive: true), 10, 11, 12, header(0x33)])
check(final.stop == .finalized && final.wordOffset == 4, "finalize stops after complete command")
check(final.writes.map(\.register) == [0xF, 0x10] && final.writes.map(\.value) == [9, 10], "finalize ignores following writes")
check(PICACommandDecoder.decode([]).stop == .exhausted, "empty buffer")
check(PICACommandDecoder.decode([7]).stop == .truncatedHeader(wordOffset: 0), "missing header")
let missing = PICACommandDecoder.decode([7, header(0x33, extra: 2), 8])
check(missing.stop == .truncatedParameters(wordOffset: 0, expectedWords: 4, availableWords: 3) && missing.writes.isEmpty, "missing parameter is atomic")
check(PICACommandDecoder.decode([7, header(0x33, extra: 1), 8]).stop == .truncatedPadding(wordOffset: 0), "missing alignment word")
let partial = PICACommandDecoder.decode([1, header(0x100), 2])
check(partial.writes.count == 1 && partial.wordOffset == 2 && partial.stop == .truncatedHeader(wordOffset: 2), "earlier complete command retained")
check(PICACommandDecoder.decode([1, header(0xFFFF, extra: 1, consecutive: true), 2, 0]).stop == .registerOverflow(wordOffset: 0), "register overflow")
let maximum = PICACommandDecoder.decode([0, header(0x200, extra: 255)] + Array(1...255).map(UInt32.init) + [0])
check(maximum.stop == .exhausted && maximum.writes.count == 256 && maximum.writes.last?.value == 255, "maximum parameter count and padding")
let lastRegister = PICACommandDecoder.decode([1, header(0xFFFE, extra: 1, consecutive: true), 2, 0])
check(lastRegister.writes.map(\.register) == [0xFFFE, 0xFFFF], "last valid consecutive register")
print("PICA command decoder: \(assertions) assertions passed")

// The bridge deliberately supplies a fixed Metal passthrough shader rather
// than executing PICA shader code. The memory reader uses physical addresses.
let xy: [Float] = [9, 9, -0.8, -0.7, 0.7, -0.6, -0.4, 0.8]
let memory = xy.flatMap { value -> [UInt8] in
    (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
}
let physicalBase: UInt64 = 0x1800_0000
func readMemory(_ address: UInt64, _ count: Int) -> [UInt8]? {
    guard address >= physicalBase, address - physicalBase <= UInt64(memory.count) else { return nil }
    let start = Int(address - physicalBase)
    guard count <= memory.count - start else { return nil }
    return Array(memory[start..<(start + count)])
}
func write(_ register: UInt32, _ value: UInt32, mask: UInt32 = 15) -> [UInt32] {
    [value, header(register, mask: mask)]
}
let commands = write(0x200, UInt32(physicalBase >> 3))
    + write(0x201, 7) // float, two components
    + write(0x202, 0) + write(0x203, 0) + write(0x204, 0)
    + write(0x205, (1 << 28) | (8 << 16))
    + write(0x228, 3) + write(0x22A, 1)
    + write(0x25E, 0) + write(0x22E, 1)
let decoded = PICACommandDecoder.decode(commands)
check(decoded.stop == .exhausted, "synthetic command stream decodes")
var gpu = PICASyntheticDraw()
let draws = try gpu.execute(decoded.writes, read: readMemory)
check(draws.count == 1 && draws[0] == [PICAPosition(x: -0.8, y: -0.7), PICAPosition(x: 0.7, y: -0.6), PICAPosition(x: -0.4, y: 0.8)], "draw fetches vertex offset and float2 buffer")
let masked = PICACommandDecoder.decode(write(0x228, 0x100, mask: 2) + write(0x22E, 1, mask: 0))
let maskedDraws = try gpu.execute(masked.writes, read: readMemory)
check(maskedDraws.isEmpty, "masked trigger does not draw")
check(gpu[0x228] == 0x103, "masked register update preserves other bytes")
var unsupported = PICASyntheticDraw()
let invalid = PICACommandDecoder.decode(commands + write(0x25E, 0x100) + write(0x22E, 1))
do {
    _ = try unsupported.execute(invalid.writes, read: readMemory)
    fatalError("unsupported primitive accepted")
} catch PICASyntheticDrawError.unsupportedConfiguration { check(true, "unsupported primitive rejected") }
do {
    var missingGPU = PICASyntheticDraw()
    _ = try missingGPU.execute(decoded.writes, read: { _, _ in nil })
    fatalError("missing vertex memory accepted")
} catch PICASyntheticDrawError.vertexDataUnavailable { check(true, "missing memory rejected") }

let pixels = try PICASyntheticMetal.render(draws[0], width: 64, height: 64)
func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 4]) }
check(pixel(20, 35) == [255, 0, 0, 255], "triangle interior red")
check(pixel(55, 5) == [0, 0, 0, 255] && pixel(60, 50) == [0, 0, 0, 255], "outside remains black")
check(pixel(20, 15) == [255, 0, 0, 255] && pixel(50, 15) == [0, 0, 0, 255], "asymmetric triangle orientation")
print("Synthetic command-to-Metal geometry: \(assertions - 19) assertions passed")
