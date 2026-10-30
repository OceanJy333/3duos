// input: guest memory (ideally with a published ARMPageTable) and an instruction limit.
// output: executed instruction count and the stop that ended the run (`.running` when the limit was reached).
// pos: hot loop of the ARM11 interpreter: cached pre-decoded ops, host-pointer loads and stores, full decoder as fallback.
// Kept in one file so non-whole-module builds can inline the helpers and fold the flag constants.

struct ARMDecodedOp {
    var raw: UInt32 = 0
    var imm: UInt32 = 0
    var condMask: UInt16 = 0xFFFF   // bit n set: passes when NZCV == n
    var kind: ARMOpKind = .undecoded
    var rd: UInt8 = 0, rn: UInt8 = 0, rm: UInt8 = 0
    var shift: UInt8 = 0            // shift kind << 5 | amount; see ARMOpKind for other uses
    var flags: UInt8 = 0            // per kind, see the masks below

    // data and multiply: ALU opcode in bits 0-3.
    static let setFlags: UInt8 = 0x10, accumulate: UInt8 = 0x20
    // load/store: imm is the signed offset, or the address itself when absolute (PC-relative literal).
    static let preIndexed: UInt8 = 1, writeback: UInt8 = 2, byte: UInt8 = 4, absolute: UInt8 = 8
    static let registerOffset: UInt8 = 16, subtract: UInt8 = 32
    // load/store multiple: increment, before, writeback; VFP transfers: vfpLoad, vfpDouble, absolute,
    // and for FLDM/FSTM increment and writeback.
    static let increment: UInt8 = 16, before: UInt8 = 4
    static let vfpLoad: UInt8 = 1, vfpDouble: UInt8 = 4
}

extension ARM11CPU {
    func run(memory: ARMMemory, limit: Int) -> (stop: ARMStop, executed: Int) {
        let table = memory.pageTable
        pageTable = table
        let readable = table?.readable, writable = table?.writable
        let r = registers.base, s = vfpSingles.base
        var pc = r[15], executed = 0, uncounted = 0
        var stop = ARMStop.running
        var codePage = UInt32.max
        var host: UnsafeMutableRawPointer?, ops: UnsafeMutablePointer<ARMDecodedOp>?
        loop: while executed < limit {
            executed &+= 1
            if cpsr & 0x20 != 0 { stop = .unsupportedThumb(pc); uncounted = 1; break }
            if let readable, pc >> 12 != codePage {
                codePage = pc >> 12
                host = readable[Int(codePage)]
                ops = host == nil ? nil : table.unsafelyUnwrapped.decodedPage(Int(codePage))
            }
            var op: ARMDecodedOp
            if let host, let ops, pc & 3 == 0 {
                let raw = host.load(fromByteOffset: Int(pc & 0xFFF), as: UInt32.self)
                let slot = ops + Int((pc & 0xFFF) >> 2)
                op = slot.pointee
                if op.raw != raw { op = Self.decode(raw, at: pc); slot.pointee = op }
            } else {
                do { op = Self.decode(try memory.read32(pc), at: pc) }
                catch { stop = .memoryFault(pc, String(describing: error)); uncounted = 1; break }
            }
            if (op.condMask >> UInt16(cpsr >> 28)) & 1 == 0 { pc &+= 4; continue }
            dispatch: switch op.kind {
            case .dataImmediate:
                let carry = op.shift == 0 ? (cpsr >> 29) & 1 : op.imm >> 31
                dataOperation(op, r[Int(op.rn)], op.imm, carry, r, &pc)
                continue
            case .dataRegister:
                let (value, carry) = shiftedRegister(r[Int(op.rm)], op.shift)
                dataOperation(op, r[Int(op.rn)], value, carry, r, &pc)
                continue
            case .branch:
                if op.flags != 0 { r[14] = pc &+ 4 }
                pc = op.imm
                continue
            case .branchExchange:
                let target = r[Int(op.rm)]
                if op.flags != 0 { r[14] = pc &+ 4 }
                interwork(target, &pc)
                continue
            case .load, .store, .halfword:
                guard let readable, let writable else { break dispatch }
                let flags = op.flags
                let base = flags & ARMDecodedOp.absolute != 0 ? 0 : r[Int(op.rn)]
                let offset = flags & ARMDecodedOp.registerOffset != 0 ? shiftedRegister(r[Int(op.rm)], op.shift).0 : op.imm
                let adjusted = flags & ARMDecodedOp.subtract != 0 ? base &- offset : base &+ offset
                let location = flags & ARMDecodedOp.preIndexed != 0 ? adjusted : base
                let within = Int(location & 0xFFF), rd = Int(op.rd)
                switch op.kind {
                case .load:
                    guard let page = readable[Int(location >> 12)] else { break dispatch }
                    let value: UInt32
                    if flags & ARMDecodedOp.byte != 0 { value = UInt32(page.load(fromByteOffset: within, as: UInt8.self)) }
                    else {
                        guard location & 3 == 0 else { break dispatch }
                        value = page.load(fromByteOffset: within, as: UInt32.self)
                    }
                    if flags & ARMDecodedOp.writeback != 0 { r[Int(op.rn)] = adjusted }
                    if rd == 15 { interwork(value, &pc); continue loop }
                    r[rd] = value
                case .store:
                    guard let page = writable[Int(location >> 12)] else { break dispatch }
                    let value = rd == 15 ? pc &+ 12 : r[rd]   // ARM11 stores the instruction address + 12 for PC
                    if flags & ARMDecodedOp.byte != 0 {
                        page.storeBytes(of: UInt8(truncatingIfNeeded: value), toByteOffset: within, as: UInt8.self)
                    } else {
                        guard location & 3 == 0 else { break dispatch }
                        page.storeBytes(of: value, toByteOffset: within, as: UInt32.self)
                    }
                    if flags & ARMDecodedOp.writeback != 0 { r[Int(op.rn)] = adjusted }
                default:
                    guard halfword(op.shift, location, rd, readable, writable, r) else { break dispatch }
                    if flags & ARMDecodedOp.writeback != 0 { r[Int(op.rn)] = adjusted }
                }
                pc &+= 4
                continue
            case .loadMultiple, .storeMultiple:
                guard let readable, let writable else { break }
                let load = op.kind.rawValue == ARMOpKind.loadMultiple.rawValue, list = op.imm, base = r[Int(op.rn)]
                let size = UInt32(list.nonzeroBitCount * 4), before = op.flags & ARMDecodedOp.before != 0
                let increment = op.flags & ARMDecodedOp.increment != 0
                let start = increment ? base &+ (before ? 4 : 0) : base &- size &+ (before ? 0 : 4)
                guard start & 3 == 0, (start & 0xFFF) + size <= 0x1000,
                      let page = (load ? readable : writable)[Int(start >> 12)] else { break }
                var word = (page + Int(start & 0xFFF)).assumingMemoryBound(to: UInt32.self)
                var bits = list, loadedPC: UInt32?
                while bits != 0 {
                    let register = bits.trailingZeroBitCount
                    bits &= bits &- 1
                    if load {
                        if register == 15 { loadedPC = word.pointee } else { r[register] = word.pointee }
                    } else { word.pointee = register == 15 ? pc &+ 12 : r[register] }
                    word += 1
                }
                if op.flags & ARMDecodedOp.writeback != 0 { r[Int(op.rn)] = increment ? base &+ size : base &- size }
                if let target = loadedPC { interwork(target, &pc) } else { pc &+= 4 }
                continue
            case .multiply:
                let product = r[Int(op.rm)] &* r[Int(op.shift)]
                let result = op.flags & ARMDecodedOp.accumulate != 0 ? product &+ r[Int(op.rd)] : product
                r[Int(op.rn)] = result
                if op.flags & ARMDecodedOp.setFlags != 0 {
                    cpsr = (cpsr & 0x3FFF_FFFF) | (result & 0x8000_0000) | (result == 0 ? 0x4000_0000 : 0)
                }
                pc &+= 4
                continue
            case .vfpArithmetic:
                guard fpexc & 0xC000_0000 == 0x4000_0000, fpscr & 0x0007_0000 == 0 else { break }
                let a = Float(bitPattern: s[Int(op.rn)]), b = Float(bitPattern: s[Int(op.rm)])
                let d = Float(bitPattern: s[Int(op.rd)])
                let result: Float
                switch op.flags { // products are rounded before accumulating, as VFP11 does
                case 0: let p = a * b; result = d + p
                case 1: let p = a * b; result = d - p
                case 2: let p = a * b; result = -d + p
                case 3: let p = a * b; result = -d - p
                case 4: result = a * b
                case 5: result = -(a * b)
                case 6: result = a + b
                case 7: result = a - b
                default: result = a / b
                }
                s[Int(op.rd)] = result.bitPattern
                pc &+= 4
                continue
            case .vfpTransfer:
                guard let readable, let writable, fpexc & 0xC000_0000 == 0x4000_0000 else { break }
                let location = op.flags & ARMDecodedOp.absolute != 0 ? op.imm : r[Int(op.rn)] &+ op.imm
                let double = op.flags & ARMDecodedOp.vfpDouble != 0, load = op.flags & ARMDecodedOp.vfpLoad != 0
                guard location & 3 == 0, location & 0xFFF <= (double ? 0xFF8 : 0xFFC),
                      let page = (load ? readable : writable)[Int(location >> 12)] else { break }
                let word = (page + Int(location & 0xFFF)).assumingMemoryBound(to: UInt32.self)
                let first = Int(op.rd)
                if load {
                    s[first] = word[0]
                    if double { s[first + 1] = word[1] }
                } else {
                    word[0] = s[first]
                    if double { word[1] = s[first + 1] }
                }
                pc &+= 4
                continue
            case .vfpMultiple:
                guard let readable, let writable, fpexc & 0xC000_0000 == 0x4000_0000 else { break }
                let load = op.flags & ARMDecodedOp.vfpLoad != 0, increment = op.flags & ARMDecodedOp.increment != 0
                let bytes = op.imm << 2, base = r[Int(op.rn)]
                let start = increment ? base : base &- bytes
                guard start & 3 == 0, (start & 0xFFF) + bytes <= 0x1000,
                      let page = (load ? readable : writable)[Int(start >> 12)] else { break }
                let words = (page + Int(start & 0xFFF)).assumingMemoryBound(to: UInt32.self), first = s + Int(op.rd)
                if load { first.update(from: words, count: Int(op.imm)) } else { words.update(from: first, count: Int(op.imm)) }
                if op.flags & ARMDecodedOp.writeback != 0 { r[Int(op.rn)] = increment ? start &+ bytes : start }
                pc &+= 4
                continue
            case .undecoded: // an empty cache slot whose memory word equals the empty slot's raw (0)
                if let ops { ops[Int((pc & 0xFFF) >> 2)] = Self.decode(op.raw, at: pc) }
            case .generic, .vfpData, .vfpBlock: break
            }
            // Full decoder: encodings without a fast form, and fast forms whose access left the host pages
            // (every `break dispatch` happens before the fast form changes any state).
            r[15] = pc
            let result: ARMStop
            switch op.kind {
            case .vfpData: result = vfpDataProcessing(op.raw, at: pc)
            case .vfpBlock:
                do { result = try vfpBlockTransfer(op.raw, at: pc, memory: memory) }
                catch { result = .memoryFault(pc, String(describing: error)) }
            default: result = execute(op.raw, at: pc, memory: memory)
            }
            pc = r[15]
            if case .running = result { continue }
            stop = result
            break
        }
        r[15] = pc
        instructionCount &+= UInt64(executed - uncounted)
        return (stop, executed)
    }

    // BX-style PC write: bit 0 selects Thumb.
    @inline(__always) private func interwork(_ target: UInt32, _ pc: inout UInt32) {
        cpsr = (cpsr & ~0x20) | ((target & 1) << 5)
        pc = target & (target & 1 == 0 ? ~UInt32(3) : ~UInt32(1))
    }

    // LDRH/STRH/LDRSB/LDRSH/LDRD/STRD inside one host page; false sends the instruction to the full decoder.
    @inline(__always)
    private func halfword(_ form: UInt8, _ location: UInt32, _ rd: Int, _ readable: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                          _ writable: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ r: UnsafeMutablePointer<UInt32>) -> Bool {
        let within = Int(location & 0xFFF), load = form & 4 != 0, kind = form & 3
        if kind == 1 || load { guard within <= 0xFFE || kind == 2 else { return false } }
        else { guard location & 3 == 0, within <= 0xFF8 else { return false } }   // LDRD, STRD
        guard let page = (load || kind == 2 ? readable : writable)[Int(location >> 12)] else { return false }
        switch (load, kind) {
        case (true, 1): r[rd] = UInt32(page.loadUnaligned(fromByteOffset: within, as: UInt16.self))
        case (true, 2): r[rd] = UInt32(bitPattern: Int32(page.load(fromByteOffset: within, as: Int8.self)))
        case (true, _): r[rd] = UInt32(bitPattern: Int32(page.loadUnaligned(fromByteOffset: within, as: Int16.self)))
        case (false, 1): page.storeBytes(of: UInt16(truncatingIfNeeded: r[rd]), toByteOffset: within, as: UInt16.self)
        case (false, 2):
            r[rd] = page.load(fromByteOffset: within, as: UInt32.self)
            r[rd + 1] = page.load(fromByteOffset: within + 4, as: UInt32.self)
        default:
            page.storeBytes(of: r[rd], toByteOffset: within, as: UInt32.self)
            page.storeBytes(of: r[rd + 1], toByteOffset: within + 4, as: UInt32.self)
        }
        return true
    }

    @inline(__always)
    private func dataOperation(_ op: ARMDecodedOp, _ lhs: UInt32, _ rhs: UInt32, _ shifterCarry: UInt32,
                               _ r: UnsafeMutablePointer<UInt32>, _ pc: inout UInt32) {
        let opcode = op.flags & 15
        var result: UInt32, carry = shifterCarry, overflow: UInt32 = 2 // 2: V unchanged
        switch opcode {
        case 0, 8: result = lhs & rhs
        case 1, 9: result = lhs ^ rhs
        case 12: result = lhs | rhs
        case 13: result = rhs
        case 14: result = lhs & ~rhs
        case 15: result = ~rhs
        default:
            let x: UInt32, y: UInt32, carryIn: UInt64
            switch opcode {
            case 2, 10: (x, y, carryIn) = (lhs, ~rhs, 1)
            case 3: (x, y, carryIn) = (rhs, ~lhs, 1)
            case 4, 11: (x, y, carryIn) = (lhs, rhs, 0)
            case 5: (x, y, carryIn) = (lhs, rhs, UInt64((cpsr >> 29) & 1))
            case 6: (x, y, carryIn) = (lhs, ~rhs, UInt64((cpsr >> 29) & 1))
            default: (x, y, carryIn) = (rhs, ~lhs, UInt64((cpsr >> 29) & 1))
            }
            let wide = UInt64(x) &+ UInt64(y) &+ carryIn
            result = UInt32(truncatingIfNeeded: wide)
            carry = UInt32(truncatingIfNeeded: wide >> 32)
            overflow = (~(x ^ y) & (x ^ result)) >> 31
        }
        if op.flags & ARMDecodedOp.setFlags != 0 {
            let nzc = (result & 0x8000_0000) | (result == 0 ? 0x4000_0000 : 0) | carry << 29
            cpsr = overflow == 2 ? (cpsr & 0x1FFF_FFFF) | nzc : (cpsr & 0x0FFF_FFFF) | nzc | overflow << 28
        }
        if opcode & 12 == 8 { pc &+= 4 }                    // TST, TEQ, CMP, CMN
        else if op.rd == 15 { pc = result & ~UInt32(3) }
        else { r[Int(op.rd)] = result; pc &+= 4 }
    }

    // Barrel shifter for a register shifted by an immediate; returns the value and the carry out (0 or 1).
    @inline(__always)
    private func shiftedRegister(_ value: UInt32, _ shift: UInt8) -> (UInt32, UInt32) {
        let amount = UInt32(shift & 31), carryIn = (cpsr >> 29) & 1
        switch shift >> 5 {
        case 0:
            return amount == 0 ? (value, carryIn) : (value &<< amount, (value &>> (32 - amount)) & 1)
        case 1:
            return amount == 0 ? (0, value >> 31) : (value &>> amount, (value &>> (amount - 1)) & 1)
        case 2:
            let signed = Int32(bitPattern: value)
            return amount == 0 ? (UInt32(bitPattern: signed >> 31), value >> 31)
                : (UInt32(bitPattern: signed &>> Int32(amount)), (value &>> (amount - 1)) & 1)
        default:
            return amount == 0 ? (carryIn << 31 | value >> 1, value & 1)
                : (value &>> amount | value &<< (32 - amount), (value &>> (amount - 1)) & 1)
        }
    }
}
