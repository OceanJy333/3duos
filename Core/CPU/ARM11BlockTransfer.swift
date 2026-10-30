// input: A32 LDM/STM instruction, CPU registers and memory
// output: sequential register transfers, writeback, or an unsupported instruction
// pos: ARM11 interpreter block transfer and stack instructions

extension ARM11CPU {
    func blockTransfer(_ op: UInt32, at instructionAddress: UInt32, memory: ARMMemory) throws -> ARMStop {
        let pre = op & (1 << 24) != 0
        let increment = op & (1 << 23) != 0
        let userRegisters = op & (1 << 22) != 0
        let writeback = op & (1 << 21) != 0
        let load = op & (1 << 20) != 0
        let baseRegister = Int((op >> 16) & 15)
        let list = op & 0xffff
        // Banked user registers and CPSR restore need CPU mode banking, not yet implemented.
        if userRegisters || baseRegister == 15 || list == 0 { return .undefined(instructionAddress, op) }
        let includesBase = list & (1 << baseRegister) != 0
        if writeback && includesBase {
            if load || list.trailingZeroBitCount != baseRegister { return .undefined(instructionAddress, op) }
        }
        let base = registers[baseRegister]
        let size = UInt32(list.nonzeroBitCount * 4)
        var address = increment ? base &+ (pre ? 4 : 0) : base &- size &+ (pre ? 0 : 4)
        var loadedPC: UInt32?
        for register in 0..<16 where list & (1 << register) != 0 {
            if load {
                let value = try guestRead32(memory, address)
                if register == 15 { loadedPC = value } else { registers[register] = value }
            } else {
                let value = register == 15 ? instructionAddress &+ 12 : registers[register]
                try guestWrite32(memory, address, value)
            }
            address = address &+ 4
        }
        if writeback { registers[baseRegister] = increment ? base &+ size : base &- size }
        if let target = loadedPC {
            cpsr = (cpsr & ~0x20) | ((target & 1) << 5)
            pc = target & (target & 1 == 0 ? ~UInt32(3) : ~UInt32(1))
        } else { pc = instructionAddress &+ 4 }
        return .running
    }
}
