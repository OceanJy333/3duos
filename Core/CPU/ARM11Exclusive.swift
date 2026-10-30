// input: ARMv6K LDREX/STREX instructions (word, doubleword, byte, halfword) and a local memory interface
// output: transfer and exclusive status, or alignment / memory fault
// pos: per-core exclusive monitor (shared-memory global monitoring is separate)

private enum ExclusiveFault: Error {
    case unaligned(UInt32)
}

extension ARM11CPU {
    func clearExclusiveMonitor() { exclusiveAddress = nil }

    func exclusiveTransfer(_ op: UInt32, at address: UInt32, memory: ARMMemory) throws -> ARMStop {
        let load = op & (1 << 20) != 0
        let size = (op >> 21) & 3 // 0 word, 1 doubleword, 2 byte, 3 halfword
        let rn = Int((op >> 16) & 15), rd = Int((op >> 12) & 15), rm = Int(op & 15)
        let pair = size == 1
        if rn == 15 || rd == 15 || (!load && (rm == 15 || rd == rn || rd == rm)) ||
            (pair && (load ? rd & 1 != 0 || rd == 14 : rm & 1 != 0 || rm == 14 || rd == rm + 1 || rd == rn)) {
            return .undefined(address, op)
        }
        let location = registers[rn]
        guard location & (pair ? 7 : size == 3 ? 1 : size == 2 ? 0 : 3) == 0 else { throw ExclusiveFault.unaligned(location) }
        if load {
            switch size {
            case 1:
                registers[rd] = try guestRead32(memory, location)
                registers[rd + 1] = try guestRead32(memory, location &+ 4)
            case 2: registers[rd] = UInt32(try guestRead8(memory, location))
            case 3: registers[rd] = UInt32(try guestRead8(memory, location)) | UInt32(try guestRead8(memory, location &+ 1)) << 8
            default: registers[rd] = try guestRead32(memory, location)
            }
            exclusiveAddress = location
        } else {
            let success = exclusiveAddress == location
            if success {
                let value = registers[rm]
                switch size {
                case 1:
                    try guestWrite32(memory, location, value)
                    try guestWrite32(memory, location &+ 4, registers[rm + 1])
                case 2: try guestWrite8(memory, location, UInt8(truncatingIfNeeded: value))
                case 3:
                    try guestWrite8(memory, location, UInt8(truncatingIfNeeded: value))
                    try guestWrite8(memory, location &+ 1, UInt8(truncatingIfNeeded: value >> 8))
                default: try guestWrite32(memory, location, value)
                }
            }
            registers[rd] = success ? 0 : 1
            clearExclusiveMonitor()
        }
        pc = address &+ 4
        return .running
    }
}
