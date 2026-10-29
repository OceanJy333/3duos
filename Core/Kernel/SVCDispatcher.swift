// input: ARM11 SVC number and the trapped CPU registers
// output: handled call with 3DS ABI register results, or an unsupported call
// pos: kernel SVC boundary used after ARM11CPU.step returns supervisorCall

enum SVCDispatchResult: Equatable {
    case handled
    case unsupported(UInt32)
}

// A memory implementation must actually install the pages before the SVC succeeds.
protocol KernelMemory: ARMMemory {
    func commit(address: UInt32, size: UInt32, permission: UInt32) -> Bool
}

final class SVCDispatcher {
    let handles = KernelHandles()
    // nil means the bootstrap has not established this category's commit usage.
    var currentCommit: UInt32?
    // The boot environment selects the appropriate linear region from its kernel version.
    var linearBase: UInt32?
    private var linearBytes: UInt32 = 0

    func dispatch(_ number: UInt32, cpu: ARM11CPU, memory: ARMMemory? = nil) -> SVCDispatchResult {
        switch number {
        case 0x01:
            return controlMemory(cpu: cpu, memory: memory)
        case 0x21:
            let created = handles.createAddressArbiter()
            cpu.registers[0] = created.result
            if let handle = created.handle { cpu.registers[1] = handle }
            return .handled
        case 0x23:
            cpu.registers[0] = handles.close(cpu.registers[0])
            return .handled
        case 0x38:
            let result = handles.getResourceLimit(process: cpu.registers[1])
            cpu.registers[0] = result.result
            if let handle = result.handle { cpu.registers[1] = handle }
            return .handled
        case 0x3A:
            return getResourceLimitCurrentValues(cpu: cpu, memory: memory)
        default:
            return .unsupported(number)
        }
    }

    private func controlMemory(cpu: ARM11CPU, memory: ARMMemory?) -> SVCDispatchResult {
        let operation = cpu.registers[0], address = cpu.registers[1], address1 = cpu.registers[2]
        let size = cpu.registers[3], permission = cpu.registers[4]
        // Only the bootstrap's application COMMIT cases are modeled. Other operations and
        // kernel error cases remain visible as unsupported instead of pretending success.
        guard let memory = memory as? KernelMemory, let currentCommit,
              operation == 3 || operation == 0x10003,
              address1 == 0, size > 0, size & 0xFFF == 0,
              address & 0xFFF == 0, permission == 1 || permission == 3,
              UInt64(currentCommit) + UInt64(size) <= 0x0400_0000 else {
            return .unsupported(0x01)
        }
        let linear = operation == 0x10003
        guard !linear || address == 0 else { return .unsupported(0x01) }
        guard !linear || linearBase != nil else { return .unsupported(0x01) }
        let base = UInt64(linearBase ?? 0)
        let start = linear ? base + UInt64(linearBytes) : UInt64(address)
        guard start <= UInt32.max else { return .unsupported(0x01) }
        let target = UInt32(start)
        let end = UInt64(target) + UInt64(size)
        let bounds: Range<UInt64> = linear ? base..<(base + 0x0400_0000) : 0x0800_0000..<0x1000_0000
        guard UInt64(target) >= bounds.lowerBound, end <= bounds.upperBound,
              memory.commit(address: target, size: size, permission: permission) else {
            return .unsupported(0x01)
        }
        if linear { linearBytes += size }
        self.currentCommit = currentCommit + size
        cpu.registers[0] = KernelHandles.success
        cpu.registers[1] = target
        return .handled
    }

    private func getResourceLimitCurrentValues(cpu: ARM11CPU, memory: ARMMemory?) -> SVCDispatchResult {
        guard let memory else { return .unsupported(0x3A) }
        let output = cpu.registers[0], handle = cpu.registers[1]
        let names = cpu.registers[2], count = cpu.registers[3]
        guard handles.isResourceLimit(handle) else {
            cpu.registers[0] = KernelHandles.invalidHandle
            return .handled
        }
        guard output != 0, names != 0, count > 0, count <= UInt32(Int32.max),
              UInt64(output) + UInt64(count) * 8 <= 0x1_0000_0000 else { return .unsupported(0x3A) }
        do {
            for i in 0..<count {
                let address = UInt64(names) + UInt64(i) * 4
                guard address + 4 <= 0x1_0000_0000 else { return .unsupported(0x3A) }
                let name = try memory.read32(UInt32(address))
                guard name < 10 else {
                    cpu.registers[0] = 0xD8E0_07ED
                    return .handled
                }
                guard name == 1, currentCommit != nil else { return .unsupported(0x3A) }
            }
            guard let currentCommit else { return .unsupported(0x3A) }
            for i in 0..<count {
                let address = UInt64(output) + UInt64(i) * 8
                let value = UInt64(currentCommit)
                for byte in 0..<8 {
                    try memory.write8(UInt32(address) + UInt32(byte), UInt8(truncatingIfNeeded: value >> (byte * 8)))
                }
            }
            cpu.registers[0] = KernelHandles.success
        } catch {
            cpu.registers[0] = 0xE0E0_1BF5
        }
        return .handled
    }
}
