// input: ARMv6 addressing mode 3 instruction and little-endian memory
// output: halfword, signed byte, or doubleword transfer and optional writeback
// pos: ARM11 interpreter miscellaneous memory operations

private enum MiscellaneousTransferFault: Error { case unaligned(UInt32) }

extension ARM11CPU {
    func miscellaneousTransfer(_ op: UInt32, at address: UInt32, memory: ARMMemory) throws -> ARMStop {
        let pre = op & (1 << 24) != 0, add = op & (1 << 23) != 0
        let immediate = op & (1 << 22) != 0, w = op & (1 << 21) != 0
        let loadBit = op & (1 << 20) != 0, kind = Int((op >> 5) & 3)
        let rn = Int((op >> 16) & 15), rd = Int((op >> 12) & 15), rm = Int(op & 15)
        let writeback = !pre || w, doubleword = !loadBit && kind != 1
        let load = loadBit || kind == 2
        if (!pre && w) || rd == 15 || (writeback && (rn == 15 || rn == rd || (doubleword && rn == rd + 1))) ||
            (!immediate && (op & 0xF00 != 0 || rm == 15 || (doubleword && load && (rm == rd || rm == rd + 1)))) ||
            (doubleword && (rd & 1 != 0 || rd == 14)) {
            return .undefined(address, op)
        }
        let offset = immediate ? ((op >> 4) & 0xF0) | (op & 15) : registers[rm]
        let base = operandRegister(rn, at: address)
        let adjusted = add ? base &+ offset : base &- offset
        let location = pre ? adjusted : base
        if doubleword {
            guard location & 3 == 0 else { throw MiscellaneousTransferFault.unaligned(location) }
            if load {
                let first = try memory.read32(location), second = try memory.read32(location &+ 4)
                registers[rd] = first; registers[rd + 1] = second
            } else {
                try memory.write32(location, registers[rd])
                try memory.write32(location &+ 4, registers[rd + 1])
            }
        } else if load {
            let low = UInt32(try memory.read8(location))
            if kind == 2 {
                registers[rd] = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(low))))
            } else {
                let high = UInt32(try memory.read8(location &+ 1))
                let value = low | (high << 8)
                registers[rd] = kind == 3 ? UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(value)))) : value
            }
        } else {
            try memory.write8(location, UInt8(truncatingIfNeeded: registers[rd]))
            try memory.write8(location &+ 1, UInt8(truncatingIfNeeded: registers[rd] >> 8))
        }
        if writeback { registers[rn] = adjusted }
        pc = address &+ 4
        return .running
    }
}
