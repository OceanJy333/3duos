// input: synthetic programs and an optional local decrypted CXI path.
// output: bounded boot assertions and an observed stop for the supplied game.
// pos: standalone verification of program mapping and the first execution boundary.
import Foundation

func segment(_ address: UInt32, _ words: [UInt32]) -> CartridgeMappedSegment {
    let bytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
    return CartridgeMappedSegment(address: address, bytes: Data(bytes), usedSize: UInt32(bytes.count))
}
func program(_ words: [UInt32]) -> CartridgeProgram {
    CartridgeProgram(text: segment(0x0010_0000, words), ro: segment(0x0020_0000, [0x12345678]),
                     data: segment(0x0030_0000, [0x87654321]), bssSize: 16, stackSize: 0x1000)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let memory = try ProgramMemory(program: program([0xEF000042]))
let readText = try memory.read32(0x0010_0000)
let readRO = try memory.read32(0x0020_0000)
let readData = try memory.read32(0x0030_0000)
let readBSS = try memory.read32(0x0030_0004)
let readStack = try memory.read32(0x0FFF_FFFC)
check(readText == 0xEF000042 && readRO == 0x12345678 && readData == 0x87654321, "segment mapping")
check(readBSS == 0 && readStack == 0, "zeroed BSS and stack")
try memory.write32(0x0030_0004, 42)
let written = try memory.read32(0x0030_0004)
check(written == 42, "writable BSS")
let tlsStart = try memory.read32(ProgramMemory.mainThreadTLS)
check(tlsStart == 0, "zeroed TLS")
try memory.write32(ProgramMemory.mainThreadTLS + 0x80, 0x12345678)
let tlsIPC = try memory.read32(ProgramMemory.mainThreadTLS + 0x80)
check(tlsIPC == 0x12345678, "writable TLS IPC buffer")
let memType = try memory.read32(0x1FF8_0030)
let allocation = try memory.read32(0x1FF8_0040)
check(memType == 0 && allocation == 0x0400_0000, "Old3DS application memory configuration")
do { try memory.write32(0x1FF8_0040, 0); fatalError("configuration page must be read-only") }
catch ProgramMemoryError.address(0x1FF8_0040) { }
do { _ = try memory.read32(0x1FF8_0044); fatalError("unknown configuration field must fault") }
catch ProgramMemoryError.address(0x1FF8_0044) { }
do { _ = try memory.read32(0x0040_0000); fatalError("unmapped read should fail") }
catch ProgramMemoryError.address(0x0040_0000) { }
let heapKernel = SVCDispatcher(), heapCPU = ARM11CPU()
heapKernel.currentCommit = 0x2000
heapKernel.linearBase = 0x1400_0000
heapCPU.registers[0...4] = [0x10003, 0, 0, 0x2000, 3]
check(heapKernel.dispatch(1, cpu: heapCPU, memory: memory) == .handled, "linear commit succeeds")
check(heapCPU.registers[0] == 0 && heapCPU.registers[1] == 0x1400_0000 && heapKernel.currentCommit == 0x4000, "linear result and accounting")
let heapZero = try memory.read32(0x1400_1000)
check(heapZero == 0, "new pages are zeroed")
try memory.write32(0x1400_1000, 0x1234_5678)
let heapValue = try memory.read32(0x1400_1000)
check(heapValue == 0x1234_5678, "committed pages are writable")
heapCPU.registers[0...4] = [0x10003, 0, 0, 0x1000, 3]
check(heapKernel.dispatch(1, cpu: heapCPU, memory: memory) == .handled && heapCPU.registers[1] == 0x1400_2000, "next linear allocation follows the first")
heapCPU.registers[0...4] = [3, 0x0800_0000, 0, 0x1000, 1]
check(heapKernel.dispatch(1, cpu: heapCPU, memory: memory) == .handled && heapCPU.registers[1] == 0x0800_0000, "fixed heap commit")
do { try memory.write32(0x0800_0000, 42); fatalError("read-only heap must reject writes") }
catch ProgramMemoryError.address(0x0800_0000) { }
heapCPU.registers[0...4] = [3, 0x0800_0000, 0, 0x1000, 3]
let overlapRegisters = heapCPU.registers
check(heapKernel.dispatch(1, cpu: heapCPU, memory: memory) == .unsupported(1) && heapCPU.registers == overlapRegisters && heapKernel.currentCommit == 0x6000, "overlap has no side effects")
heapCPU.registers[0...4] = [1, 0x0800_0000, 0, 0x1000, 0]
check(heapKernel.dispatch(1, cpu: heapCPU, memory: memory) == .unsupported(1), "unimplemented free stays unsupported")
let heapResource = heapKernel.handles.getResourceLimit(process: KernelHandles.currentProcess).handle!
try memory.write32(0x0030_0004, 1)
heapCPU.registers[0...3] = [0x0FFF_FFF0, heapResource, 0x0030_0004, 1]
check(heapKernel.dispatch(0x3A, cpu: heapCPU, memory: memory) == .handled, "commit usage query succeeds after allocations")
let heapUsage = try memory.read32(0x0FFF_FFF0)
check(heapUsage == 0x6000, "commit query includes newly allocated pages")
let unsetKernel = SVCDispatcher()
heapCPU.registers[0...4] = [0x10003, 0, 0, 0x1000, 3]
check(unsetKernel.dispatch(1, cpu: heapCPU, memory: memory) == .unsupported(1), "unknown capacity stays unsupported")
unsetKernel.currentCommit = 0x0400_0000
unsetKernel.linearBase = 0x1400_0000
check(unsetKernel.dispatch(1, cpu: heapCPU, memory: memory) == .unsupported(1) && unsetKernel.currentCommit == 0x0400_0000, "capacity exhaustion has no accounting side effect")
let svc = try BootProbe.run(program([0xE3A00001, 0xEF000042]))
check(svc.stop == .supervisorCall(0x42) && svc.pc == 0x0010_0004 && svc.instruction == 0xEF000042 && svc.instructionCount == 2, "SVC stop")
let handled = try BootProbe.run(program([0xEF000021, 0xEF000042]), hle: true)
check(handled.stop == .supervisorCall(0x42) && handled.pc == 0x0010_0004 && handled.instructionCount == 2 && handled.handledSVCCount == 1 && handled.unsupportedSVC == 0x42, "handled and unsupported SVC")
// Read TLS through MRC, write and read its IPC buffer, then branch on the value.
let tls = try BootProbe.run(program([0xEE1D0F70, 0xE3A0102A, 0xE5801080, 0xE5902080,
                                     0xE352002A, 0x1F000043, 0xEF000042]))
check(tls.stop == .supervisorCall(0x42) && tls.instructionCount == 7, "TLS CPU address and memory access")
// The booted application context enables VFP before it writes FPSCR.
let vfp = try BootProbe.run(program([0xE3A00000, 0xEEE10A10, 0xEF000042]))
check(vfp.stop == .supervisorCall(0x42) && vfp.instructionCount == 3, "VFP enabled at entry")
let config = try BootProbe.run(program([0xE59F000C, 0xE5901040, 0xE3510301,
                                        0x1F000043, 0xEF000042, 0x1FF80000]))
check(config.stop == .supervisorCall(0x42) && config.instructionCount == 5, "CPU reads configured APPMEMALLOC")
let unknown = try BootProbe.run(program([0xE0000090]))
check(unknown.stop == .undefined(0x0010_0000, 0xE0000090) && unknown.instructionCount == 1, "unsupported instruction")
let loop = try BootProbe.run(program([0xEAFFFFFE]), limit: 7)
check(loop.stop == .running && loop.pc == 0x0010_0000 && loop.instruction == 0xEAFFFFFE && loop.instructionCount == 7, "bounded loop")
let thumb = try BootProbe.run(program([0xE28F0001, 0xE12FFF10, 0x0000B500]))
check(thumb.stop == .unsupportedThumb(0x0010_0008) && thumb.pc == 0x0010_0008 && thumb.instruction == 0xB500 && thumb.instructionCount == 2, "Thumb boundary")
let fault = try BootProbe.run(program([0xE5910000]))
if case .memoryFault(0x0010_0000, _) = fault.stop {
    check(fault.instruction == 0xE5910000 && fault.instructionCount == 1, "memory fault context")
} else { fatalError("expected memory fault") }
print("Boot probe synthetic checks passed")

if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let cartridge = try CartridgeReader.read(url: url)
    let decoded = try CartridgeProgramLoader.load(cartridge, from: url)
    let options = Array(CommandLine.arguments.dropFirst(2))
    let limit = options.first(where: { !$0.hasPrefix("--") }).map { Int($0) ?? 0 } ?? 10_000
    guard limit > 0 else { fatalError("instruction limit must be positive") }
    let hle = options.contains("--hle")
    let estimatedCommit = options.contains("--estimated-commit") ?
        UInt32(decoded.text.bytes.count + decoded.ro.bytes.count + decoded.data.bytes.count
               + ((Int(decoded.bssSize) + 0xFFF) & ~0xFFF) + Int(decoded.stackSize)) : nil
    let result = try BootProbe.run(decoded, limit: limit, hle: hle, currentCommit: estimatedCommit)
    check(result.instructionCount > 0 && result.instructionCount <= UInt64(limit), "game instruction count")
    let instruction = result.instruction.map { String(format: "0x%08X", $0) } ?? "unreadable"
    print(String(format: "entry=0x%08X pc=0x%08X instruction=%@ count=%llu stop=%@ handledSVC=%d unsupportedSVC=%@ estimatedCommit=%@", decoded.text.address, result.pc, instruction, result.instructionCount, String(describing: result.stop), result.handledSVCCount, result.unsupportedSVC.map { String(format: "0x%X", $0) } ?? "none", estimatedCommit.map(String.init) ?? "none"))
}
