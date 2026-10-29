// input: fixed ARMv6 instruction words and a bounded little-endian memory
// output: executable assertions for the standalone ARM11 interpreter
// pos: CPU tests, run with swiftc alongside 3duos/Core/CPU/*.swift

import Foundation

enum TestFault: Error { case address(UInt32) }
final class RAM: ARMMemory {
    var bytes: [UInt8]
    init(_ size: Int = 256) { bytes = [UInt8](repeating: 0, count: size) }
    func read8(_ address: UInt32) throws -> UInt8 {
        guard Int(address) < bytes.count else { throw TestFault.address(address) }
        return bytes[Int(address)]
    }
    func read32(_ address: UInt32) throws -> UInt32 {
        guard address & 3 == 0, UInt64(address) + 4 <= UInt64(bytes.count) else { throw TestFault.address(address) }
        let i = Int(address)
        return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
    func write8(_ address: UInt32, _ value: UInt8) throws {
        guard Int(address) < bytes.count else { throw TestFault.address(address) }
        bytes[Int(address)] = value
    }
    func write32(_ address: UInt32, _ value: UInt32) throws {
        guard address & 3 == 0, UInt64(address) + 4 <= UInt64(bytes.count) else { throw TestFault.address(address) }
        for i in 0..<4 { bytes[Int(address) + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    func load(_ instructions: [UInt32]) throws {
        for (i, instruction) in instructions.enumerated() { try write32(UInt32(i * 4), instruction) }
    }
}

var assertions = 0
func check(_ expression: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !expression() { fatalError(description) }
}
func run(_ instructions: [UInt32], configure: (ARM11CPU) -> Void = { _ in }) throws -> (ARM11CPU, RAM, ARMStop) {
    let ram = RAM(), cpu = ARM11CPU()
    try ram.load(instructions)
    configure(cpu)
    var stop = ARMStop.running
    for _ in 0..<100 {
        stop = cpu.step(memory: ram)
        if stop != .running { break }
    }
    return (cpu, ram, stop)
}

do {
    let (nop, _, nopStop) = try run([0xE3A00001, 0xE320F000, 0xEF000042])
    check(nopStop == .supervisorCall(0x42) && nop.registers[0] == 1 && nop.instructionCount == 3,
          "ARMv6K NOP leaves registers unchanged")
    // Loop five times, persist its result, load it back, and trap.
    let (cpu, ram, stop) = try run([0xE3A00000, 0xE2800001, 0xE3500005, 0x1AFFFFFC,
                                    0xE5810000, 0xE5912000, 0xEF000042]) { $0.registers[1] = 128 }
    check(stop == .supervisorCall(0x42), "SVC result")
    check(cpu.registers[0] == 5 && cpu.registers[2] == 5, "loop, store and load")
    let stored = try ram.read32(128)
    check(stored == 5 && cpu.pc == 28 && cpu.instructionCount == 19, "memory, PC and count")

    let (flags, _, flagsStop) = try run([0xE2900001, 0xE2B11000, 0xE3520000, 0x03A03007, 0x13A03009, 0xEF000000]) {
        $0.registers[0] = UInt32.max; $0.registers[1] = 0; $0.registers[2] = 0
    }
    check(flagsStop == .supervisorCall(0) && flags.registers[0] == 0, "ADDS wrap")
    check(flags.registers[1] == 1 && flags.registers[3] == 7 && flags.z && flags.c, "ADC and condition flags")
    let (overflow, _, _) = try run([0xE2900001, 0xEF000000]) { $0.registers[0] = 0x7FFF_FFFF }
    check(overflow.registers[0] == 0x8000_0000 && overflow.n && overflow.v && !overflow.c, "signed overflow")

    // MOVS r1,r0,LSR #32; MOVS r2,r0,RRX (C from first instruction).
    let (shifts, _, _) = try run([0xE1B01020, 0xE1B02060, 0xEF000000]) { $0.registers[0] = 0x8000_0001 }
    check(shifts.registers[1] == 0 && shifts.registers[2] == 0xC000_0000 && shifts.c, "LSR 32 and RRX")
    let (branch, _, branchStop) = try run([0xEB000000, 0xE3A00001, 0xE28F2000, 0xEF000009])
    check(branchStop == .supervisorCall(9) && branch.registers[14] == 4 && branch.registers[2] == 16, "BL and PC-relative operand")
    let (bytes, bytesRAM, _) = try run([0xE5C10001, 0xE5D12001, 0xEF000000]) {
        $0.registers[0] = 0x1234; $0.registers[1] = 128
    }
    check(bytes.registers[2] == 0x34, "byte store and load")
    let storedByte = try bytesRAM.read8(129)
    check(storedByte == 0x34, "byte stored")

    let (indexed, _, _) = try run([0xE4810004, 0xE5112004, 0xE1B03410, 0xEF000000]) {
        $0.registers[0] = 0x8000_0001; $0.registers[1] = 128; $0.registers[4] = 32
    }
    check(indexed.registers[1] == 132 && indexed.registers[2] == 0x8000_0001, "post-index writeback and negative offset")
    check(indexed.registers[3] == 0 && indexed.z && indexed.c, "register shift by 32")
    let (skipped, _, skipStop) = try run([0x03A00001, 0xEF000003])
    check(skipped.registers[0] == 0 && skipped.instructionCount == 2 && skipStop == .supervisorCall(3), "failed condition advances PC and counts fetch")
    let fetchCPU = ARM11CPU(), fetchRAM = RAM()
    fetchCPU.pc = 256
    if case .memoryFault(256, _) = fetchCPU.step(memory: fetchRAM) {
        check(fetchCPU.instructionCount == 0 && fetchCPU.pc == 256, "fetch fault does not count")
    } else { fatalError("missing fetch fault") }

    // Real Zelda opcode PUSH {r4,lr}, followed by POP {r4,pc}.
    let stack = RAM(), stackCPU = ARM11CPU()
    try stack.load([0xE92D4010, 0xE8BD8010, 0xE3A00000, 0xEF000055])
    stackCPU.registers[13] = 128; stackCPU.registers[4] = 0x1234; stackCPU.registers[14] = 12
    check(stackCPU.step(memory: stack) == .running && stackCPU.registers[13] == 120, "Zelda PUSH decrements SP")
    let pushedR4 = try stack.read32(120), pushedLR = try stack.read32(124)
    check(pushedR4 == 0x1234 && pushedLR == 12, "PUSH ascending register order")
    stackCPU.registers[4] = 0
    check(stackCPU.step(memory: stack) == .running && stackCPU.registers[4] == 0x1234 && stackCPU.registers[13] == 128 && stackCPU.pc == 12, "POP restores registers and branches")
    check(stackCPU.step(memory: stack) == .supervisorCall(0x55), "POP target executes")

    // Address mode bits (P,U): IA (0,1), IB (1,1), DA (0,0), DB (1,0).
    for (mode, start) in [(UInt32(0x00800000), UInt32(128)), (0x01800000, 132),
                          (0x00000000, 124), (0x01000000, 120)] {
        let memory = RAM(), core = ARM11CPU()
        try memory.load([0xE8000005 | mode | 0x00210000]) // STM mode r1!, {r0,r2}
        core.registers[0] = 0x11223344; core.registers[1] = 128; core.registers[2] = 0x55667788
        check(core.step(memory: memory) == .running, "STM mode executes")
        let first = try memory.read32(start), second = try memory.read32(start + 4)
        check(first == 0x11223344 && second == 0x55667788, "STM mode addresses")
        check(core.registers[1] == (mode & 0x00800000 != 0 ? 136 : 120), "STM mode writeback")
        let loadMemory = RAM(), loadCore = ARM11CPU()
        try loadMemory.load([0xE8100005 | mode | 0x00010000]) // LDM mode r1, {r0,r2}
        try loadMemory.write32(start, 0xAABBCCDD); try loadMemory.write32(start + 4, 0x12345678)
        loadCore.registers[1] = 128
        check(loadCore.step(memory: loadMemory) == .running && loadCore.registers[0] == 0xAABBCCDD && loadCore.registers[2] == 0x12345678 && loadCore.registers[1] == 128, "LDM mode without writeback")
    }
    let storeBase = RAM(), storeCore = ARM11CPU()
    try storeBase.load([0xE8A10006]) // STMIA r1!, {r1,r2}
    storeCore.registers[1] = 128; storeCore.registers[2] = 9
    check(storeCore.step(memory: storeBase) == .running && storeCore.registers[1] == 136, "STM base lowest permits writeback")
    let savedBase = try storeBase.read32(128)
    check(savedBase == 128, "STM stores original base")
    let unsupported = RAM(), unsupportedCore = ARM11CPU()
    try unsupported.load([0xE8B10002]) // LDMIA r1!, {r1} is unpredictable
    check(unsupportedCore.step(memory: unsupported) == .undefined(0, 0xE8B10002), "unpredictable LDM writeback")
    let banked = RAM(), bankedCore = ARM11CPU()
    try banked.load([0xE8D10001]) // LDM with S bit requires banked user registers.
    check(bankedCore.step(memory: banked) == .undefined(0, 0xE8D10001), "banked transfer is explicit")
    let storePC = RAM(), storePCCore = ARM11CPU()
    try storePC.load([0xE8818000]) // STMIA r1, {pc}
    storePCCore.registers[1] = 128
    check(storePCCore.step(memory: storePC) == .running, "STM PC executes")
    let storedPC = try storePC.read32(128)
    check(storedPC == 12, "STM stores chosen PC+12 value")
    let thumbPop = RAM(), thumbCore = ARM11CPU()
    try thumbPop.load([0xE8BD8000]); try thumbPop.write32(128, 17)
    thumbCore.registers[13] = 128
    check(thumbCore.step(memory: thumbPop) == .running && thumbCore.pc == 16 && thumbCore.cpsr & 0x20 != 0, "LDM PC selects Thumb")
    check(thumbCore.step(memory: thumbPop) == .unsupportedThumb(16), "Thumb remains explicit")

    // Zelda's LDREX r2,[r0]; atomically increment and store with STREX r3,r2,[r0].
    let exclusive = RAM(), exclusiveCPU = ARM11CPU()
    try exclusive.load([0xE1902F9F, 0xE2822001, 0xE1803F92, 0xE1803F92])
    try exclusive.write32(128, 41); exclusiveCPU.registers[0] = 128
    check(exclusiveCPU.step(memory: exclusive) == .running && exclusiveCPU.registers[2] == 41, "Zelda LDREX reads word")
    check(exclusiveCPU.step(memory: exclusive) == .running && exclusiveCPU.registers[2] == 42, "exclusive update")
    check(exclusiveCPU.step(memory: exclusive) == .running && exclusiveCPU.registers[3] == 0, "STREX succeeds")
    let exclusiveStored = try exclusive.read32(128)
    check(exclusiveStored == 42, "successful STREX writes value")
    check(exclusiveCPU.step(memory: exclusive) == .running && exclusiveCPU.registers[3] == 1, "STREX consumes monitor")

    let cleared = RAM(), clearedCPU = ARM11CPU()
    try cleared.load([0xE1902F9F, 0xF57FF01F, 0xE1803F92])
    try cleared.write32(128, 21); clearedCPU.registers[0] = 128
    check(clearedCPU.step(memory: cleared) == .running && clearedCPU.step(memory: cleared) == .running, "CLREX executes unconditionally")
    check(clearedCPU.step(memory: cleared) == .running && clearedCPU.registers[3] == 1, "CLREX forces STREX failure")
    let clearedValue = try cleared.read32(128)
    check(clearedValue == 21, "failed STREX leaves memory unchanged")

    let mismatch = RAM(), mismatchCPU = ARM11CPU()
    try mismatch.load([0xE1902F9F, 0xE1803F92, 0xE1803F92])
    mismatchCPU.registers[0] = 128
    check(mismatchCPU.step(memory: mismatch) == .running, "LDREX sets local monitor")
    mismatchCPU.registers[0] = 132
    check(mismatchCPU.step(memory: mismatch) == .running && mismatchCPU.registers[3] == 1, "different address STREX fails")
    mismatchCPU.registers[0] = 128
    check(mismatchCPU.step(memory: mismatch) == .running && mismatchCPU.registers[3] == 1, "failed STREX clears monitor")

    let alignment = RAM(), alignmentCPU = ARM11CPU()
    try alignment.load([0xE1902F9F]); alignmentCPU.registers[0] = 129; alignmentCPU.registers[2] = 123
    if case .memoryFault(0, _) = alignmentCPU.step(memory: alignment) {
        check(alignmentCPU.pc == 0 && alignmentCPU.registers[2] == 123, "unaligned LDREX faults without destination update")
    } else { fatalError("missing exclusive alignment fault") }
    let invalidExclusive = RAM(), invalidExclusiveCPU = ARM11CPU()
    try invalidExclusive.load([0xE1800F92]) // STREX status shares its base register.
    check(invalidExclusiveCPU.step(memory: invalidExclusive) == .undefined(0, 0xE1800F92), "invalid STREX operands")
    let conditionExclusive = RAM(), conditionExclusiveCPU = ARM11CPU()
    try conditionExclusive.load([0x01902F9F, 0xE1803F92]); conditionExclusiveCPU.registers[0] = 128
    check(conditionExclusiveCPU.step(memory: conditionExclusive) == .running && conditionExclusiveCPU.step(memory: conditionExclusive) == .running && conditionExclusiveCPU.registers[3] == 1, "failed LDREX condition sets no monitor")
    let resetMonitor = RAM(), resetCPU = ARM11CPU()
    try resetMonitor.load([0xE1902F9F, 0xE1803F92]); resetCPU.registers[0] = 128
    check(resetCPU.step(memory: resetMonitor) == .running, "LDREX before context switch")
    resetCPU.clearExclusiveMonitor()
    check(resetCPU.step(memory: resetMonitor) == .running && resetCPU.registers[3] == 1, "context switch clears local monitor")

    let tls = RAM(), tlsCPU = ARM11CPU()
    try tls.load([0xEE1D0F70, 0xEE1D7F70, 0x0E1D3F70, 0xEE1DFF70])
    tlsCPU.threadLocalStorageAddress = 0xA123_4567
    check(tlsCPU.step(memory: tls) == .running && tlsCPU.registers[0] == 0xA123_4567, "Zelda MRC reads per-core thread address")
    check(tlsCPU.step(memory: tls) == .running && tlsCPU.registers[7] == 0xA123_4567, "MRC reads into selected destination")
    tlsCPU.registers[3] = 99
    check(tlsCPU.step(memory: tls) == .running && tlsCPU.registers[3] == 99, "conditional MRC is skipped")
    check(tlsCPU.step(memory: tls) == .running && tlsCPU.cpsr & 0xF000_0000 == 0xA000_0000 && tlsCPU.pc == 16, "MRC r15 updates flags")
    let otherCP15 = RAM(), otherCP15CPU = ARM11CPU()
    try otherCP15.load([0xEE1D0F50]) // c13,c0,2 is outside the implemented read.
    check(otherCP15CPU.step(memory: otherCP15) == .undefined(0, 0xEE1D0F50), "other CP15 encoding remains undefined")
    let writeTLS = RAM(), writeTLSCPU = ARM11CPU()
    try writeTLS.load([0xEE0D0F70]) // MCR to the read-only register is not implemented.
    check(writeTLSCPU.step(memory: writeTLS) == .undefined(0, 0xEE0D0F70), "MCR remains undefined")
    let otherCore = ARM11CPU()
    check(otherCore.threadLocalStorageAddress == 0 && tlsCPU.threadLocalStorageAddress == 0xA123_4567, "thread addresses belong to CPU instances")

    let vfp = RAM(), vfpCPU = ARM11CPU()
    try vfp.load([0xEEE10A10, 0xEEF11A10, 0xEEF1FA10, 0x0EE12A10])
    vfpCPU.fpexc = 0x4000_0000; vfpCPU.registers[0] = 0xA100_0091
    check(vfpCPU.step(memory: vfp) == .running && vfpCPU.fpscr == 0xA100_0091, "Zelda VMSR writes FPSCR")
    check(vfpCPU.step(memory: vfp) == .running && vfpCPU.registers[1] == 0xA100_0091, "VMRS reads FPSCR")
    check(vfpCPU.step(memory: vfp) == .running && vfpCPU.cpsr & 0xF000_0000 == 0xA000_0000, "VMRS r15 copies FPSCR flags")
    vfpCPU.registers[2] = 0x1234
    check(vfpCPU.step(memory: vfp) == .running && vfpCPU.fpscr == 0xA100_0091, "failed VMSR condition changes nothing")

    let fpexcTest = RAM(), fpexcCPU = ARM11CPU()
    try fpexcTest.load([0xEEE80A10, 0xEEF81A10, 0xEEE10A10])
    fpexcCPU.cpsr = 0x13; fpexcCPU.registers[0] = 0x4000_0000
    check(fpexcCPU.step(memory: fpexcTest) == .running && fpexcCPU.fpexc == 0x4000_0000, "privileged VMSR enables VFP")
    check(fpexcCPU.step(memory: fpexcTest) == .running && fpexcCPU.registers[1] == 0x4000_0000, "privileged VMRS reads FPEXC")
    check(fpexcCPU.step(memory: fpexcTest) == .running && fpexcCPU.fpscr == 0x4000_0000, "enabled FPSCR access")
    let vfpDisabled = RAM(), vfpDisabledCPU = ARM11CPU()
    try vfpDisabled.load([0xEEE10A10])
    check(vfpDisabledCPU.step(memory: vfpDisabled) == .undefined(0, 0xEEE10A10), "FPSCR inaccessible when VFP disabled")
    let fpexcUser = RAM(), fpexcUserCPU = ARM11CPU()
    try fpexcUser.load([0xEEF80A10]); fpexcUserCPU.fpexc = 0x4000_0000
    check(fpexcUserCPU.step(memory: fpexcUser) == .undefined(0, 0xEEF80A10), "FPEXC privileged only")
    let vfpOther = RAM(), vfpOtherCPU = ARM11CPU()
    try vfpOther.load([0xEEE20A10]); vfpOtherCPU.fpexc = 0x4000_0000
    check(vfpOtherCPU.step(memory: vfpOther) == .undefined(0, 0xEEE20A10), "other VFP registers remain undefined")
    let vfpOtherEncoding = RAM(), vfpOtherEncodingCPU = ARM11CPU()
    try vfpOtherEncoding.load([0xEEE10A30]); vfpOtherEncodingCPU.fpexc = 0x4000_0000
    check(vfpOtherEncodingCPU.step(memory: vfpOtherEncoding) == .undefined(0, 0xEEE10A30), "other VFP encodings remain undefined")
    let vfpPCWrite = RAM(), vfpPCWriteCPU = ARM11CPU()
    try vfpPCWrite.load([0xEEE1FA10]); vfpPCWriteCPU.fpexc = 0x4000_0000
    check(vfpPCWriteCPU.step(memory: vfpPCWrite) == .undefined(0, 0xEEE1FA10), "VMSR from PC is unsupported")
    let vfpExceptional = RAM(), vfpExceptionalCPU = ARM11CPU()
    try vfpExceptional.load([0xEEF10A10]); vfpExceptionalCPU.fpexc = 0xC000_0000
    check(vfpExceptionalCPU.step(memory: vfpExceptional) == .undefined(0, 0xEEF10A10), "VFP exception processing is unsupported")

    // FLDS/FSTS preserve raw bits; D0 aliases S0 and S1.
    let fpMemory = RAM(), fpCPU = ARM11CPU()
    try fpMemory.load([0xEDDF0A1B, 0xED410A01, 0xED910B01, 0xED01FB02, 0xEDD1FA00])
    try fpMemory.write32(116, 0x7FA12345) // signaling NaN payload at PC+8+108
    try fpMemory.write32(132, 0x12345678); try fpMemory.write32(136, 0x89ABCDEF)
    try fpMemory.write32(128, 0x80000001)
    fpCPU.fpexc = 0x4000_0000; fpCPU.registers[1] = 128
    check(fpCPU.step(memory: fpMemory) == .running && fpCPU.vfpSingles[1] == 0x7FA12345, "Zelda FLDS S1 PC-relative and NaN payload")
    let fpStoreStop = fpCPU.step(memory: fpMemory), fpStored = try fpMemory.read32(124)
    check(fpStoreStop == .running && fpStored == 0x7FA12345 && fpCPU.registers[1] == 128, "FSTS negative offset without writeback")
    check(fpCPU.step(memory: fpMemory) == .running && fpCPU.vfpSingles[0] == 0x12345678 && fpCPU.vfpSingles[1] == 0x89ABCDEF, "FLDD writes aliased S0 and S1")
    fpCPU.vfpSingles[30] = 0xCAFEBABE; fpCPU.vfpSingles[31] = 0x01234567
    let fpDoubleStop = fpCPU.step(memory: fpMemory), fpLow = try fpMemory.read32(120), fpHigh = try fpMemory.read32(124)
    check(fpDoubleStop == .running && fpLow == 0xCAFEBABE && fpHigh == 0x01234567, "FSTD D15 stores both aliased registers")
    check(fpCPU.step(memory: fpMemory) == .running && fpCPU.vfpSingles[31] == 0x80000001, "FLDS selects S31")
    for op: UInt32 in [0xEDD10B00, 0xEDB10A00] { // VFPv2 has no D16, multiple load unsupported.
        let memory = RAM(), core = ARM11CPU(); try memory.load([op]); core.fpexc = 0x4000_0000
        check(core.step(memory: memory) == .undefined(0, op), "unsupported VFP memory encoding")
    }
    let disabledFP = RAM(), disabledFPCPU = ARM11CPU(); try disabledFP.load([0xED910A00])
    check(disabledFPCPU.step(memory: disabledFP) == .undefined(0, 0xED910A00), "disabled VFP rejects FLDS")
    let exceptionalFP = RAM(), exceptionalFPCPU = ARM11CPU(); try exceptionalFP.load([0xED910A00]); exceptionalFPCPU.fpexc = 0xC000_0000
    check(exceptionalFPCPU.step(memory: exceptionalFP) == .undefined(0, 0xED910A00), "exceptional VFP state is unsupported")
    let skippedFP = RAM(), skippedFPCPU = ARM11CPU(); try skippedFP.load([0x0D910A00])
    check(skippedFPCPU.step(memory: skippedFP) == .running && skippedFPCPU.pc == 4, "failed condition skips disabled VFP")
    let fpFault = RAM(), fpFaultCPU = ARM11CPU(); try fpFault.load([0xED910B00])
    fpFaultCPU.fpexc = 0x4000_0000; fpFaultCPU.registers[1] = 252
    fpFaultCPU.vfpSingles[0] = 12; fpFaultCPU.vfpSingles[1] = 34
    if case .memoryFault(0, _) = fpFaultCPU.step(memory: fpFault) {
        check(fpFaultCPU.vfpSingles[0] == 12 && fpFaultCPU.vfpSingles[1] == 34 && fpFaultCPU.pc == 0, "FLDD fault preserves registers and PC")
    } else { fatalError("missing FLDD fault") }

    // Addressing mode 3: the Zelda STRD and paired LDRD with immediate offsets.
    let pairs = RAM(), pairCPU = ARM11CPU()
    try pairs.load([0xE1C580F8, 0xE1C520D8]) // STRD r8,[r5,#8]; LDRD r2,[r5,#8]
    pairCPU.registers[5] = 128; pairCPU.registers[8] = 0x12345678; pairCPU.registers[9] = 0xABCDEF01
    check(pairCPU.step(memory: pairs) == .running && pairCPU.registers[5] == 128, "Zelda STRD immediate offset")
    let pairLow = try pairs.read32(136), pairHigh = try pairs.read32(140)
    check(pairLow == 0x12345678 && pairHigh == 0xABCDEF01, "STRD stores ascending words")
    check(pairCPU.step(memory: pairs) == .running && pairCPU.registers[2] == pairLow && pairCPU.registers[3] == pairHigh, "LDRD loads both words")

    let modes = RAM(), modeCPU = ARM11CPU()
    try modes.load([0xE16520F8, 0xE00500D6]) // STRD r2,[r5,#-8]!; LDRD r0,[r5],-r6
    modeCPU.registers[5] = 144; modeCPU.registers[6] = 4
    modeCPU.registers[2] = 0xBEEF; modeCPU.registers[3] = 0x1234
    check(modeCPU.step(memory: modes) == .running && modeCPU.registers[5] == 136, "STRD negative pre-index writeback")
    check(modeCPU.step(memory: modes) == .running && modeCPU.registers[0] == 0xBEEF && modeCPU.registers[1] == 0x1234 && modeCPU.registers[5] == 132, "LDRD register post-index writeback")

    let halves = RAM(), halfCPU = ARM11CPU()
    try halves.load([0xE1C120B3, 0xE1D130B3, 0xE1D140D4, 0xE1D150F3])
    halfCPU.registers[1] = 128; halfCPU.registers[2] = 0xAB80
    check(halfCPU.step(memory: halves) == .running, "STRH unaligned ARMv6 transfer")
    check(halfCPU.step(memory: halves) == .running && halfCPU.registers[3] == 0xAB80, "LDRH zero extends")
    check(halfCPU.step(memory: halves) == .running && halfCPU.registers[4] == 0xFFFFFFAB, "LDRSB sign extends")
    check(halfCPU.step(memory: halves) == .running && halfCPU.registers[5] == 0xFFFFAB80, "LDRSH sign extends")
    let offsets = RAM(512), offsetsCPU = ARM11CPU()
    try offsets.load([0xE1D12FBF, 0xE09130B1, 0xE1DF40B8])
    offsetsCPU.registers[1] = 128
    try offsets.write8(383, 0x34); try offsets.write8(384, 0x12)
    try offsets.write8(128, 0xCD); try offsets.write8(129, 0xAB)
    try offsets.write8(24, 0x78); try offsets.write8(25, 0x56)
    check(offsetsCPU.step(memory: offsets) == .running && offsetsCPU.registers[2] == 0x1234, "split 8-bit immediate reaches 255")
    check(offsetsCPU.step(memory: offsets) == .running && offsetsCPU.registers[3] == 0xABCD && offsetsCPU.registers[1] == 256, "ARMv6 permits base as post-index register")
    check(offsetsCPU.step(memory: offsets) == .running && offsetsCPU.registers[4] == 0x5678, "PC-relative halfword uses instruction address plus eight")

    let invalidMisc: [UInt32] = [0xE1C590F8, 0xE1C5E0F8, 0xE1E880F8, 0xE18580D8,
                                  0xE18121B2, 0xE0E120B2, 0xE18580DF]
    for op in invalidMisc {
        let memory = RAM(), core = ARM11CPU(); try memory.load([op])
        check(core.step(memory: memory) == .undefined(0, op) && core.pc == 0, "invalid miscellaneous operands \(String(op, radix: 16))")
    }
    let pairFault = RAM(), pairFaultCPU = ARM11CPU()
    try pairFault.load([0xE1E120D8]); pairFaultCPU.registers[1] = 244
    pairFaultCPU.registers[2] = 0xAA; pairFaultCPU.registers[3] = 0xBB
    if case .memoryFault(0, _) = pairFaultCPU.step(memory: pairFault) {
        check(pairFaultCPU.registers[1] == 244 && pairFaultCPU.registers[2] == 0xAA && pairFaultCPU.registers[3] == 0xBB && pairFaultCPU.pc == 0, "LDRD second-word fault leaves registers and base intact")
    } else { fatalError("missing LDRD fault") }
    let pairAlign = RAM(), pairAlignCPU = ARM11CPU()
    try pairAlign.load([0xE1C120D0]); pairAlignCPU.registers[1] = 130
    if case .memoryFault(0, _) = pairAlignCPU.step(memory: pairAlign) {
        check(pairAlignCPU.pc == 0, "unaligned LDRD stops")
    } else { fatalError("missing LDRD alignment fault") }
    let skippedMisc = RAM(), skippedMiscCPU = ARM11CPU()
    try skippedMisc.load([0x01C580F8]); skippedMiscCPU.registers[5] = 256
    check(skippedMiscCPU.step(memory: skippedMisc) == .running && skippedMiscCPU.pc == 4, "failed condition skips transfer")

    // UXTH rotates by 0, 8, 16 or 24 before zero-extending, without changing flags.
    let extended = RAM(), extendCPU = ARM11CPU()
    try extended.load([0xE6FF3073, 0xE6FF1470, 0xE6FF2870, 0xE6FF3C70, 0xE6FF0070])
    extendCPU.registers[0] = 0x89AB_CDEF; extendCPU.registers[3] = 0xABCD_8001
    extendCPU.cpsr = 0xB000_0010
    check(extendCPU.step(memory: extended) == .running && extendCPU.registers[3] == 0x8001, "Zelda UXTH in-place")
    check(extendCPU.step(memory: extended) == .running && extendCPU.registers[1] == 0xABCD, "UXTH rotate 8")
    check(extendCPU.step(memory: extended) == .running && extendCPU.registers[2] == 0x89AB, "UXTH rotate 16")
    check(extendCPU.step(memory: extended) == .running && extendCPU.registers[3] == 0xEF89, "UXTH rotate 24 wraps")
    check(extendCPU.step(memory: extended) == .running && extendCPU.registers[0] == 0xCDEF && extendCPU.cpsr == 0xB000_0010, "UXTH preserves flags")
    let conditionalExtend = RAM(), conditionalExtendCPU = ARM11CPU()
    try conditionalExtend.load([0x06FF3073]); conditionalExtendCPU.registers[3] = 0x1234_5678
    check(conditionalExtendCPU.step(memory: conditionalExtend) == .running && conditionalExtendCPU.registers[3] == 0x1234_5678 && conditionalExtendCPU.pc == 4, "failed UXTH condition is skipped")
    for op: UInt32 in [0xE6FFF073, 0xE6FF307F, 0xE6FF3173, 0xE6F13073] {
        let memory = RAM(), core = ARM11CPU(); try memory.load([op])
        check(core.step(memory: memory) == .undefined(0, op) && core.pc == 0, "invalid or unsupported extend encoding \(String(op, radix: 16))")
    }

    let (unknown, _, unknownStop) = try run([0xE0000090])
    check(unknownStop == .undefined(0, 0xE0000090) && unknown.pc == 0 && unknown.instructionCount == 1, "undefined multiply")
    let (thumb, _, thumbStop) = try run([0xE12FFF10]) { $0.registers[0] = 9 }
    check(thumbStop == .unsupportedThumb(8) && thumb.pc == 8 && thumb.instructionCount == 1, "BX Thumb boundary")
    let (fault, _, faultStop) = try run([0xE5910000]) { $0.registers[1] = 256 }
    if case .memoryFault(0, _) = faultStop { check(fault.pc == 0, "fault preserves PC") }
    else { fatalError("missing memory fault") }
    print("ARM11 interpreter: \(assertions) assertions passed; loop executed \(cpu.instructionCount) instructions")
} catch { fatalError("test setup failed: \(error)") }
