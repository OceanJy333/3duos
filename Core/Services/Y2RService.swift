// input: y2r:u IPC commands (conversion parameters, CDMA buffers, start/stop, status queries).
// output: converted RGB data in guest memory, the transfer-end event and reply words.
// pos: HLE of the YUV-to-RGB converter used by video playback and camera previews (follows Cytrus service/cam/y2r_u.cpp).
import Foundation

final class Y2RService: HLEService {
    // Cytrus' estimate: the shortest delay that still resolves a race in the FIFA intro cutscene.
    static let completionTicks: UInt64 = 50_000
    private static let outOfRange: UInt32 = 0xE0E0_53FD, invalidEnum: UInt32 = 0xE0E0_53ED
    private static let standardCoefficients: [[Int16]] = [
        [0x100, 0x166, 0xB6, 0x58, 0x1C5, -0x166F, 0x10EE, -0x1C5B],   // Rec601, PC range
        [0x100, 0x193, 0x77, 0x2F, 0x1DB, -0x1933, 0xA7C, -0x1D51],    // Rec709, PC range
        [0x12A, 0x198, 0xD0, 0x64, 0x204, -0x1BDE, 0x10F2, -0x229B],   // Rec601, TV range
        [0x12A, 0x1CA, 0x88, 0x36, 0x21C, -0x1F04, 0x99C, -0x2421],    // Rec709, TV range
    ]

    let name = "y2r:u"
    private var config = Y2RConfig()
    private var standardCoefficient: UInt8 = 0, padding: UInt8 = 0   // only echoed back by GetPackageParameter
    private var dithering = [UInt32](repeating: 0, count: 8)
    private var spacialDithering = false, temporalDithering = false, transferEndInterrupt = false
    private let completion = KEvent(reset: .oneShot)
    private var busy = false
    private var conversionID = 0   // a stop or restart invalidates the completion already scheduled

    init() { completion.label = "Y2R completed" }

    private func setLineWidth(_ width: UInt32) -> UInt32 {
        guard width != 0, width <= 1024, width % 8 == 0 else { return Self.outOfRange }
        config.lineWidth = UInt16(width)
        return 0
    }

    // The console's camera module skips the register write for 1024 lines, so that value keeps the previous setting.
    private func setLines(_ lines: UInt32) -> UInt32 {
        guard lines != 0, lines <= 1024 else { return Self.outOfRange }
        if lines != 1024 { config.lines = UInt16(lines) }
        return 0
    }

    private func setStandardCoefficient(_ index: UInt32) -> UInt32 {
        guard Int(index) < Self.standardCoefficients.count else { return Self.invalidEnum }
        config.coefficients = Self.standardCoefficients[Int(index)]
        return 0
    }

    // Two 16-bit coefficients per IPC word.
    private static func pack(_ values: [Int16]) -> [UInt32] {
        stride(from: 0, to: values.count, by: 2).map { UInt32(UInt16(bitPattern: values[$0])) | UInt32(UInt16(bitPattern: values[$0 + 1])) << 16 }
    }

    // SetSending*/SetReceiving(address, size, transfer unit, gap, process handle): the process is always the caller's.
    private func buffer(_ request: IPCRequest) -> Y2RBuffer {
        Y2RBuffer(address: request.param(0), size: request.param(1), unit: Int(request.param(2) & 0xFFFF), gap: Int(request.param(3) & 0xFFFF))
    }

    private func startConversion(_ kernel: Kernel) {
        conversionID += 1
        let id = conversionID
        let renderer = kernel.gpu.renderer(memory: kernel.memory)
        renderer.syncGuest()
        try? Y2RConversion.run(config, memory: kernel.memory)
        // Like a GX DMA, the output may overlap a GPU surface that must now be reloaded from guest memory.
        renderer.guestWritten(config.dst.address, length: Int(config.dst.size))
        busy = true
        kernel.schedule(atTick: kernel.ticks + Self.completionTicks) { [weak self, weak kernel] in
            guard let self, let kernel, self.conversionID == id else { return }
            self.completion.signaled = true
            kernel.signalChanged(self.completion)
            self.busy = false
        }
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        let command = request.command, p = request.param(0)
        func reply(_ values: UInt32...) -> IPCReply { IPCReply(command: command, values) }
        switch command {
        case 0x01: config.inputFormat = UInt8(truncatingIfNeeded: p); return reply(0)
        case 0x02: return reply(0, UInt32(config.inputFormat))
        case 0x03: config.outputFormat = UInt8(truncatingIfNeeded: p); return reply(0)
        case 0x04: return reply(0, UInt32(config.outputFormat))
        case 0x05: config.rotation = UInt8(truncatingIfNeeded: p); return reply(0)
        case 0x06: return reply(0, UInt32(config.rotation))
        case 0x07: config.blockAlignment = UInt8(truncatingIfNeeded: p); return reply(0)
        case 0x08: return reply(0, UInt32(config.blockAlignment))
        case 0x09: spacialDithering = p & 0xFF != 0; return reply(0)
        case 0x0A: return reply(0, spacialDithering ? 1 : 0)
        case 0x0B: temporalDithering = p & 0xFF != 0; return reply(0)
        case 0x0C: return reply(0, temporalDithering ? 1 : 0)
        case 0x0D: transferEndInterrupt = p & 0xFF != 0; return reply(0)
        case 0x0E: return reply(0, transferEndInterrupt ? 1 : 0)
        case 0x0F: // GetTransferEndEvent
            return IPCReply(command: command, [0], translate: [0, kernel.create(completion) ?? 0])
        case 0x10: config.srcY = buffer(request); return reply(0)
        case 0x11: config.srcU = buffer(request); return reply(0)
        case 0x12: config.srcV = buffer(request); return reply(0)
        case 0x13: config.srcYUYV = buffer(request); return reply(0)
        case 0x14, 0x15, 0x16, 0x17, 0x19: return reply(0, 1)   // IsFinishedSending*/Receiving: transfers finish inside StartConversion
        case 0x18: config.dst = buffer(request); return reply(0)
        case 0x1A: return reply(setLineWidth(p))
        case 0x1B: return reply(0, UInt32(config.lineWidth))
        case 0x1C: return reply(setLines(p))
        case 0x1D: return reply(0, UInt32(config.lines))
        case 0x1E:
            config.coefficients = (1...4).flatMap { [Int16(truncatingIfNeeded: request.words[$0]), Int16(truncatingIfNeeded: request.words[$0] >> 16)] }
            return reply(0)
        case 0x1F: return IPCReply(command: command, [0] + Self.pack(config.coefficients))
        case 0x20: return reply(setStandardCoefficient(p))
        case 0x21:
            guard Int(p) < Self.standardCoefficients.count else { return reply(Self.invalidEnum) }
            return IPCReply(command: command, [0] + Self.pack(Self.standardCoefficients[Int(p)]))
        case 0x22: config.alpha = UInt16(truncatingIfNeeded: p); return reply(0)
        case 0x23: return reply(0, UInt32(config.alpha))
        case 0x24: dithering = (1...8).map { request.words[$0] }; return reply(0)
        case 0x25: return IPCReply(command: command, [0] + dithering)
        case 0x26: startConversion(kernel); return reply(0)
        case 0x27:
            if busy { busy = false; conversionID += 1 }
            return reply(0)
        case 0x28: return reply(0, busy ? 1 : 0)
        case 0x29: // SetPackageParameter(formats, width | lines, standard coefficient | padding | alpha)
            let q = request.param(1), r = request.param(2)
            config.inputFormat = UInt8(truncatingIfNeeded: p)
            config.outputFormat = UInt8(truncatingIfNeeded: p >> 8)
            config.rotation = UInt8(truncatingIfNeeded: p >> 16)
            config.blockAlignment = UInt8(truncatingIfNeeded: p >> 24)
            var result = setLineWidth(q & 0xFFFF)
            if result == 0 { result = setLines(q >> 16) }
            if result == 0 { result = setStandardCoefficient(r & 0xFF) }
            if result == 0 {
                standardCoefficient = UInt8(r & 0xFF)
                padding = UInt8(truncatingIfNeeded: r >> 8)
                config.alpha = UInt16(truncatingIfNeeded: r >> 16)
            }
            return reply(result)
        case 0x2A: return reply(0, 0)   // PingProcess
        case 0x2B: // DriverInitialize
            config.inputFormat = 0; config.outputFormat = 0; config.rotation = 0; config.blockAlignment = 0
            config.coefficients = [Int16](repeating: 0, count: 8)
            _ = setLineWidth(1024); _ = setLines(1024)
            config.alpha = 0
            config.srcY = Y2RBuffer(); config.srcU = Y2RBuffer(); config.srcV = Y2RBuffer(); config.dst = Y2RBuffer()
            completion.signaled = false
            return reply(0)
        case 0x2C: return reply(0)   // DriverFinalize
        case 0x2D: // GetPackageParameter: the package as SetPackageParameter received it
            let formats = UInt32(config.inputFormat) | UInt32(config.outputFormat) << 8 | UInt32(config.rotation) << 16 | UInt32(config.blockAlignment) << 24
            return reply(0, formats, UInt32(config.lineWidth) | UInt32(config.lines) << 16,
                         UInt32(standardCoefficient) | UInt32(padding) << 8 | UInt32(config.alpha) << 16)
        default:
            return nil
        }
    }
}
