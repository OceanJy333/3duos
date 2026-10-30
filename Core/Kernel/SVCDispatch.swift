// input: an SVC number trapped by a guest thread.
// output: the guest registers the 3DS ABI promises, or a stop when the call is not implemented.
// pos: SVC table; bodies are grouped by theme in SVCMemory, SVCThread and SVCSystem.
import Foundation

extension Kernel {
    func dispatchSVC(_ number: UInt32, thread: KThread) -> KernelStop? {
        let cpu = thread.cpu
        if traceSVC && current.id != 5 { note(String(format: "t%d @%llu SVC 0x%02X pc=%08X r0=%08X r1=%08X r2=%08X r3=%08X", current.id, ticks, number, cpu.pc, cpu.registers[0], cpu.registers[1], cpu.registers[2], cpu.registers[3])) }
        switch number {
        case 0x01: controlMemory(cpu)
        case 0x02: queryMemory(cpu)
        case 0x03: stop = .exited
        case 0x08: createThread(cpu)
        case 0x09: exitThread(thread)
        case 0x0A: sleepThread(thread)
        case 0x0B: getThreadPriority(cpu)
        case 0x0C: setThreadPriority(cpu)
        case 0x0D, 0x0F: cpu.registers[0] = 0 // affinity mask, ideal processor: one emulated core
        case 0x0E, 0x10: cpu.registers[0] = 0; cpu.registers[1] = 1
        case 0x11: cpu.registers[0] = 0; cpu.registers[1] = 0
        case 0x13: createMutex(cpu)
        case 0x14: releaseMutex(thread)
        case 0x15: createSemaphore(cpu)
        case 0x16: releaseSemaphore(cpu)
        case 0x17: createEvent(cpu)
        case 0x18: signalEvent(cpu)
        case 0x19: clearEvent(cpu)
        case 0x1A: createTimer(cpu)
        case 0x1B: setTimer(cpu)
        case 0x1C: cancelTimer(cpu)
        case 0x1D: clearTimer(cpu)
        case 0x1E: createMemoryBlock(cpu)
        case 0x1F: mapMemoryBlock(cpu)
        case 0x20: unmapMemoryBlock(cpu)
        case 0x21: createAddressArbiter(cpu)
        case 0x22: arbitrateAddress(thread)
        case 0x23: cpu.registers[0] = close(cpu.registers[0])
        case 0x24: waitSynchronization1(thread)
        case 0x25: waitSynchronizationN(thread)
        case 0x27: duplicateHandle(cpu)
        case 0x28: cpu.registers[0] = 0; cpu.registers[1] = UInt32(truncatingIfNeeded: ticks); cpu.registers[2] = UInt32(truncatingIfNeeded: ticks >> 32)
        case 0x2D: connectToPort(cpu)
        case 0x32: sendSyncRequest(thread)
        case 0x35, 0x36: cpu.registers[0] = 0; cpu.registers[1] = 0x1D
        case 0x37: getThreadID(cpu)
        case 0x38: getResourceLimit(cpu)
        case 0x39, 0x3A: resourceLimitValues(cpu, current: number == 0x3A)
        case 0x3C: stop = .unsupported(String(format: "Break(0x%X) at pc=%08X", cpu.registers[0], cpu.pc))
        case 0x3D: outputDebugString(cpu)
        default:
            stop = .unsupportedSVC(number, pc: cpu.pc &- 4)
        }
        return stop
    }
}
