// input: GSP register writes, buffer-swap requests, and guest physical addresses.
// output: the LCD framebuffer configuration and physical-to-virtual address translation.
// pos: emulated GPU/LCD state shared by the GSP service and the display; PICA rendering attaches here.
import Foundation

struct FramebufferConfig: Equatable {
    var address: UInt32 = 0     // physical address of the left-eye buffer
    var stride: UInt32 = 0
    var format: UInt32 = 0      // low 3 bits: 0 RGBA8, 1 RGB8, 2 RGB565, 3 RGB5A1, 4 RGBA4
    var width: Int
    var bytesPerPixel: Int {
        switch format & 7 { case 0: return 4; case 1: return 3; default: return 2 }
    }
}

final class GPUState {
    var top = FramebufferConfig(width: 400)
    var bottom = FramebufferConfig(width: 320)
    var registers: [UInt32: UInt32] = [:]
    var frameCount = 0
    private var picaRenderer: PICARenderer?
    // GX commands (PICA lists, fills, copies, transfers) run here in order, overlapping the emulated CPU.
    let gx = DispatchQueue(label: "3duos.gx", qos: .userInteractive)

    // Blocks until every queued GX command has run. Call before reading GX output or renderer state on another thread
    // (native framebuffers, motion, jitter, onDraw results), e.g. once per presented frame.
    func waitForIdle() { gx.sync {} }
    var gxWaitNanoseconds: UInt64 = 0   // emulation thread blocked on GX work (GSP interrupts); a measure of GPU-side load

    // The PICA renderer renders into the guest memory it is first asked about.
    func renderer(memory: PagedMemory) -> PICARenderer {
        // PICA_SOFTWARE=1 selects the software rasterizer; PICA_SCALE=1...4 the internal resolution (default 3).
        let environment = ProcessInfo.processInfo.environment
        if picaRenderer == nil {
            picaRenderer = PICARenderer(memory: memory, metal: environment["PICA_SOFTWARE"] == nil,
                                        internalScale: environment["PICA_SCALE"].flatMap { Int($0) } ?? 3)
        }
        return picaRenderer!
    }

    // VRAM sits at physical 0x18000000 and virtual 0x1F000000; FCRAM at 0x20000000 and the kernel's linear heap base.
    static func virtualAddress(_ physical: UInt32) -> UInt32 {
        switch physical {
        case 0x1800_0000..<0x1860_0000: return physical - 0x1800_0000 + Kernel.vramBase
        case 0x2000_0000..<0x2800_0000: return physical - 0x2000_0000 + Kernel.linearBase
        default: return physical
        }
    }

    // BGR8 column-major bytes in the order FramebufferDecoder expects, or nil when nothing is configured.
    // The high-res image of the buffer a screen displays now (Metal renderer only).
    func highResFrame(_ screen: ThreeDSScreen) -> PICAHighResFrame? {
        let config = screen == .top ? top : bottom
        return config.address == 0 ? nil : picaRenderer?.highResFrame(at: config.address)
    }

    func framebuffer(_ screen: ThreeDSScreen, memory: PagedMemory) -> ThreeDSFramebuffer? {
        let config = screen == .top ? top : bottom
        guard config.address != 0, config.stride > 0 else { return nil }
        guard let raw = try? memory.readBytes(Self.virtualAddress(config.address), count: screen.width * Int(config.stride)) else { return nil }
        var bgr = Data(count: screen.width * 240 * 3)
        for x in 0..<screen.width {
            for y in 0..<240 {
                let source = x * Int(config.stride) + y * config.bytesPerPixel
                let target = x * 240 * 3 + y * 3
                switch config.format & 7 {
                case 0: bgr[target] = raw[source + 1]; bgr[target + 1] = raw[source + 2]; bgr[target + 2] = raw[source + 3]
                case 1: bgr[target] = raw[source]; bgr[target + 1] = raw[source + 1]; bgr[target + 2] = raw[source + 2]
                default:
                    let pixel = UInt16(raw[source]) | UInt16(raw[source + 1]) << 8
                    bgr[target] = UInt8((pixel & 31) << 3); bgr[target + 1] = UInt8(((pixel >> 5) & 63) << 2)
                    bgr[target + 2] = UInt8((pixel >> 11) << 3)
                }
            }
        }
        return ThreeDSFramebuffer(screen: screen, bytes: bgr)
    }
}
