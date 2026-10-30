// input: one A32 instruction word and the address it was fetched from.
// output: an ARMDecodedOp with condition, operands and shifts resolved, or `.generic` for the full decoder.
// pos: decode stage of the ARM11 interpreter; ARM11Run executes the result and caches it per page.

enum ARMOpKind: UInt8 {
    case undecoded, generic
    case dataImmediate, dataRegister   // rhs is a rotated immediate / a register shifted by an immediate
    case branch, branchExchange        // imm = absolute target / rm = target; flags bit 0 = link
    case load, store                   // word or byte; imm offset or register offset
    case halfword                      // LDRH/STRH/LDRSB/LDRSH/LDRD/STRD with immediate offset
    case loadMultiple, storeMultiple   // imm = register list
    case multiply                      // MUL/MLA; shift holds Rs
    case vfpArithmetic                 // single-precision FMAC...FDIV; flags = operation code
    case vfpTransfer                   // FLDS/FSTS/FLDD/FSTD; rd = first S register
    case vfpMultiple                   // FLDM/FSTM; rd = first S register, imm = word count
    case vfpData, vfpBlock             // other VFP data processing / FLDM, FSTM: dispatched straight to their handlers
}

extension ARM11CPU {
    static let conditionMasks: [UInt16] = (0..<16).map { condition in
        (0..<16).reduce(UInt16(0)) { mask, nzcv in
            let n = nzcv & 8 != 0, z = nzcv & 4 != 0, c = nzcv & 2 != 0, v = nzcv & 1 != 0
            let passed: Bool
            switch condition {
            case 0: passed = z
            case 1: passed = !z
            case 2: passed = c
            case 3: passed = !c
            case 4: passed = n
            case 5: passed = !n
            case 6: passed = v
            case 7: passed = !v
            case 8: passed = c && !z
            case 9: passed = !c || z
            case 10: passed = n == v
            case 11: passed = n != v
            case 12: passed = !z && n == v
            case 13: passed = z || n != v
            default: passed = true
            }
            return passed ? mask | 1 << nzcv : mask
        }
    }

    // Each fast form mirrors the order and exclusions of `execute`; anything else keeps `.generic`.
    static func decode(_ op: UInt32, at address: UInt32) -> ARMDecodedOp {
        let generic = ARMDecodedOp(raw: op, kind: .generic)
        let condition = Int(op >> 28)
        guard condition != 15 else { return generic }   // CLREX, PLD and undefined stay on the full decoder
        let rd = UInt8((op >> 12) & 15), rn = UInt8((op >> 16) & 15), rm = UInt8(op & 15)
        var d = generic
        d.condMask = conditionMasks[condition]
        d.rd = rd; d.rn = rn; d.rm = rm
        let pre = op & (1 << 24) != 0, add = op & (1 << 23) != 0, w = op & (1 << 21) != 0, load = op & (1 << 20) != 0
        let writeback = w || !pre
        switch (op >> 25) & 7 {
        case 0 where op & 0x90 != 0x90 && op & 0x0190_0000 != 0x0100_0000,
             1 where op & 0x0190_0000 != 0x0100_0000:
            let opcode = (op >> 21) & 15, setFlags = op & (1 << 20) != 0, test = (8...11).contains(opcode)
            if test && (!setFlags || rd != 0) || !test && setFlags && rd == 15 { return generic }
            if opcode != 13 && opcode != 15 && rn == 15 { return generic }
            d.flags = UInt8(opcode) | (setFlags ? ARMDecodedOp.setFlags : 0)
            if op & (1 << 25) != 0 {
                let value = op & 255, amount = ((op >> 8) & 15) * 2
                d.kind = .dataImmediate
                d.imm = amount == 0 ? value : value >> amount | value << (32 - amount)
                d.shift = amount == 0 ? 0 : 1
            } else {
                if op & 0x10 != 0 || rm == 15 { return generic }
                d.kind = .dataRegister
                d.shift = UInt8((op >> 5) & 3) << 5 | UInt8((op >> 7) & 31)
            }
            return d
        case 0 where op & 0x0FC0_00F0 == 0x0000_0090: // MUL, MLA
            if rd == 15 || rn == 15 || rm == 15 || (op >> 8) & 15 == 15 { return generic }
            d.kind = .multiply
            d.shift = UInt8((op >> 8) & 15)
            d.flags = (op & (1 << 20) != 0 ? ARMDecodedOp.setFlags : 0) | (op & (1 << 21) != 0 ? ARMDecodedOp.accumulate : 0)
            return d
        case 0 where op & 0x90 == 0x90 && op & 0x60 != 0 && op & (1 << 22) != 0: // addressing mode 3, immediate
            let kind = (op >> 5) & 3, doubleword = !load && kind != 1
            if (!pre && w) || rd == 15 || (writeback && (rn == 15 || rn == rd || (doubleword && rn == rd + 1))) ||
                (doubleword && (rd & 1 != 0 || rd == 14)) { return generic }
            let offset = ((op >> 4) & 0xF0) | (op & 15)
            d.kind = .halfword
            d.shift = UInt8(kind) | (load ? 4 : 0)
            setAddressing(&d, offset: offset, add: add, pre: pre, writeback: writeback, at: address)
            return d
        case 2, 3:
            if op & (1 << 25) != 0 && op & 0x10 != 0 { return generic }
            let byte = op & (1 << 22) != 0, registerOffset = op & (1 << 25) != 0
            if (!pre && w) || (writeback && rn == 15) || (load && writeback && rn == rd) || (byte && rd == 15) { return generic }
            if registerOffset && (rm == 15 || rn == 15) { return generic }
            d.kind = load ? .load : .store
            if registerOffset {
                d.shift = UInt8((op >> 5) & 3) << 5 | UInt8((op >> 7) & 31)
                d.flags = ARMDecodedOp.registerOffset | (add ? 0 : ARMDecodedOp.subtract)
                d.flags |= (pre ? ARMDecodedOp.preIndexed : 0) | (writeback ? ARMDecodedOp.writeback : 0)
            } else {
                setAddressing(&d, offset: op & 0xFFF, add: add, pre: pre, writeback: writeback, at: address)
            }
            if byte { d.flags |= ARMDecodedOp.byte }
            return d
        case 4:
            let list = op & 0xFFFF
            if op & (1 << 22) != 0 || rn == 15 || list == 0 { return generic }
            if w && list & (1 << UInt32(rn)) != 0 && (load || list.trailingZeroBitCount != Int(rn)) { return generic }
            d.kind = load ? .loadMultiple : .storeMultiple
            d.imm = list
            d.flags = (add ? ARMDecodedOp.increment : 0) | (pre ? ARMDecodedOp.before : 0) | (w ? ARMDecodedOp.writeback : 0)
            return d
        case 5:
            let signed = Int32(bitPattern: (op & 0x00FF_FFFF) << 8) >> 6
            d.kind = .branch
            d.imm = address &+ 8 &+ UInt32(bitPattern: signed)
            d.flags = op & 0x0100_0000 != 0 ? 1 : 0
            return d
        case 6 where op & 0x0FE0_0E00 != 0x0C40_0A00:
            if op & 0x0F20_0E00 == 0x0D00_0A00 {
                let double = op & 0x100 != 0, dBit = UInt8((op >> 22) & 1)
                if double && dBit != 0 { return generic }
                d.kind = .vfpTransfer
                d.rd = double ? rd * 2 : rd * 2 + dBit
                d.flags = (load ? ARMDecodedOp.vfpLoad : 0) | (double ? ARMDecodedOp.vfpDouble : 0)
                d.imm = add ? (op & 255) << 2 : 0 &- ((op & 255) << 2)
                if rn == 15 { d.flags |= ARMDecodedOp.absolute; d.imm = address &+ 8 &+ d.imm }
                return d
            }
            if op & 0x0E00_0E00 == 0x0C00_0A00 && op & 0x0120_0000 != 0x0100_0000 {
                // Same validity rules as vfpBlockTransfer; anything it rejects goes to it directly.
                let double = op & 0x100 != 0, dBit = (op >> 22) & 1, vd = (op >> 12) & 15, words = op & 255
                let first = double ? vd * 2 : vd << 1 | dBit
                d.kind = .vfpBlock
                guard pre != add, rn != 15, !(double && (words & 1 != 0 || words > 32 || dBit != 0)), first + words <= 32 else { return d }
                d.kind = .vfpMultiple
                d.rd = UInt8(first)
                d.imm = words
                d.flags = (load ? ARMDecodedOp.vfpLoad : 0) | (add ? ARMDecodedOp.increment : 0) | (w ? ARMDecodedOp.writeback : 0)
                return d
            }
            return generic
        case 7 where op & 0x0F00_0E10 == 0x0E00_0A00:
            let code = ((op >> 20) & 1) << 1 | (op >> 6) & 1 | ((op >> 23) & 1) << 3 | ((op >> 21) & 1) << 2
            d.kind = .vfpData
            if op & 0x100 == 0 && code <= 8 {
                d.kind = .vfpArithmetic
                d.flags = UInt8(code)
                d.rd = rd << 1 | UInt8((op >> 22) & 1)
                d.rn = rn << 1 | UInt8((op >> 7) & 1)
                d.rm = rm << 1 | UInt8((op >> 5) & 1)
            }
            return d
        default:
            if op & 0x0FFF_FFD0 == 0x012F_FF10 && rm != 15 {
                d.kind = .branchExchange
                d.flags = op & 0x20 != 0 ? 1 : 0
                return d
            }
            return generic
        }
    }

    // Immediate addressing: imm is the signed offset, or the final address for a PC-relative literal.
    private static func setAddressing(_ d: inout ARMDecodedOp, offset: UInt32, add: Bool, pre: Bool, writeback: Bool,
                                      at address: UInt32) {
        d.imm = add ? offset : 0 &- offset
        d.flags = (pre ? ARMDecodedOp.preIndexed : 0) | (writeback ? ARMDecodedOp.writeback : 0)
        if d.rn == 15 { d.flags |= ARMDecodedOp.absolute; d.imm = address &+ 8 &+ d.imm }
    }
}
