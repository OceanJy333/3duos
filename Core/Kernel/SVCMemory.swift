// input: ControlMemory, QueryMemory and memory-block SVC registers.
// output: heap/linear/aliased mappings in PagedMemory with COMMIT accounting.
// pos: SVC bodies for the guest address space; the layout follows a 2.5x kernel (linear heap at 0x14000000, the layout pre-2.44 titles such as Ocarina of Time 3D convert addresses with).
import Foundation

extension Kernel {
    static let heapRange: Range<UInt32> = 0x0800_0000..<0x0E00_0000
    static let linearBase: UInt32 = 0x1400_0000
    static let linearSize: UInt32 = 0x0800_0000
    static let vramBase: UInt32 = 0x1F00_0000
    static let vramSize: UInt32 = 0x0060_0000

    func controlMemory(_ cpu: ARM11CPU) {
        let raw = cpu.registers[0], address = cpu.registers[1], source = cpu.registers[2]
        let size = cpu.registers[3], permission = MemoryPermission(rawValue: UInt8(cpu.registers[4] & 7))
        let linear = raw & 0x10000 != 0
        guard size & 0xFFF == 0, address & 0xFFF == 0 else { cpu.registers[0] = KernelResult.invalidSize; return }
        switch raw & 0xFF {
        case 3: // COMMIT
            let target = linear && address == 0 ? Self.linearBase + linearTop : address
            let range = linear ? Self.linearBase..<(Self.linearBase + Self.linearSize) : Self.heapRange
            guard UInt64(target) + UInt64(size) <= UInt64(range.upperBound), target >= range.lowerBound else {
                cpu.registers[0] = KernelResult.invalidAddress; return
            }
            guard committedBytes + size <= memoryLimit else { cpu.registers[0] = KernelResult.outOfMemory; return }
            guard memory.map(target, size: size, permission: permission, kind: linear ? 2 : 1) != nil else {
                cpu.registers[0] = KernelResult.invalidAddress; return
            }
            if linear, address == 0 { linearTop += size }
            committedBytes += size
            cpu.registers[0] = KernelResult.success
            cpu.registers[1] = target
        case 1: // FREE
            guard memory.isMapped(address, size: size) else { cpu.registers[0] = KernelResult.invalidAddress; return }
            memory.unmap(address, size: size)
            committedBytes -= min(committedBytes, size)
            cpu.registers[0] = KernelResult.success
        case 4: // MAP: alias `source` at `address`
            guard let pages = memory.backing(source, size: size),
                  memory.map(address, size: size, permission: permission, kind: 3, backing: pages) != nil else {
                cpu.registers[0] = KernelResult.invalidAddress; return
            }
            cpu.registers[0] = KernelResult.success
        case 5: // UNMAP
            memory.unmap(address, size: size)
            cpu.registers[0] = KernelResult.success
        case 6: // PROTECT
            guard memory.isMapped(address, size: size) else { cpu.registers[0] = KernelResult.invalidAddress; return }
            memory.protect(address, size: size, permission: permission)
            cpu.registers[0] = KernelResult.success
        default:
            stop = .unsupported(String(format: "ControlMemory op 0x%X", raw))
        }
    }

    func queryMemory(_ cpu: ARM11CPU) {
        let info = memory.query(cpu.registers[2])
        cpu.registers[0] = KernelResult.success
        cpu.registers[1] = info.base
        cpu.registers[2] = info.size
        cpu.registers[3] = UInt32(info.permission.rawValue)
        cpu.registers[4] = info.permission.isEmpty && info.kind == 0 ? 0 : 5
        cpu.registers[5] = 0
    }

    func createMemoryBlock(_ cpu: ARM11CPU) {
        // r0 other-process permission, r1 address, r2 size, r3 own permission (permissions are not enforced).
        let address = cpu.registers[1], size = cpu.registers[2]
        guard size & 0xFFF == 0, size > 0 else { cpu.registers[0] = KernelResult.invalidSize; return }
        // A block over the caller's own mapped memory shares those pages; address 0 asks for fresh memory.
        let pages = address == 0 ? (0..<Int(size >> 12)).map { _ in MemoryPage() } : memory.backing(address, size: size)
        guard let pages, let handle = create(KSharedMemory(pages: pages)) else {
            cpu.registers[0] = KernelResult.invalidAddress; return
        }
        cpu.registers[0] = KernelResult.success
        cpu.registers[1] = handle
    }

    func mapMemoryBlock(_ cpu: ARM11CPU) {
        guard let block = object(cpu.registers[0], as: KSharedMemory.self) else {
            cpu.registers[0] = KernelResult.invalidHandle; return
        }
        let permission = MemoryPermission(rawValue: UInt8(cpu.registers[2] & 7))
        let size = UInt32(block.pages.count) << 12
        guard memory.map(cpu.registers[1], size: size, permission: permission, kind: 4, backing: block.pages) != nil else {
            cpu.registers[0] = KernelResult.invalidAddress; return
        }
        cpu.registers[0] = KernelResult.success
    }

    func unmapMemoryBlock(_ cpu: ARM11CPU) {
        guard let block = object(cpu.registers[0], as: KSharedMemory.self) else {
            cpu.registers[0] = KernelResult.invalidHandle; return
        }
        memory.unmap(cpu.registers[1], size: UInt32(block.pages.count) << 12)
        cpu.registers[0] = KernelResult.success
    }
}
