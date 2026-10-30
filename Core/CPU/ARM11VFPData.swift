// input: VFPv2 scalar data-processing, S-register transfer instructions and the aliased register file
// output: single/double arithmetic, compare flags in FPSCR, conversions, or an undefined-instruction stop
// pos: ARM11 VFP11 arithmetic; vector mode (FPSCR.LEN != 0), exceptions and flush-to-zero are not modeled

import Foundation

extension ARM11CPU {
    func sreg(_ index: Int) -> Float { Float(bitPattern: vfpSingles[index]) }
    func setSingle(_ index: Int, _ value: Float) { vfpSingles[index] = value.bitPattern }
    func dreg(_ index: Int) -> Double {
        Double(bitPattern: UInt64(vfpSingles[index * 2 + 1]) << 32 | UInt64(vfpSingles[index * 2]))
    }
    func setDouble(_ index: Int, _ value: Double) {
        let bits = value.bitPattern
        vfpSingles[index * 2] = UInt32(truncatingIfNeeded: bits)
        vfpSingles[index * 2 + 1] = UInt32(truncatingIfNeeded: bits >> 32)
    }

    // FMSR / FMRS: move between an ARM register and one S register.
    func vfpRegisterTransfer(_ op: UInt32, at address: UInt32) -> ARMStop {
        guard fpexc & 0xC000_0000 == 0x4000_0000 else { return .undefined(address, op) }
        let rd = Int((op >> 12) & 15), s = Int((op >> 15) & 0x1E) | Int((op >> 7) & 1)
        if op & (1 << 20) != 0 {
            if rd == 15 { return .undefined(address, op) }
            registers[rd] = vfpSingles[s]
        } else {
            if rd == 15 { return .undefined(address, op) }
            vfpSingles[s] = registers[rd]
        }
        pc = address &+ 4
        return .running
    }

    func vfpDataProcessing(_ op: UInt32, at address: UInt32) -> ARMStop {
        guard fpexc & 0xC000_0000 == 0x4000_0000, fpscr & 0x0007_0000 == 0 else { return .undefined(address, op) }
        let double = op & 0x100 != 0
        let vd = Int((op >> 12) & 15), vn = Int((op >> 16) & 15), vm = Int(op & 15)
        let d = Int((op >> 22) & 1), n = Int((op >> 7) & 1), m = Int((op >> 5) & 1)
        let code = Int((op >> 20) & 1) << 1 | Int((op >> 6) & 1) | Int((op >> 23) & 1) << 3 | Int((op >> 21) & 1) << 2
        if code == 15 { return vfpExtension(op, at: address, double: double) }
        if double {
            // Double-precision operands use D:Vd, and the N and M bits extend the other fields.
            guard d == 0, n == 0, m == 0 else { return .undefined(address, op) }
            let a = dreg(vn), b = dreg(vm), dest = dreg(vd)
            guard let result = vfpArithmetic(code, a, b, dest) else { return .undefined(address, op) }
            setDouble(vd, result)
        } else {
            let fd = vd << 1 | d, fn = vn << 1 | n, fm = vm << 1 | m
            guard let result = vfpArithmetic(code, sreg(fn), sreg(fm), sreg(fd)) else {
                return .undefined(address, op)
            }
            setSingle(fd, result)
        }
        pc = address &+ 4
        return .running
    }

    private func vfpArithmetic<T: BinaryFloatingPoint>(_ code: Int, _ a: T, _ b: T, _ d: T) -> T? {
        switch code {
        case 0: let p = a * b; return d + p
        case 1: let p = a * b; return d - p
        case 2: let p = a * b; return -d + p
        case 3: let p = a * b; return -d - p
        case 4: return a * b
        case 5: return -(a * b)
        case 6: return a + b
        case 7: return a - b
        case 8: return a / b
        default: return nil
        }
    }

    private func vfpExtension(_ op: UInt32, at address: UInt32, double: Bool) -> ARMStop {
        let vd = Int((op >> 12) & 15), vm = Int(op & 15), d = Int((op >> 22) & 1), m = Int((op >> 5) & 1)
        let sub = Int((op >> 16) & 15) << 1 | Int((op >> 7) & 1)
        let sd = vd << 1 | d, sm = vm << 1 | m
        func result(_ value: Float) { setSingle(sd, value) }
        switch (sub, double) {
        case (0b00000, false): result(sreg(sm))
        case (0b00000, true): setDouble(vd, dreg(vm))
        case (0b00001, false): result(abs(sreg(sm)))
        case (0b00001, true): setDouble(vd, abs(dreg(vm)))
        case (0b00010, false): result(-sreg(sm))
        case (0b00010, true): setDouble(vd, -dreg(vm))
        case (0b00011, false): result(sreg(sm).squareRoot())
        case (0b00011, true): setDouble(vd, dreg(vm).squareRoot())
        case (0b01000, _), (0b01001, _), (0b01010, _), (0b01011, _):
            let zero = sub >= 0b01010
            let a: Double = double ? dreg(vd) : Double(sreg(sd))
            let b: Double = zero ? 0 : (double ? dreg(vm) : Double(sreg(sm)))
            var flags: UInt32
            if a.isNaN || b.isNaN { flags = 0x3000_0000 }
            else if a == b { flags = 0x6000_0000 }
            else if a < b { flags = 0x8000_0000 }
            else { flags = 0x2000_0000 }
            fpscr = (fpscr & 0x0FFF_FFFF) | flags
        case (0b01111, false): setDouble(vd, Double(sreg(sm)))
        case (0b01111, true): result(Float(dreg(vm)))
        case (0b10000, _): // FUITO
            let value = vfpSingles[sm]
            if double { setDouble(vd, Double(value)) } else { result(Float(value)) }
        case (0b10001, _): // FSITO
            let value = Int32(bitPattern: vfpSingles[sm])
            if double { setDouble(vd, Double(value)) } else { result(Float(value)) }
        case (0b11000, _), (0b11001, _): // FTOUI, FTOUIZ
            let source = double ? dreg(vm) : Double(sreg(sm))
            vfpSingles[sd] = UInt32(clamping: Int64(vfpConvert(source, truncate: sub == 0b11001, signed: false)))
        case (0b11010, _), (0b11011, _): // FTOSI, FTOSIZ
            let source = double ? dreg(vm) : Double(sreg(sm))
            vfpSingles[sd] = UInt32(bitPattern: Int32(clamping: Int64(vfpConvert(source, truncate: sub == 0b11011, signed: true))))
        default: return .undefined(address, op)
        }
        pc = address &+ 4
        return .running
    }

    private func vfpConvert(_ value: Double, truncate: Bool, signed: Bool) -> Double {
        if value.isNaN { return 0 }
        let rounding: FloatingPointRoundingRule
        if truncate { rounding = .towardZero } else {
            switch (fpscr >> 22) & 3 {
            case 1: rounding = .up
            case 2: rounding = .down
            case 3: rounding = .towardZero
            default: rounding = .toNearestOrEven
            }
        }
        let low = signed ? Double(Int32.min) : 0, high = signed ? Double(Int32.max) : Double(UInt32.max)
        return min(max(value.rounded(rounding), low), high)
    }
}
