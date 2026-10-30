// input: dsp::DSP commands (component load, interrupt events, pipes) and a 160-sample audio-frame clock.
// output: pipe replies with the audio shared-memory layout; every audio frame, source status, mixed samples and host sound.
// pos: HLE of the audio DSP (follows Citra/Cytrus audio_core/hle/hle.cpp and service/dsp/dsp_dsp.cpp).
import Foundation

final class DSPService: HLEService {
    static let frameTicks: UInt64 = 1_310_720   // 160 samples at 32728.5 Hz
    static let ramBase: UInt32 = 0x1FF0_0000
    static let regions: [UInt32] = [0x1FF5_0000, 0x1FF7_0000]   // the game fills one while the DSP reads the other

    // Byte offsets inside a region, announced on the audio pipe as DSP word addresses (0x8000 + offset / 2).
    enum Offset {
        static let frameCounter = 0x7FFE, sourceConfig = 0x3D24, sourceStatus = 0xD00, adpcm = 0x4F24, dspConfig = 0x2860
        static let dspStatus = 0x800, finalSamples = 0xA80, intermediate = 0x2924, compressor = 0xE20, debug = 0x820
        static let announced = [frameCounter, sourceConfig, sourceStatus, adpcm, dspConfig, dspStatus, finalSamples,
                                intermediate, compressor, debug, 0x5224, 0x5424, 0x55A4, 0x58A4, 0x58B8]
    }

    let name = "dsp::DSP"
    private var semaphoreHandle: UInt32?
    private var interruptEvents: [UInt32: KEvent] = [:]
    private var pipes: [UInt32: [UInt8]] = [:]
    private var audioOn = false
    private let sources = (0..<24).map { _ in AudioSource() }
    private let mixer = AudioMixer()
    private lazy var output = AudioOutput()
    private weak var kernel: Kernel?

    private func signal(_ key: UInt32) {
        guard let event = interruptEvents[key], let kernel else { return }
        event.signaled = true
        kernel.signalChanged(event)
    }

    // The region with the newer frame counter (allowing for wraparound) is the one the game finished writing.
    private func readRegion(_ memory: PagedMemory) -> Int {
        let a = (try? memory.read16(Self.regions[0] + UInt32(Offset.frameCounter))) ?? 0
        let b = (try? memory.read16(Self.regions[1] + UInt32(Offset.frameCounter))) ?? 0
        if a == 0xFFFF, b != 0xFFFE { return 1 }
        if b == 0xFFFF, a != 0xFFFE { return 0 }
        return a > b ? 0 : 1
    }

    private func audioFrame() {
        guard audioOn, let kernel else { return }
        let memory = kernel.memory, index = readRegion(memory)
        let read = Self.regions[index], write = Self.regions[1 - index]
        func bytes(_ base: UInt32, _ offset: Int, _ count: Int) -> [UInt8] { (try? memory.readBytes(base + UInt32(offset), count: count)) ?? [UInt8](repeating: 0, count: count) }
        let configs = bytes(read, Offset.sourceConfig, 24 * 192), coefficients = bytes(read, Offset.adpcm, 24 * 32)
        var mixes = [[SIMD4<Int32>]](repeating: [SIMD4<Int32>](repeating: .zero, count: samplesPerFrame), count: 3)
        var statuses: [UInt8] = []
        for (i, source) in sources.enumerated() {
            if source.parse(Array(configs[i * 192..<(i + 1) * 192]), coefficients: Array(coefficients[i * 32..<(i + 1) * 32])) {
                try? memory.writeBytes(read + UInt32(Offset.sourceConfig + i * 192), [0, 0, 0, 0])
            }
            source.tick()
            source.mix(into: &mixes)
            statuses += source.status
        }
        try? memory.writeBytes(write + UInt32(Offset.sourceStatus), statuses)
        if mixer.parse(bytes(read, Offset.dspConfig, 196)) { try? memory.writeBytes(read + UInt32(Offset.dspConfig), [0, 0, 0, 0]) }
        var aux = bytes(write, Offset.intermediate, 5120)
        let final = mixer.mix(mixes, auxIn: bytes(read, Offset.intermediate, 5120), auxOut: &aux)
        try? memory.writeBytes(write + UInt32(Offset.intermediate), aux)
        try? memory.writeBytes(write + UInt32(Offset.finalSamples), final.flatMap { s in
            [UInt8(truncatingIfNeeded: s.0), UInt8(truncatingIfNeeded: s.0 >> 8), UInt8(truncatingIfNeeded: s.1), UInt8(truncatingIfNeeded: s.1 >> 8)] })
        output.push(final)
        signal(0x202)
    }

    private func writeStructAddresses() {
        let words = [UInt16(Offset.announced.count)] + Offset.announced.map { UInt16(0x8000 + $0 / 2) }
        pipes[2, default: []] += words.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        signal(0x202)
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        if self.kernel == nil {
            self.kernel = kernel
            sources.forEach { $0.memory = kernel.memory }
            kernel.hostEvents.append(HostEvent(fireAt: kernel.ticks + Self.frameTicks, interval: Self.frameTicks) { [weak self] in self?.audioFrame() })
        }
        let command = request.command
        switch command {
        case 0x01: // RecvData(register): 0 while the DSP is on, 1 once it is off or asleep
            return IPCReply(command: command, [0, audioOn ? 0 : 1])
        case 0x02: // RecvDataIsReady
            return IPCReply(command: command, [0, 1])
        case 0x07, 0x12, 0x13, 0x14, 0x17: // SetSemaphore, UnloadComponent, cache flush/invalidate, SetSemaphoreMask
            return IPCReply(command: command, [0])
        case 0x0C: // ConvertProcessAddressFromDspDram
            return IPCReply(command: command, [0, (request.param(0) << 1) &+ Self.ramBase + 0x4_0000])
        case 0x0D: // WriteProcessPipe(channel, size, buffer)
            let channel = request.param(0), size = Int(request.param(1))
            if channel == 2, let data = try? kernel.memory.readBytes(request.words[4], count: size), data.count == 4 {
                // Pipe state change: 0 initialize, 1 shutdown, 2 wake up, 3 sleep.
                switch data[0] {
                case 0:
                    for region in Self.regions { try? kernel.memory.writeBytes(region, [UInt8](repeating: 0, count: 0x8000)) }
                    sources.forEach { $0.reset() }
                    pipes = [:]
                    writeStructAddresses(); audioOn = true
                case 1: audioOn = false
                case 2: pipes = [:]; writeStructAddresses(); audioOn = true
                default: writeStructAddresses(); audioOn = false
                }
            }
            return IPCReply(command: command, [0])
        case 0x0F: // GetPipeReadableSize(channel, peer)
            return IPCReply(command: command, [0, UInt32(pipes[request.param(0)]?.count ?? 0)])
        case 0x0E, 0x10: // ReadPipe, ReadPipeIfPossible(channel, peer, size, buffer)
            // The reply data goes to the static buffer the caller registered at TLS + 0x180.
            let channel = request.param(0), wanted = Int(request.param(2) & 0xFFFF)
            let bytes = Array((pipes[channel] ?? []).prefix(wanted))
            pipes[channel] = Array((pipes[channel] ?? []).dropFirst(bytes.count))
            let slot = kernel.current.cpu.threadLocalStorageAddress + 0x180
            let pointer = (try? kernel.memory.peek32(slot + 4)) ?? 0
            try? kernel.memory.writeBytes(pointer, bytes)
            return IPCReply(command: command, [0, UInt32(bytes.count)], translate: [UInt32(bytes.count) << 14 | 2, pointer])
        case 0x11: // LoadComponent(size, program mask, data mask, buffer)
            return IPCReply(command: command, [0, 1], translate: [request.words[4], request.words[5]])
        case 0x15: // RegisterInterruptEvents(interrupt, channel, event)
            let key = request.param(0) << 8 | request.param(1)
            if let event = kernel.object(request.words[4], as: KEvent.self) {
                event.label = String(format: "DSP interrupt %d/%d", request.param(0), request.param(1))
                interruptEvents[key] = event
            } else { interruptEvents[key] = nil }
            return IPCReply(command: command, [0])
        case 0x16: // GetSemaphoreEventHandle
            if semaphoreHandle == nil {
                let event = KEvent(reset: .oneShot)
                event.label = "DSP semaphore"
                semaphoreHandle = kernel.create(event)
            }
            return IPCReply(command: command, [0], translate: [0, semaphoreHandle!])
        case 0x1F: // GetHeadphoneStatus
            return IPCReply(command: command, [0, 0])
        case 0x20: // ForceHeadphoneOut
            return IPCReply(command: command, [0])
        default:
            return nil
        }
    }
}
