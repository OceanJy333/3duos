// input: synthetic A32 program invoking kernel SVCs through ARM11CPU
// output: executable assertions for guest-visible registers and handle lifetime
// pos: standalone CPU-to-kernel integration test

enum MemoryError: Error { case outOfBounds }
final class TestMemory: ARMMemory {
    private var bytes = [UInt8](repeating: 0, count: 256)
    func read8(_ address: UInt32) throws -> UInt8 {
        guard address < bytes.count else { throw MemoryError.outOfBounds }
        return bytes[Int(address)]
    }
    func read32(_ address: UInt32) throws -> UInt32 {
        guard address & 3 == 0, UInt64(address) + 4 <= bytes.count else { throw MemoryError.outOfBounds }
        return try (0..<4).reduce(UInt32(0)) { $0 | UInt32(try read8(address + UInt32($1))) << ($1 * 8) }
    }
    func write8(_ address: UInt32, _ value: UInt8) throws {
        guard address < bytes.count else { throw MemoryError.outOfBounds }
        bytes[Int(address)] = value
    }
    func write32(_ address: UInt32, _ value: UInt32) throws {
        guard address & 3 == 0, UInt64(address) + 4 <= bytes.count else { throw MemoryError.outOfBounds }
        for i in 0..<4 { try write8(address + UInt32(i), UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let memory = TestMemory(), cpu = ARM11CPU(), kernel = SVCDispatcher()
// Save each SVC result in guest registers; close the first handle twice.
let program: [UInt32] = [
    0xEF000021, // svc 0x21
    0xE1A04001, // mov r4,r1
    0xE1A05000, // mov r5,r0
    0xEF000021, // svc 0x21
    0xE1A06001, // mov r6,r1
    0xE1A07000, // mov r7,r0
    0xE1A00004, // mov r0,r4
    0xEF000023, // svc 0x23
    0xE1A08000, // mov r8,r0
    0xE1A00004, // mov r0,r4
    0xEF000023, // svc 0x23
    0xE1A09000, // mov r9,r0
    0xE1A00006, // mov r0,r6
    0xEF000023, // svc 0x23
    0xE1A0A000, // mov r10,r0
    0xEF000021, // create again after slot release
    0xE1A0B001, // mov r11,r1
    0xE1A0C000, // mov r12,r0
    0xE1A00004, // mov r0,r4
    0xEF000023, // old handle stays invalid after reuse
    0xE1A0E000, // mov lr,r0
    0xEF000042  // explicit unsupported boundary
]
for (index, instruction) in program.enumerated() { try memory.write32(UInt32(index * 4), instruction) }
var unsupported: UInt32?
var unsupportedPreservedRegisters = false
for _ in program {
    switch cpu.step(memory: memory) {
    case .running: break
    case .supervisorCall(let number):
        let before = cpu.registers
        if case .unsupported(let id) = kernel.dispatch(number, cpu: cpu) {
            unsupported = id
            unsupportedPreservedRegisters = before == cpu.registers
        }
    case let other: fatalError("unexpected CPU stop: \(other)")
    }
}
check(cpu.registers[5] == 0 && cpu.registers[7] == 0, "both creations succeed")
check(cpu.registers[4] != 0 && cpu.registers[6] != 0 && cpu.registers[4] != cpu.registers[6], "distinct handles returned in r1")
check(cpu.registers[8] == 0 && cpu.registers[9] == 0xD8E0_07F7, "closed handle is invalid")
check(cpu.registers[10] == 0, "second handle remains valid")
check(cpu.registers[12] == 0 && cpu.registers[11] != cpu.registers[4] && cpu.registers[14] == 0xD8E0_07F7, "reused slot does not revive old handle")
check(unsupported == 0x42 && unsupportedPreservedRegisters && cpu.pc == UInt32(program.count * 4), "unsupported SVC is explicit and leaves registers unchanged")

// Execute the real trap with r0 deliberately different from the process handle.
try memory.write32(0, 0xEF000038)
cpu.pc = 0
cpu.registers[0] = 0x1234_5678
cpu.registers[1] = KernelHandles.currentProcess
guard case .supervisorCall(0x38) = cpu.step(memory: memory) else { fatalError("expected resource-limit SVC") }
check(kernel.dispatch(0x38, cpu: cpu) == .handled && cpu.registers[0] == 0, "current process has a resource-limit handle")
let limit1 = cpu.registers[1]
check(limit1 != 0 && limit1 != KernelHandles.currentProcess, "resource-limit handle is returned in r1")
cpu.registers[1] = KernelHandles.currentProcess
_ = kernel.dispatch(0x38, cpu: cpu)
let limit2 = cpu.registers[1]
check(cpu.registers[0] == 0 && limit1 != limit2, "each lookup allocates a distinct handle")
check(kernel.handles.close(limit1) == 0 && kernel.handles.close(limit1) == KernelHandles.invalidHandle, "resource-limit handle closes once")
check(kernel.handles.close(limit2) == 0, "closing one resource-limit handle leaves the other usable")
for invalid in [UInt32(0), limit1, UInt32(0xFFFF_8000), cpu.registers[11]] {
    cpu.registers[1] = invalid
    _ = kernel.dispatch(0x38, cpu: cpu)
    check(cpu.registers[0] == KernelHandles.invalidHandle && cpu.registers[1] == invalid, "invalid process handle is rejected")
}
check(kernel.handles.close(KernelHandles.currentProcess) == KernelHandles.invalidHandle, "pseudo handle is not a closable slot")
let fullKernel = SVCDispatcher()
for _ in 0..<4096 { check(fullKernel.handles.createAddressArbiter().result == 0, "fill handle table") }
let fullCPU = ARM11CPU()
fullCPU.registers[1] = KernelHandles.currentProcess
_ = fullKernel.dispatch(0x38, cpu: fullCPU)
check(fullCPU.registers[0] == KernelHandles.outOfHandles && fullCPU.registers[1] == KernelHandles.currentProcess, "full table returns allocation failure")

let queryKernel = SVCDispatcher(), queryCPU = ARM11CPU()
let resource = queryKernel.handles.getResourceLimit(process: KernelHandles.currentProcess).handle!
try memory.write32(0x80, 1)
queryCPU.registers[0] = 0x88
queryCPU.registers[1] = resource
queryCPU.registers[2] = 0x80
queryCPU.registers[3] = 1
check(queryKernel.dispatch(0x3A, cpu: queryCPU, memory: memory) == .unsupported(0x3A), "unknown commit usage remains unsupported")
queryKernel.currentCommit = 0x1234_5000
check(queryKernel.dispatch(0x3A, cpu: queryCPU, memory: memory) == .handled && queryCPU.registers[0] == 0, "commit query succeeds when usage is configured")
let low = try memory.read32(0x88), high = try memory.read32(0x8C)
check(low == 0x1234_5000 && high == 0, "commit result is a little-endian 64-bit memory value")
queryCPU.registers[0] = 0x88
queryCPU.registers[1] = cpu.registers[11]
_ = queryKernel.dispatch(0x3A, cpu: queryCPU, memory: memory)
check(queryCPU.registers[0] == KernelHandles.invalidHandle, "query rejects non-resource handle")
queryCPU.registers[0] = 0x88
queryCPU.registers[1] = resource
try memory.write32(0x80, 10)
_ = queryKernel.dispatch(0x3A, cpu: queryCPU, memory: memory)
check(queryCPU.registers[0] == 0xD8E0_07ED, "invalid resource name is rejected")
try memory.write32(0x80, 2)
queryCPU.registers[0] = 0x88
check(queryKernel.dispatch(0x3A, cpu: queryCPU, memory: memory) == .unsupported(0x3A), "unmodeled resource stays unsupported")
try memory.write32(0x80, 1)
queryCPU.registers[0] = 0x100
_ = queryKernel.dispatch(0x3A, cpu: queryCPU, memory: memory)
check(queryCPU.registers[0] == 0xE0E0_1BF5, "invalid output address fails")
print("Kernel integration: SVC creation, resource limit, handle lifetime and unsupported checks passed")
