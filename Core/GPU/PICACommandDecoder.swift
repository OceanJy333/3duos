// input: PICA command buffer as little-endian 32-bit words
// output: ordered register write events and a termination reason
// pos: standalone GPU command-list decoder, before register execution

struct PICARegisterWrite: Equatable {
    let register: UInt16
    let value: UInt32
    let byteMask: UInt8

    func applying(to previous: UInt32) -> UInt32 {
        var bits: UInt32 = 0
        for byte in 0..<4 where byteMask & (1 << byte) != 0 {
            bits |= UInt32(0xFF) << (byte * 8)
        }
        return (previous & ~bits) | (value & bits)
    }
}

enum PICACommandStop: Equatable {
    case exhausted
    case finalized
    case truncatedHeader(wordOffset: Int)
    case truncatedParameters(wordOffset: Int, expectedWords: Int, availableWords: Int)
    case truncatedPadding(wordOffset: Int)
    case registerOverflow(wordOffset: Int)
}

struct PICACommandResult {
    let writes: [PICARegisterWrite]
    let stop: PICACommandStop
    // Index of the next command, or the start of the incomplete command on error.
    let wordOffset: Int
}

enum PICACommandDecoder {
    // A command is validated completely before its events are emitted. The caller
    // supplies the actual buffer length; hardware buffer-size alignment is separate.
    static func decode(_ words: [UInt32]) -> PICACommandResult {
        var writes: [PICARegisterWrite] = []
        var offset = 0
        func result(_ stop: PICACommandStop) -> PICACommandResult {
            PICACommandResult(writes: writes, stop: stop, wordOffset: offset)
        }

        while offset < words.count {
            let available = words.count - offset
            guard available >= 2 else { return result(.truncatedHeader(wordOffset: offset)) }
            let header = words[offset + 1]
            let firstRegister = UInt16(truncatingIfNeeded: header)
            let mask = UInt8((header >> 16) & 0xF)
            let extra = Int((header >> 20) & 0xFF)
            let consecutive = header & 0x8000_0000 != 0
            let payloadWords = 2 + extra
            guard available >= payloadWords else {
                return result(.truncatedParameters(wordOffset: offset, expectedWords: payloadWords, availableWords: available))
            }
            let totalWords = payloadWords + (payloadWords & 1)
            guard available >= totalWords else { return result(.truncatedPadding(wordOffset: offset)) }
            guard !consecutive || Int(firstRegister) + extra <= Int(UInt16.max) else {
                return result(.registerOverflow(wordOffset: offset))
            }

            for parameter in 0...extra {
                let register = firstRegister + UInt16(consecutive ? parameter : 0)
                let value = words[offset + (parameter == 0 ? 0 : parameter + 1)]
                writes.append(PICARegisterWrite(register: register, value: value, byteMask: mask))
                if register == 0x10 {
                    offset += totalWords
                    return result(.finalized)
                }
            }
            offset += totalWords
        }
        return result(.exhausted)
    }
}
