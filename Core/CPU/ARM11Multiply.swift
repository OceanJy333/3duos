// input: A32 multiply, long multiply, halfword multiply, CLZ, byte-reverse and sign/zero-extend instructions
// output: register results with N/Z flags where the S bit asks for them, or an unsupported-instruction stop
// pos: ARM11 ARMv6 integer multiply and media arithmetic, separate from the barrel-shifter data path

extension ARM11CPU {
    private func finish(_ address: UInt32) -> ARMStop {
        pc = address &+ 4
        return .running
    }

    private func setNZ(_ value: UInt32) {
        setFlag(0x8000_0000, value & 0x8000_0000 != 0)
        setFlag(0x4000_0000, value == 0)
    }

    private func half(_ value: UInt32, top: Bool) -> Int32 {
        Int32(Int16(truncatingIfNeeded: top ? value >> 16 : value))
    }

    // MUL, MLA, UMAAL, UMULL, UMLAL, SMULL, SMLAL. Operands never include PC.
    func multiply(_ op: UInt32, at address: UInt32) -> ARMStop {
        let setFlags = op & (1 << 20) != 0, accumulate = op & (1 << 21) != 0
        let hi = Int((op >> 16) & 15), lo = Int((op >> 12) & 15), rs = Int((op >> 8) & 15), rm = Int(op & 15)
        guard hi != 15, lo != 15, rs != 15, rm != 15 else { return .undefined(address, op) }
        if op & 0x0FC0_00F0 == 0x0000_0090 {
            let product = registers[rm] &* registers[rs]
            registers[hi] = accumulate ? product &+ registers[lo] : product
            if setFlags { setNZ(registers[hi]) }
            return finish(address)
        }
        guard op & 0x0F80_00F0 == 0x0080_0090, hi != lo else { return .undefined(address, op) }
        let signed = op & (1 << 22) != 0
        if op & 0x0FF0_00F0 == 0x0040_0090 { // UMAAL
            let sum = UInt64(registers[rm]) * UInt64(registers[rs]) + UInt64(registers[hi]) + UInt64(registers[lo])
            registers[lo] = UInt32(truncatingIfNeeded: sum); registers[hi] = UInt32(truncatingIfNeeded: sum >> 32)
            return finish(address)
        }
        var result: UInt64
        if signed {
            result = UInt64(bitPattern: Int64(Int32(bitPattern: registers[rm])) * Int64(Int32(bitPattern: registers[rs])))
        } else {
            result = UInt64(registers[rm]) * UInt64(registers[rs])
        }
        if accumulate { result = result &+ (UInt64(registers[hi]) << 32 | UInt64(registers[lo])) }
        registers[lo] = UInt32(truncatingIfNeeded: result)
        registers[hi] = UInt32(truncatingIfNeeded: result >> 32)
        if setFlags {
            setFlag(0x8000_0000, result >> 63 != 0)
            setFlag(0x4000_0000, result == 0)
        }
        return finish(address)
    }

    // SMLA<x><y>, SMLAW<y>, SMULW<y>, SMLAL<x><y>, SMUL<x><y>.
    func halfwordMultiply(_ op: UInt32, at address: UInt32) -> ARMStop {
        let rd = Int((op >> 16) & 15), rn = Int((op >> 12) & 15), rs = Int((op >> 8) & 15), rm = Int(op & 15)
        let x = op & 0x20 != 0, y = op & 0x40 != 0, kind = (op >> 21) & 3
        guard rd != 15, rs != 15, rm != 15, kind == 3 || rn != 15 else { return .undefined(address, op) }
        func addOverflow(_ a: Int32, _ b: Int32) -> UInt32 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            if overflow { setFlag(0x0800_0000, true) }
            return UInt32(bitPattern: sum)
        }
        switch kind {
        case 0:
            registers[rd] = addOverflow(half(registers[rm], top: x) * half(registers[rs], top: y), Int32(bitPattern: registers[rn]))
        case 1:
            let product = Int64(Int32(bitPattern: registers[rm])) * Int64(half(registers[rs], top: y)) >> 16
            registers[rd] = op & 0x20 == 0 ? addOverflow(Int32(truncatingIfNeeded: product), Int32(bitPattern: registers[rn]))
                                           : UInt32(truncatingIfNeeded: product)
        case 2:
            guard rn != rd else { return .undefined(address, op) }
            let sum = Int64(bitPattern: UInt64(registers[rd]) << 32 | UInt64(registers[rn]))
                &+ Int64(half(registers[rm], top: x) * half(registers[rs], top: y))
            registers[rn] = UInt32(truncatingIfNeeded: sum); registers[rd] = UInt32(truncatingIfNeeded: sum >> 32)
        default:
            registers[rd] = UInt32(bitPattern: half(registers[rm], top: x) * half(registers[rs], top: y))
        }
        return finish(address)
    }

    // CLZ, REV, REV16, REVSH, RBIT.
    func countOrReverse(_ op: UInt32, at address: UInt32) -> ARMStop {
        let rd = Int((op >> 12) & 15), rm = Int(op & 15)
        guard rd != 15, rm != 15 else { return .undefined(address, op) }
        let value = registers[rm]
        switch op & 0x0FFF_0FF0 {
        case 0x016F_0F10: registers[rd] = UInt32(value.leadingZeroBitCount)
        case 0x06BF_0F30: registers[rd] = value.byteSwapped
        case 0x06BF_0FB0: registers[rd] = (value & 0x00FF_00FF) << 8 | (value >> 8) & 0x00FF_00FF
        case 0x06FF_0FB0: registers[rd] = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value.byteSwapped >> 16)))
        case 0x06FF_0F30:
            var reversed: UInt32 = 0
            for bit in 0..<32 where value & (1 << bit) != 0 { reversed |= 1 << (31 - bit) }
            registers[rd] = reversed
        default: return .undefined(address, op)
        }
        return finish(address)
    }

    // SXTB/SXTH/UXTB/UXTH and the accumulating SXTAB/SXTAH/UXTAB/UXTAH forms.
    func extend(_ op: UInt32, at address: UInt32) -> ARMStop {
        let rn = Int((op >> 16) & 15), rd = Int((op >> 12) & 15), rm = Int(op & 15)
        guard rd != 15, rm != 15 else { return .undefined(address, op) }
        let rotated = shift(registers[rm], kind: 3, amount: Int((op >> 10) & 3) * 8, immediate: false).0
        let extended: UInt32
        switch (op >> 20) & 7 {
        case 2: extended = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: rotated)))
        case 3: extended = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: rotated)))
        case 6: extended = rotated & 0xFF
        case 7: extended = rotated & 0xFFFF
        default: return .undefined(address, op)
        }
        registers[rd] = rn == 15 ? extended : registers[rn] &+ extended
        return finish(address)
    }
}
