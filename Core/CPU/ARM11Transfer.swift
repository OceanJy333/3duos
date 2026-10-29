// input: decoded A32 single-data-transfer instruction and memory
// output: load/store effects or an explicit unsupported instruction
// pos: ARM11 interpreter memory operations

extension ARM11CPU {
    func transfer(_ op: UInt32, at address: UInt32, memory: ARMMemory) throws -> ARMStop {
        let registerOffset = op & (1 << 25) != 0
        let pre = op & (1 << 24) != 0
        let add = op & (1 << 23) != 0
        let byte = op & (1 << 22) != 0
        let writeback = op & (1 << 21) != 0 || !pre
        let load = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 15), rd = Int((op >> 12) & 15)
        // Unprivileged transfers and unpredictable base/destination combinations are not implemented.
        if (!pre && op & (1 << 21) != 0) || (writeback && rn == 15) ||
            (load && writeback && rn == rd) || (byte && rd == 15) ||
            (registerOffset && op & (1 << 4) != 0) {
            return .undefined(address, op)
        }
        let offset: UInt32
        if registerOffset {
            let rm = Int(op & 15)
            if rm == 15 { return .undefined(address, op) }
            offset = shift(operandRegister(rm, at: address), kind: Int((op >> 5) & 3),
                           amount: Int((op >> 7) & 31), immediate: true).0
        } else { offset = op & 0xFFF }
        let base = operandRegister(rn, at: address)
        let adjusted = add ? base &+ offset : base &- offset
        let location = pre ? adjusted : base
        if load {
            let value = byte ? UInt32(try memory.read8(location)) : try memory.read32(location)
            if writeback { registers[rn] = adjusted }
            if rd == 15 {
                cpsr = (cpsr & ~0x20) | ((value & 1) << 5)
                pc = value & (value & 1 == 0 ? ~UInt32(3) : ~UInt32(1))
            } else { registers[rd] = value; pc = address &+ 4 }
        } else {
            // On ARM11, storing r15 writes the instruction address + 12.
            let value = rd == 15 ? address &+ 12 : registers[rd]
            if byte { try memory.write8(location, UInt8(truncatingIfNeeded: value)) }
            else { try memory.write32(location, value) }
            if writeback { registers[rn] = adjusted }
            pc = address &+ 4
        }
        return .running
    }
}
