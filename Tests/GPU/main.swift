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

rendererShaderChecks()
rendererDrawChecks()
rendererMotionChecks()
print("PICA renderer: \(rendererAssertions) assertions passed")
