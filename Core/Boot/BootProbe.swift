// input: decoded cartridge program and maximum instruction count.
// output: first CPU stop or instruction limit with PC, instruction and count.
// pos: bounded game entry-point probe, before a complete OS and emulator exist.
import Foundation

struct BootProbeResult {
    let stop: ARMStop
    let pc: UInt32
    // For Thumb this is the first 16 bits; nil means the instruction could not be read.
    let instruction: UInt32?
    let instructionCount: UInt64
    let handledSVCCount: Int
    let unsupportedSVC: UInt32?
}

enum BootProbe {
    static func run(_ program: CartridgeProgram, limit: Int = 10_000, hle: Bool = false,
                    currentCommit: UInt32? = nil) throws -> BootProbeResult {
        precondition(limit > 0)
        let memory = try ProgramMemory(program: program)
        let cpu = ARM11CPU()
        cpu.threadLocalStorageAddress = ProgramMemory.mainThreadTLS
        // The OS enables VFP for the application thread before its entry point.
        cpu.fpexc = 0x4000_0000
        let kernel = hle ? SVCDispatcher() : nil
        kernel?.currentCommit = currentCommit
        // Exploratory Old3DS memory layout; no allocation occurs in the strict probe.
        if currentCommit != nil { kernel?.linearBase = 0x1400_0000 }
        var handledSVCCount = 0
        cpu.pc = program.text.address
        cpu.registers[13] = 0x1000_0000
        for _ in 0..<limit {
            let address = cpu.pc
            let instruction = peek(memory, cpu: cpu)
            let stop = cpu.step(memory: memory)
            if case .supervisorCall(let id) = stop, let kernel {
                switch kernel.dispatch(id, cpu: cpu, memory: memory) {
                case .handled:
                    handledSVCCount += 1
                    continue
                case .unsupported(let unsupportedID):
                    return BootProbeResult(stop: stop, pc: address, instruction: instruction,
                                           instructionCount: cpu.instructionCount, handledSVCCount: handledSVCCount,
                                           unsupportedSVC: unsupportedID)
                }
            }
            if stop != .running {
                return BootProbeResult(stop: stop, pc: address, instruction: instruction,
                                       instructionCount: cpu.instructionCount, handledSVCCount: handledSVCCount,
                                       unsupportedSVC: nil)
            }
        }
        return BootProbeResult(stop: .running, pc: cpu.pc, instruction: peek(memory, cpu: cpu),
                               instructionCount: cpu.instructionCount, handledSVCCount: handledSVCCount, unsupportedSVC: nil)
    }

    private static func peek(_ memory: ProgramMemory, cpu: ARM11CPU) -> UInt32? {
        if cpu.cpsr & 0x20 == 0 { return try? memory.read32(cpu.pc) }
        guard let low = try? memory.read8(cpu.pc), let high = try? memory.read8(cpu.pc &+ 1) else { return nil }
        return UInt32(low) | UInt32(high) << 8
    }
}
