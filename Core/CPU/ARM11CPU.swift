// input: ARM instructions and memory supplied by the caller
// output: register updates, instruction count, or a stop reason
// pos: standalone ARM11 A32 interpreter core

protocol ARMMemory {
    func read8(_ address: UInt32) throws -> UInt8
    func read32(_ address: UInt32) throws -> UInt32
    func write8(_ address: UInt32, _ value: UInt8) throws
    func write32(_ address: UInt32, _ value: UInt32) throws
}

enum ARMStop: Equatable {
    case running
    case supervisorCall(UInt32)
    case undefined(UInt32, UInt32)
    case memoryFault(UInt32, String)
    case unsupportedThumb(UInt32)
}

final class ARM11CPU {
    var registers = [UInt32](repeating: 0, count: 16)
    var cpsr: UInt32 = 0x10 // User mode, A32, little endian.
    private(set) var instructionCount: UInt64 = 0
    var exclusiveAddress: UInt32?
    var threadLocalStorageAddress: UInt32 = 0 // CP15 c13 user read-only thread register.
    var fpscr: UInt32 = 0
    var fpexc: UInt32 = 0
    var vfpSingles = [UInt32](repeating: 0, count: 32) // Dn aliases S(2n) and S(2n+1).

    var pc: UInt32 {
        get { registers[15] }
        set { registers[15] = newValue }
    }
    var n: Bool { cpsr & 0x8000_0000 != 0 }
    var z: Bool { cpsr & 0x4000_0000 != 0 }
    var c: Bool { cpsr & 0x2000_0000 != 0 }
    var v: Bool { cpsr & 0x1000_0000 != 0 }

    func step(memory: ARMMemory) -> ARMStop {
        let address = pc
        if cpsr & 0x20 != 0 { return .unsupportedThumb(address) }
        let instruction: UInt32
        do { instruction = try memory.read32(address) }
        catch { return .memoryFault(address, String(describing: error)) }
        instructionCount &+= 1
        if instruction == 0xF57F_F01F { // CLREX is unconditional in ARM state.
            clearExclusiveMonitor()
            pc = address &+ 4
            return .running
        }
        let condition = instruction >> 28
        if condition == 15 { return .undefined(address, instruction) }
        if !conditionPassed(condition) { pc = address &+ 4; return .running }
        if instruction & 0x0FFF_FFFF == 0x0320_F000 { // ARMv6K NOP hint.
            pc = address &+ 4
            return .running
        }
        if instruction & 0x0FFF_0FFF == 0x0E1D_0F70 { // MRC p15, 0, Rd, c13, c0, 3
            let rd = Int((instruction >> 12) & 15)
            if rd == 15 { cpsr = (cpsr & 0x0FFF_FFFF) | (threadLocalStorageAddress & 0xF000_0000) }
            else { registers[rd] = threadLocalStorageAddress }
            pc = address &+ 4
            return .running
        }
        if instruction & 0x0FE0_0FFF == 0x0EE0_0A10 {
            return vfpSystemTransfer(instruction, at: address)
        }
        if instruction & 0x0F20_0E00 == 0x0D00_0A00 {
            do { return try vfpMemoryTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0FFF_FFF0 == 0x012F_FF10 { // BX
            let target = operandRegister(Int(instruction & 15), at: address)
            cpsr = (cpsr & ~0x20) | ((target & 1) << 5)
            pc = target & (target & 1 == 0 ? ~UInt32(3) : ~UInt32(1))
            return .running
        }
        if instruction & 0x0F00_0000 == 0x0F00_0000 {
            pc = address &+ 4
            return .supervisorCall(instruction & 0x00FF_FFFF)
        }
        if instruction & 0x0E00_0000 == 0x0A00_0000 {
            let raw = instruction & 0x00FF_FFFF
            let signed = Int32(bitPattern: raw << 8) >> 6
            if instruction & 0x0100_0000 != 0 { registers[14] = address &+ 4 }
            pc = address &+ 8 &+ UInt32(bitPattern: signed)
            return .running
        }
        if instruction & 0x0FF0_0FFF == 0x0190_0F9F ||
            instruction & 0x0FF0_0FF0 == 0x0180_0F90 {
            do { return try exclusiveTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0E00_0000 == 0x0800_0000 {
            do { return try blockTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0FFF_03F0 == 0x06FF_0070 { // UXTH, ARMv6 rotate-and-extend.
            let rd = Int((instruction >> 12) & 15), rm = Int(instruction & 15)
            if rd == 15 || rm == 15 { return .undefined(address, instruction) }
            let rotation = Int((instruction >> 10) & 3) * 8
            registers[rd] = shift(registers[rm], kind: 3, amount: rotation, immediate: false).0 & 0xFFFF
            pc = address &+ 4
            return .running
        }
        if instruction & 0x0C00_0000 == 0x0400_0000 {
            do { return try transfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0E00_0090 == 0x0000_0090 && instruction & 0x60 != 0 {
            do { return try miscellaneousTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0C00_0000 == 0 {
            return dataProcessing(instruction, at: address)
        }
        return .undefined(address, instruction)
    }

    func operandRegister(_ index: Int, at address: UInt32) -> UInt32 {
        index == 15 ? address &+ 8 : registers[index]
    }

    func setFlag(_ mask: UInt32, _ value: Bool) {
        cpsr = value ? cpsr | mask : cpsr & ~mask
    }

    private func conditionPassed(_ condition: UInt32) -> Bool {
        switch condition {
        case 0: return z
        case 1: return !z
        case 2: return c
        case 3: return !c
        case 4: return n
        case 5: return !n
        case 6: return v
        case 7: return !v
        case 8: return c && !z
        case 9: return !c || z
        case 10: return n == v
        case 11: return n != v
        case 12: return !z && n == v
        case 13: return z || n != v
        case 14: return true
        default: return false
        }
    }
}
