// input: a decoded cartridge program.
// output: a Kernel whose memory, main thread, configuration pages and services are ready to run the program.
// pos: process creation, the first step after CartridgeProgramLoader.
import Foundation

enum ProcessError: Error {
    case mapping(String)
}

enum ProcessLoader {
    static let stackTop: UInt32 = 0x1000_0000

    static func boot(_ program: CartridgeProgram, source: CartridgeSource? = nil, saveRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("3duos-saves"), traceSVC: Bool = false) throws -> Kernel {
        let kernel = Kernel()
        kernel.traceSVC = traceSVC
        let memory = kernel.memory
        func map(_ segment: CartridgeMappedSegment, _ permission: MemoryPermission) throws {
            guard let pages = memory.map(segment.address, size: UInt32(segment.bytes.count), permission: permission, kind: 3) else {
                throw ProcessError.mapping(String(format: "segment at 0x%08X", segment.address))
            }
            for (i, page) in pages.enumerated() {
                segment.bytes.withUnsafeBytes { page.bytes.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self) + i * 4096, count: 4096) }
            }
        }
        try map(program.text, [.read, .execute])
        try map(program.ro, .read)
        try map(program.data, .readWrite)
        let bssStart = program.data.address + UInt32(program.data.bytes.count)
        let bss = (program.bssSize + 0xFFF) & ~0xFFF
        let stack = (program.stackSize + 0xFFF) & ~0xFFF
        guard bss == 0 || memory.map(bssStart, size: bss, permission: .readWrite, kind: 3) != nil,
              memory.map(stackTop - stack, size: stack, permission: .readWrite, kind: 6) != nil,
              memory.map(0x1FF8_0000, size: 0x2000, permission: .read, kind: 0x20) != nil,
              memory.map(0x1FF8_2000, size: 0x1000, permission: .readWrite, kind: 0x10) != nil,
              memory.map(Kernel.vramBase, size: Kernel.vramSize, permission: .readWrite, kind: 0x21) != nil,
              memory.map(0x1FF0_0000, size: 0x8_0000, permission: .readWrite, kind: 0x22) != nil else {
            throw ProcessError.mapping("stack, BSS or system pages")
        }
        kernel.committedBytes = UInt32(program.text.bytes.count + program.ro.bytes.count + program.data.bytes.count) + bss + stack
        try writeConfiguration(memory)
        kernel.setClock()
        guard kernel.addThread(priority: 0x30, entry: program.text.address, argument: 0, stackTop: stackTop) != nil else {
            throw ProcessError.mapping("main thread")
        }
        kernel.services["srv:"] = ServiceManager()
        kernel.services["err:f"] = FatalErrorService()
        let apt = APTService()
        for name in ["APT:U", "APT:A", "APT:S"] { kernel.serviceDirectory[name] = apt }
        kernel.serviceDirectory["fs:USER"] = FSService(source: source, saveRoot: saveRoot)
        kernel.serviceDirectory["gsp::Gpu"] = GSPService()
        kernel.serviceDirectory["dsp::DSP"] = DSPService()
        kernel.serviceDirectory["y2r:u"] = Y2RService()
        let hid = HIDService()
        for name in ["hid:USER", "hid:SPVR"] { kernel.serviceDirectory[name] = hid }
        let cfg = CFGService()
        for name in ["cfg:u", "cfg:i", "cfg:s", "cfg:nor"] { kernel.serviceDirectory[name] = cfg }
        return kernel
    }

    // Configuration memory (0x1FF80000) of a retail Old 3DS on a 2.50-11 kernel.
    private static func writeConfiguration(_ memory: PagedMemory) throws {
        let fields: [(UInt32, UInt32)] = [
            (0x00, 0x0232_0B00), (0x10, 2), (0x14, 1), (0x18, 0), (0x30, 0), (0x40, 0x0400_0000),
            (0x44, 0x02C0_0000), (0x48, 0x0140_0000), (0x64, 2),
        ]
        for (offset, value) in fields { try memory.poke32(0x1FF8_0000 + offset, value) }
    }
}
