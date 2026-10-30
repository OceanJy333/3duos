// input: gsp::Gpu IPC commands, the shared GSP memory page the game writes, and a 60 Hz virtual VBlank.
// output: interrupts to the game's GSP event, framebuffer configuration, memory fills, copies and display transfers
//         (GX commands run on GPUState.gx, off the emulation thread).
// pos: HLE of the GPU service; PICA command lists are handed to the renderer through `commandListHandler`.
import Foundation

final class GSPService: HLEService {
    enum Interrupt: UInt8 { case psc0 = 0, psc1, vblank0, vblank1, ppf, p3d, dma }
    static let queueSlots = 15
    static let vblankTicks: UInt64 = 4_468_531
    // Modeled GX throughput: bytes of command list, fill, copy or transfer output per ARM11 tick.
    static let bytesPerTick: UInt64 = 4

    let name = "gsp::Gpu"
    private var sharedMemory: KSharedMemory?
    private var event: KEvent?
    private weak var kernel: Kernel?
    private var busyUntil: UInt64 = 0   // modeled tick at which the queued GX commands finish
    // Called with the physical address and byte size of a PICA command list.
    var commandListHandler: ((UInt32, UInt32) -> Void)?

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        self.kernel = kernel
        let command = request.command
        switch command {
        case 0x13: // RegisterInterruptRelayQueue(flags, event)
            guard let signal = kernel.object(request.words[3], as: KEvent.self) else { return IPCReply(command: command, [KernelResult.invalidHandle, 0], translate: [0, 0]) }
            event = signal
            signal.label = "GSP interrupt"
            if sharedMemory == nil {
                sharedMemory = KSharedMemory(pages: (0..<1).map { _ in MemoryPage() })
                sharedMemory?.label = "GSP shared memory"
                kernel.hostEvents.append(HostEvent(fireAt: kernel.ticks + Self.vblankTicks, interval: Self.vblankTicks) { [weak self] in self?.vblank() })
            }
            return IPCReply(command: command, [0, 0], translate: [0, kernel.create(sharedMemory!)!])
        case 0x14, 0x15, 0x16, 0x17, 0x08, 0x09, 0x0B, 0x12, 0x19, 0x1A, 0x1C, 0x1E: // right management, cache and mode controls
            return IPCReply(command: command, [0])
        case 0x01: // WriteHWRegs(offset, size, buffer)
            let base = request.param(0), size = Int(request.param(1))
            if let bytes = try? kernel.memory.readBytes(request.words[4], count: size) {
                for i in 0..<size / 4 { writeRegister(base + UInt32(i * 4), word(bytes, i)) }
            }
            return IPCReply(command: command, [0])
        case 0x02: // WriteHWRegsWithMask(offset, size, data, mask)
            return IPCReply(command: command, [0])
        case 0x04: // ReadHWRegs(offset, size)
            let base = request.param(0), size = Int(request.param(1))
            let bytes = (0..<size / 4).flatMap { i in (0..<4).map { UInt8(truncatingIfNeeded: (kernel.gpu.registers[base + UInt32(i * 4)] ?? 0) >> ($0 * 8)) } }
            try? kernel.memory.writeBytes(request.words[4], bytes)
            return IPCReply(command: command, [0], translate: [request.words[3], request.words[4]])
        case 0x05: // SetBufferSwap(screen, FrameBufferInfo)
            apply(screen: request.param(0), info: Array(request.words[2..<9]))
            return IPCReply(command: command, [0])
        case 0x0C: // TriggerCmdReqQueue
            processCommands()
            return IPCReply(command: command, [0])
        case 0x18: // ImportDisplayCaptureInfo
            return IPCReply(command: command, [0] + [UInt32](repeating: 0, count: 14))
        default:
            return nil
        }
    }

    private func word(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index * 4 + $1]) << ($1 * 8) }
    }

    private func writeRegister(_ offset: UInt32, _ value: UInt32) { kernel?.gpu.registers[offset] = value }

    // FrameBufferInfo: active index, left address, right address, stride, format, select, unknown.
    private func apply(screen: UInt32, info: [UInt32]) {
        guard let gpu = kernel?.gpu else { return }
        if screen == 0 { gpu.top.address = info[1]; gpu.top.stride = info[3]; gpu.top.format = info[4] }
        else { gpu.bottom.address = info[1]; gpu.bottom.stride = info[3]; gpu.bottom.format = info[4] }
    }

    // MARK: Shared memory

    private func read32(_ offset: UInt32) -> UInt32 { sharedMemory.flatMap { page in
        (0..<4).reduce(0) { $0 | UInt32(page.pages[0].bytes[Int(offset) + $1]) << ($1 * 8) } } ?? 0 }

    private func write32(_ offset: UInt32, _ value: UInt32) {
        guard let page = sharedMemory?.pages[0] else { return }
        for i in 0..<4 { page.bytes[Int(offset) + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    // Relay queue (per thread, 0x40 bytes): index, count, error flag, config (bit 0 ignores VBlank), missed PDC0/PDC1
    // counters, then 0x34 slots. VBlanks never take the last slots, so GPU completions are not dropped (Cytrus gsp_gpu.cpp).
    func trigger(_ interrupt: Interrupt) {
        guard let page = sharedMemory?.pages[0], let event, let kernel else { return }
        let bytes = page.bytes
        let index = Int(bytes[0]), count = Int(bytes[1])
        if interrupt == .vblank0 || interrupt == .vblank1 {
            if bytes[3] & 1 != 0 { return }
            if count >= 0x20 {
                let offset = UInt32(interrupt == .vblank0 ? 4 : 8)
                write32(offset, read32(offset) &+ 1)
                return
            }
        }
        guard count < 0x34 else { bytes[2] = 1; return }
        bytes[0xC + (index + count) % 0x34] = interrupt.rawValue
        bytes[1] = UInt8(count + 1)
        event.signaled = true
        kernel.signalChanged(event)
    }

    private func vblank() {
        guard let kernel else { return }
        // Pending buffer swaps written by the game into its shared framebuffer info.
        for screen in 0..<2 {
            let base = UInt32(0x200 + screen * 0x40)
            let header = read32(base), index = Int(header & 1)
            if (header >> 8) & 0xFF != 0 {
                apply(screen: UInt32(screen), info: (0..<7).map { read32(base + 4 + UInt32(index) * 0x1C + UInt32($0 * 4)) })
                write32(base, header & ~0xFF00)
            }
        }
        kernel.gpu.frameCount += 1
        trigger(.vblank0)
        trigger(.vblank1)
    }

    // MARK: Command queue

    // Header: index, command count, status (1: stopped), stop request. A command whose stop byte is set halts the queue
    // after it runs; the game clears the status and triggers again (Cytrus TriggerCmdReqQueue).
    private func processCommands() {
        guard let kernel else { return }
        while true {
            let header = read32(0x800), slot = header & 0xFF, total = (header >> 8) & 0xFF
            guard total > 0 else { return }
            if header >> 24 != 0 || (header >> 16) & 1 != 0 { write32(0x800, header | 1 << 16); return }
            let words = (0..<8).map { read32(0x820 + slot * 0x20 + UInt32($0 * 4)) }
            let stop: UInt32 = (words[0] >> 16) & 0xFF != 0 ? 1 << 16 : 0
            write32(0x800, ((slot + 1) % UInt32(Self.queueSlots)) | ((total - 1) << 8) | (header & 0xFFFF_0000) | stop)
            execute(words, kernel)
        }
    }

    // Command ids: 0 DMA, 1 PICA command list, 2 memory fill, 3 display transfer, 4 texture copy, 5 cache flush.
    // Each command runs in order on the GX thread while the emulated CPU goes on. Its interrupt fires at a modeled tick
    // (fixed by command size, not host speed), so guest timing is deterministic; the emulation thread blocks there only
    // when the host has not finished the command yet.
    private func execute(_ cmd: [UInt32], _ kernel: Kernel) {
        let memory = kernel.memory, renderer = kernel.gpu.renderer(memory: memory)
        let work: () -> Void, interrupts: [Interrupt], bytes: UInt32
        switch cmd[0] & 0xFF {
        case 0:
            interrupts = [.dma]; bytes = cmd[3]
            work = {
                renderer.syncGuest()
                if let data = try? memory.readBytes(GPUState.virtualAddress(cmd[1]), count: Int(cmd[3])) { try? memory.writeBytes(GPUState.virtualAddress(cmd[2]), data) }
                renderer.guestWritten(cmd[2], length: Int(cmd[3]))
            }
        case 1:
            interrupts = [.p3d]; bytes = cmd[2]
            work = { renderer.processCommandList(address: cmd[1], size: cmd[2]) }
        case 2:
            // Only filled units interrupt, and with both in use GSP reports PSC0 alone (Cytrus video_core/gpu.cpp).
            interrupts = cmd[1] != 0 ? [.psc0] : cmd[4] != 0 ? [.psc1] : []; bytes = (cmd[3] > cmd[1] ? cmd[3] - cmd[1] : 0) + (cmd[6] > cmd[4] ? cmd[6] - cmd[4] : 0)
            work = { [self] in
                renderer.syncGuest()
                for (start, value, end, width) in [(cmd[1], cmd[2], cmd[3], (cmd[7] >> 8) & 3), (cmd[4], cmd[5], cmd[6], (cmd[7] >> 24) & 3)] where start != 0 && end > start {
                    fill(start: start, value: value, end: end, width: width, memory: memory)
                    renderer.memoryFilled(start: start, end: end, value: value, width: width)
                }
            }
        case 3:
            let transfer = DisplayTransfer(words: cmd)
            interrupts = [.ppf]; bytes = UInt32(transfer.outputWidth * transfer.outputHeight * 4)
            work = {
                renderer.finishFrame()
                renderer.displayTransfer(transfer, memory: memory)
                renderer.guestWritten(transfer.output, length: transfer.outputWidth * transfer.outputHeight * 4)
            }
        case 4:
            interrupts = [.ppf]; bytes = cmd[3]
            work = { renderer.syncGuest(); TextureCopy.run(words: cmd, memory: memory) }
        default:
            return
        }
        let job = DispatchWorkItem(block: work)
        kernel.gpu.gx.async(execute: job)
        busyUntil = max(busyUntil, kernel.ticks) + UInt64(bytes) / Self.bytesPerTick
        kernel.schedule(atTick: busyUntil) { [weak self] in
            let start = DispatchTime.now().uptimeNanoseconds
            job.wait()
            if let gpu = self?.kernel?.gpu { gpu.gxWaitNanoseconds += DispatchTime.now().uptimeNanoseconds - start }
            interrupts.forEach { self?.trigger($0) }
        }
    }

    private func fill(start: UInt32, value: UInt32, end: UInt32, width: UInt32, memory: PagedMemory) {
        let size = [2, 3, 4, 4][Int(width)]
        let address = GPUState.virtualAddress(start)
        let pattern = (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        let count = Int(end - start)
        try? memory.writeBytes(address, (0..<count).map { pattern[$0 % size] })
    }
}
