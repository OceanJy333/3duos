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
            let low = try guestRead32(memory, location)
            if double {
                let high = try guestRead32(memory, location &+ 4)
                vfpSingles[first] = low; vfpSingles[first + 1] = high
            } else { vfpSingles[first] = low }
        } else {
            try guestWrite32(memory, location, vfpSingles[first])
            if double { try guestWrite32(memory, location &+ 4, vfpSingles[first + 1]) }
        }
        pc = address &+ 4
        return .running
    }
}

extension ARM11CPU {
    // FLDM/FSTM (including the PUSH and POP forms) on S or D registers.
    func vfpBlockTransfer(_ op: UInt32, at address: UInt32, memory: ARMMemory) throws -> ARMStop {
        let p = op & (1 << 24) != 0, u = op & (1 << 23) != 0, w = op & (1 << 21) != 0, load = op & (1 << 20) != 0
        let double = op & 0x100 != 0, d = Int((op >> 22) & 1)
        let rn = Int((op >> 16) & 15), vd = Int((op >> 12) & 15), words = Int(op & 255)
        guard fpexc & 0xC000_0000 == 0x4000_0000, p != u, !(double && (words & 1 != 0 || words > 32 || d != 0)),
              !double || vd * 2 + words <= 32, double || (vd << 1 | d) + words <= 32, rn != 15 || !w else {
            return .undefined(address, op)
        }
        let first = double ? vd * 2 : vd << 1 | d
        let bytes = UInt32(words * 4)
        let start = u ? registers[rn] : registers[rn] &- bytes
        for i in 0..<words {
            let location = start &+ UInt32(i * 4)
            if load { vfpSingles[first + i] = try guestRead32(memory, location) }
            else { try guestWrite32(memory, location, vfpSingles[first + i]) }
        }
        if w { registers[rn] = u ? start &+ bytes : start }
        pc = address &+ 4
        return .running
    }

    // FMRRS/FMSRR (two S registers) and FMRRD/FMDRR (one D register) against two ARM registers.
    func vfpPairTransfer(_ op: UInt32, at address: UInt32) -> ARMStop {
        let double = op & 0x100 != 0, load = op & (1 << 20) != 0
        let rt = Int((op >> 12) & 15), rt2 = Int((op >> 16) & 15), m = Int((op >> 5) & 1), vm = Int(op & 15)
        guard fpexc & 0xC000_0000 == 0x4000_0000, rt != 15, rt2 != 15, !double || m == 0,
              double || vm << 1 | m < 31, !load || rt != rt2 else { return .undefined(address, op) }
        let first = double ? vm * 2 : vm << 1 | m
        if load { registers[rt] = vfpSingles[first]; registers[rt2] = vfpSingles[first + 1] }
        else { vfpSingles[first] = registers[rt]; vfpSingles[first + 1] = registers[rt2] }
        pc = address &+ 4
        return .running
    }
}
