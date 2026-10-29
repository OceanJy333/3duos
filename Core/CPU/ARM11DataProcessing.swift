// input: A32 data-processing instruction and current CPU flags
// output: register and CPSR updates or an unsupported-instruction stop
// pos: ARM11 interpreter arithmetic, logic, and barrel shifter

extension ARM11CPU {
    func dataProcessing(_ op: UInt32, at address: UInt32) -> ARMStop {
        let immediate = op & (1 << 25) != 0
        let opcode = Int((op >> 21) & 15)
        let setFlags = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 15), rd = Int((op >> 12) & 15)
        let test = (8...11).contains(opcode)
        // Exclude multiply, miscellaneous instructions, flag-restoring PC writes,
        // and encodings whose PC semantics need a different execution path.
        if (test && (!setFlags || rd != 0)) || (!test && setFlags && rd == 15) ||
            (!immediate && op & 0x90 == 0x90) {
            return .undefined(address, op)
        }
        let rhs: UInt32, shifterCarry: Bool
        if immediate {
            let value = op & 255, rotation = Int((op >> 8) & 15) * 2
            (rhs, shifterCarry) = shift(value, kind: 3, amount: rotation, immediate: false)
        } else {
            let rm = Int(op & 15)
            let byRegister = op & 0x10 != 0
            let rs = Int((op >> 8) & 15)
            if byRegister && (rs == 15 || rm == 15 || rn == 15 || op & 0x80 != 0) {
                return .undefined(address, op)
            }
            let amount = byRegister ? Int(registers[rs] & 255) : Int((op >> 7) & 31)
            (rhs, shifterCarry) = shift(operandRegister(rm, at: address),
                                        kind: Int((op >> 5) & 3), amount: amount,
                                        immediate: !byRegister)
        }
        let lhs = operandRegister(rn, at: address)
        var result: UInt32 = 0
        var arithmetic: (UInt32, Bool, Bool)?
        switch opcode {
        case 0, 8: result = lhs & rhs
        case 1, 9: result = lhs ^ rhs
        case 2, 10: arithmetic = addWithCarry(lhs, ~rhs, true)
        case 3: arithmetic = addWithCarry(rhs, ~lhs, true)
        case 4, 11: arithmetic = addWithCarry(lhs, rhs, false)
        case 5: arithmetic = addWithCarry(lhs, rhs, c)
        case 6: arithmetic = addWithCarry(lhs, ~rhs, c)
        case 7: arithmetic = addWithCarry(rhs, ~lhs, c)
        case 12: result = lhs | rhs
        case 13: result = rhs
        case 14: result = lhs & ~rhs
        case 15: result = ~rhs
        default: break
        }
        if let arithmetic { result = arithmetic.0 }
        if setFlags {
            setFlag(0x8000_0000, result & 0x8000_0000 != 0)
            setFlag(0x4000_0000, result == 0)
            setFlag(0x2000_0000, arithmetic?.1 ?? shifterCarry)
            if let arithmetic { setFlag(0x1000_0000, arithmetic.2) }
        }
        if !test && rd == 15 { pc = result & ~UInt32(3) }
        else {
            if !test { registers[rd] = result }
            pc = address &+ 4
        }
        return .running
    }

    private func addWithCarry(_ x: UInt32, _ y: UInt32, _ carry: Bool) -> (UInt32, Bool, Bool) {
        let wide = UInt64(x) + UInt64(y) + (carry ? 1 : 0)
        let result = UInt32(truncatingIfNeeded: wide)
        let overflow = (~(x ^ y) & (x ^ result) & 0x8000_0000) != 0
        return (result, wide > UInt64(UInt32.max), overflow)
    }

    func shift(_ value: UInt32, kind: Int, amount: Int, immediate: Bool) -> (UInt32, Bool) {
        if amount == 0 {
            if !immediate || kind == 0 { return (value, c) }
            if kind == 3 { return ((c ? 0x8000_0000 : 0) | (value >> 1), value & 1 != 0) }
            return shift(value, kind: kind, amount: 32, immediate: false)
        }
        switch kind {
        case 0:
            if amount < 32 { return (value << amount, (value >> (32 - amount)) & 1 != 0) }
            return (0, amount == 32 && value & 1 != 0)
        case 1:
            if amount < 32 { return (value >> amount, (value >> (amount - 1)) & 1 != 0) }
            return (0, amount == 32 && value & 0x8000_0000 != 0)
        case 2:
            let sign = value & 0x8000_0000 != 0
            if amount >= 32 { return (sign ? UInt32.max : 0, sign) }
            return (UInt32(bitPattern: Int32(bitPattern: value) >> amount), (value >> (amount - 1)) & 1 != 0)
        default:
            let rotation = amount % 32
            if rotation == 0 { return (value, value & 0x8000_0000 != 0) }
            let result = (value >> rotation) | (value << (32 - rotation))
            return (result, result & 0x8000_0000 != 0)
        }
    }
}
