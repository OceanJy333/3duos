// input: ARMv6K word LDREX/STREX instructions and a local memory interface
// output: word transfer and exclusive status, or alignment / memory fault
// pos: per-core exclusive monitor (shared-memory global monitoring is separate)

private enum ExclusiveFault: Error {
    case unaligned(UInt32)
}

extension ARM11CPU {
    func clearExclusiveMonitor() { exclusiveAddress = nil }

    func exclusiveTransfer(_ op: UInt32, at address: UInt32, memory: ARMMemory) throws -> ARMStop {
        let load = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 15), rd = Int((op >> 12) & 15), rm = Int(op & 15)
        if rn == 15 || rd == 15 || (!load && (rm == 15 || rd == rn || rd == rm)) {
            return .undefined(address, op)
        }
        let location = registers[rn]
        guard location & 3 == 0 else { throw ExclusiveFault.unaligned(location) }
        if load {
            let value = try memory.read32(location)
            registers[rd] = value
            exclusiveAddress = location
        } else {
            let success = exclusiveAddress == location
            if success { try memory.write32(location, registers[rm]) }
            registers[rd] = success ? 0 : 1
            clearExclusiveMonitor()
        }
        pc = address &+ 4
        return .running
    }
}
