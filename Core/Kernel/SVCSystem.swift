// input: handle, port, IPC and resource-limit SVC registers.
// output: handle table changes, HLE service replies, and resource queries.
// pos: SVC bodies for process-level kernel state and the boundary to Services.
import Foundation

extension Kernel {
    func duplicateHandle(_ cpu: ARM11CPU) {
        guard let target = object(cpu.registers[1]), let handle = create(target) else {
            cpu.registers[0] = KernelResult.invalidHandle; return
        }
        cpu.registers[0] = 0
        cpu.registers[1] = handle
    }

    func connectToPort(_ cpu: ARM11CPU) {
        var name = ""
        var address = cpu.registers[1]
        while name.count < 12, let byte = try? memory.read8(address), byte != 0 {
            name.append(Character(UnicodeScalar(byte)))
            address += 1
        }
        guard let service = services[name] else {
            stop = .unsupported("ConnectToPort(\(name))"); return
        }
        guard let handle = create(KSession(service: service)) else { cpu.registers[0] = KernelResult.outOfHandles; return }
        note("ConnectToPort(\(name))")
        cpu.registers[0] = 0
        cpu.registers[1] = handle
    }

    func sendSyncRequest(_ thread: KThread) {
        let cpu = thread.cpu
        guard let session = object(cpu.registers[0], as: KSession.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        let buffer = cpu.threadLocalStorageAddress + 0x80
        guard let bytes = try? memory.readBytes(buffer, count: 64 * 4) else { cpu.registers[0] = KernelResult.invalidAddress; return }
        let words = (0..<64).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i * 4 + $1]) << ($1 * 8) } }
        let request = IPCRequest(words: words)
        guard let reply = session.service.handle(request, kernel: self) else {
            stop = .unsupported(String(format: "%@ command 0x%04X header=%08X params=%@", session.service.name,
                                       request.command, request.header, words[1..<8].map { String(format: "%08X", $0) }.joined(separator: " ")))
            return
        }
        note(String(format: "%@ cmd 0x%04X [%@] -> %@", session.service.name, request.command,
                    words[0..<7].map { String(format: "%X", $0) }.joined(separator: " "), reply.normal.map { String(format: "%X", $0) }.joined(separator: " ")))
        try? memory.writeBytes(buffer, reply.words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        cpu.registers[0] = 0
    }

    func getResourceLimit(_ cpu: ARM11CPU) {
        guard cpu.registers[1] == Self.currentProcessHandle, let handle = create(KResourceLimit()) else {
            cpu.registers[0] = KernelResult.invalidHandle; return
        }
        cpu.registers[0] = 0
        cpu.registers[1] = handle
    }

    // Resource names: 0 priority, 1 commit, 2 thread, 3 event, 4 mutex, 5 semaphore, 6 timer, 7 shared memory, 8 arbiter, 9 CPU time.
    func resourceLimitValues(_ cpu: ARM11CPU, current: Bool) {
        let output = cpu.registers[0], count = Int(cpu.registers[3])
        guard object(cpu.registers[1], as: KResourceLimit.self) != nil else { cpu.registers[0] = KernelResult.invalidHandle; return }
        guard count > 0, count <= 10, let names = try? memory.readBytes(cpu.registers[2], count: count * 4) else {
            cpu.registers[0] = KernelResult.invalidAddress; return
        }
        let limits: [UInt64] = [0x18, UInt64(memoryLimit), 0x20, 0x20, 0x20, 8, 8, 16, 2, 0]
        let used: [UInt64] = [0, UInt64(committedBytes), UInt64(threads.filter { $0.state != .dead }.count), 0, 0, 0, 0, 0, 0, 0]
        for i in 0..<count {
            let name = (0..<4).reduce(UInt32(0)) { $0 | UInt32(names[i * 4 + $1]) << ($1 * 8) }
            guard name < 10 else { cpu.registers[0] = KernelResult.invalidEnumValue; return }
            let value = current ? used[Int(name)] : limits[Int(name)]
            try? memory.writeBytes(output + UInt32(i * 8), (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        cpu.registers[0] = 0
    }

    func outputDebugString(_ cpu: ARM11CPU) {
        let length = Int(min(cpu.registers[1], 256))
        if let bytes = try? memory.readBytes(cpu.registers[0], count: length) {
            note("debug: " + String(decoding: bytes, as: UTF8.self))
        }
    }
}
