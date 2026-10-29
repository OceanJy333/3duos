// input: VFPv2 single-register load/store instruction and little-endian memory
// output: bit-preserving transfer between memory and aliased VFP registers
// pos: ARM11 VFP11 load/store one register, immediate offset

extension ARM11CPU {
    func vfpMemoryTransfer(_ op: UInt32, at address: UInt32, memory: ARMMemory) throws -> ARMStop {
        let double = op & 0x100 != 0, d = Int((op >> 22) & 1)
        guard fpexc & 0xC000_0000 == 0x4000_0000, !double || d == 0 else {
            return .undefined(address, op)
        }
        let rn = Int((op >> 16) & 15), vd = Int((op >> 12) & 15)
        let first = double ? vd * 2 : vd * 2 + d
        let base = operandRegister(rn, at: address), offset = (op & 255) << 2
        let location = op & (1 << 23) != 0 ? base &+ offset : base &- offset
        if op & (1 << 20) != 0 {
            let low = try memory.read32(location)
            if double {
                let high = try memory.read32(location &+ 4)
                vfpSingles[first] = low; vfpSingles[first + 1] = high
            } else { vfpSingles[first] = low }
        } else {
            try memory.write32(location, vfpSingles[first])
            if double { try memory.write32(location &+ 4, vfpSingles[first + 1]) }
        }
        pc = address &+ 4
        return .running
    }
}
