// input: ARM instructions and memory supplied by the caller
// output: register updates, instruction count, or a stop reason
// pos: standalone ARM11 A32 interpreter core

protocol ARMMemory {
    func read8(_ address: UInt32) throws -> UInt8
    func read32(_ address: UInt32) throws -> UInt32
    func write8(_ address: UInt32, _ value: UInt8) throws
    func write32(_ address: UInt32, _ value: UInt32) throws
    // Direct host pages when the memory can publish them; nil keeps every access on the methods above.
    var pageTable: ARMPageTable? { get }
}

extension ARMMemory {
    var pageTable: ARMPageTable? { nil }
}

enum ARMStop: Equatable {
    case running
    case supervisorCall(UInt32)
    case undefined(UInt32, UInt32)
    case memoryFault(UInt32, String)
    case unsupportedThumb(UInt32)
}

final class ARM11CPU {
    let registers = RegisterFile(count: 16)
    var cpsr: UInt32 = 0x10 // User mode, A32, little endian.
    var instructionCount: UInt64 = 0
    var exclusiveAddress: UInt32?
    var threadLocalStorageAddress: UInt32 = 0 // CP15 c13 user read-only thread register.
    var fpscr: UInt32 = 0
    var fpexc: UInt32 = 0
    let vfpSingles = RegisterFile(count: 32) // Dn aliases S(2n) and S(2n+1).
    var pageTable: ARMPageTable? // set by run(memory:limit:) for the memory being executed
    deinit { registers.release(); vfpSingles.release() }

    var pc: UInt32 {
        get { registers[15] }
        set { registers[15] = newValue }
    }
    var n: Bool { cpsr & 0x8000_0000 != 0 }
    var z: Bool { cpsr & 0x4000_0000 != 0 }
    var c: Bool { cpsr & 0x2000_0000 != 0 }
    var v: Bool { cpsr & 0x1000_0000 != 0 }

    func step(memory: ARMMemory) -> ARMStop { run(memory: memory, limit: 1).stop }

    // Everything after fetch, decode-on-the-fly: the path for encodings without a pre-decoded form.
    func execute(_ instruction: UInt32, at address: UInt32, memory: ARMMemory) -> ARMStop {
        if instruction == 0xF57F_F01F { // CLREX is unconditional in ARM state.
            clearExclusiveMonitor()
            pc = address &+ 4
            return .running
        }
        let condition = instruction >> 28
        if instruction & 0xFD70_F000 == 0xF550_F000 { // PLD is only a cache hint.
            pc = address &+ 4
            return .running
        }
        if condition == 15 { return .undefined(address, instruction) }
        if !conditionPassed(condition) { pc = address &+ 4; return .running }
        // Fast paths for the common classes; encodings that share these bits with special instructions fall through.
        switch (instruction >> 25) & 7 {
        case 0 where instruction & 0x90 != 0x90 && instruction & 0x0190_0000 != 0x0100_0000, 1 where instruction & 0x0190_0000 != 0x0100_0000:
            return dataProcessing(instruction, at: address)
        case 2:
            do { return try transfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        case 5:
            let signed = Int32(bitPattern: (instruction & 0x00FF_FFFF) << 8) >> 6
            if instruction & 0x0100_0000 != 0 { registers[14] = address &+ 4 }
            pc = address &+ 8 &+ UInt32(bitPattern: signed)
            return .running
        default: break
        }
        if instruction & 0x0FFF_FFFF == 0x0320_F000 { // ARMv6K NOP hint.
            pc = address &+ 4
            return .running
        }
        if instruction & 0x0F1F_0F10 == 0x0E07_0F10 { // MCR p15, c7: cache maintenance and barriers
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
        if instruction & 0x0F00_0E00 == 0x0E00_0A00 {
            if instruction & 0x10 == 0 { return vfpDataProcessing(instruction, at: address) }
            if instruction & 0x0FE0_0F7F == 0x0E00_0A10 { return vfpRegisterTransfer(instruction, at: address) }
        }
        if instruction & 0x0FE0_0E00 == 0x0C40_0A00 { return vfpPairTransfer(instruction, at: address) }
        if instruction & 0x0E00_0E00 == 0x0C00_0A00 && instruction & 0x0120_0000 != 0x0100_0000 {
            do { return try vfpBlockTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0F20_0E00 == 0x0D00_0A00 {
            do { return try vfpMemoryTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0FFF_FFD0 == 0x012F_FF10 { // BX, BLX (register)
            let target = operandRegister(Int(instruction & 15), at: address)
            if instruction & 0x20 != 0 { registers[14] = address &+ 4 }
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
        if instruction & 0x0F80_0FF0 == 0x0180_0F90 && (instruction & 0x0010_0000 == 0 || instruction & 0xF == 0xF) {
            do { return try exclusiveTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0E00_0000 == 0x0800_0000 {
            do { return try blockTransfer(instruction, at: address, memory: memory) }
            catch { return .memoryFault(address, String(describing: error)) }
        }
        if instruction & 0x0F00_00F0 == 0x0000_0090 { return multiply(instruction, at: address) }
        if instruction & 0x0F90_0090 == 0x0100_0080 { return halfwordMultiply(instruction, at: address) }
        if instruction & 0x0FFF_0FF0 == 0x016F_0F10 || instruction & 0x0FBF_0F70 == 0x06BF_0F30 {
            return countOrReverse(instruction, at: address)
        }
        if instruction & 0x0F80_03F0 == 0x0680_0070 { return extend(instruction, at: address) }
        if instruction & 0x0FA0_0030 == 0x06A0_0010 { return saturate(instruction, at: address) }
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
