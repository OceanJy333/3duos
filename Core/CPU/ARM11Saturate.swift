// input: A32 SSAT and USAT instructions with an optional shifted source register
// output: the clamped value in Rd; the sticky Q flag is not modelled
// pos: ARM11 interpreter saturating arithmetic

extension ARM11CPU {
    func saturate(_ op: UInt32, at address: UInt32) -> ARMStop {
        let unsigned = op & (1 << 22) != 0
        let rd = Int((op >> 12) & 15), rn = Int(op & 15)
        if rd == 15 || rn == 15 { return .undefined(address, op) }
        let amount = Int((op >> 7) & 31), source = Int32(bitPattern: registers[rn])
        let shifted = op & 0x40 == 0 ? Int64(source) << amount : Int64(source >> (amount == 0 ? 31 : amount))
        let bits = Int((op >> 16) & 31) + (unsigned ? 0 : 1)
        let low: Int64 = unsigned ? 0 : -(Int64(1) << (bits - 1))
        let high: Int64 = unsigned ? (Int64(1) << bits) - 1 : (Int64(1) << (bits - 1)) - 1
        registers[rd] = UInt32(truncatingIfNeeded: min(max(shifted, low), high))
        pc = address &+ 4
        return .running
    }
}
