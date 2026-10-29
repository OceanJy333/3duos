// Input: the top or bottom screen and a small synthetic A32 program.
// Output: a labeled framebuffer modified by ARM11CPU and decoded to RGBA.
// Pos: core-to-Metal integration demonstration; no game code is executed.
import UIKit

enum TestFrameError: LocalizedError {
    case displayUnavailable, cpuStopped(ARMStop)
    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "Metal test frame could not be displayed."
        case .cpuStopped(let reason): return "CPU test stopped: \(reason)"
        }
    }
}

private final class TestMemory: ARMMemory {
    // MOV r1,#48; STRB r1,[r0],#1; SUBS r2,r2,#1; BNE to STRB; SVC #0.
    private let program: [UInt32] = [0xE3A01030, 0xE4C01001, 0xE2522001, 0x1AFFFFFC, 0xEF000000]
    var framebuffer: Data
    init(_ framebuffer: Data) { self.framebuffer = framebuffer }
    func read8(_ address: UInt32) throws -> UInt8 { framebuffer[Int(address - 0x1000)] }
    func read32(_ address: UInt32) throws -> UInt32 { program[Int(address / 4)] }
    func write8(_ address: UInt32, _ value: UInt8) throws { framebuffer[Int(address - 0x1000)] = value }
    func write32(_ address: UInt32, _ value: UInt32) throws {
        for i in 0..<4 { try write8(address + UInt32(i), UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
}

enum TestFrame {
    static func make(_ screen: ThreeDSScreen) throws -> DecodedScreenFrame {
        let width = screen.width, height = screen.height
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(UIColor(red: 0.08, green: 0.17, blue: 0.20, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let detail = screen == .top ? "TOP SCREEN · ARM11 → METAL" : "BOTTOM SCREEN · 游戏执行开发中"
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("自研核心测试帧" as NSString).draw(in: CGRect(x: 10, y: 83, width: width - 20, height: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24, weight: .bold),
                                 .foregroundColor: UIColor.white, .paragraphStyle: style])
            (detail as NSString).draw(in: CGRect(x: 10, y: 132, width: width - 20, height: 30),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: UIColor.systemTeal, .paragraphStyle: style])
            UIGraphicsPopContext()
        }
        var bgr = Data(count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let source = (y * width + x) * 4, dest = x * height * 3 + (height - 1 - y) * 3
                bgr[dest] = pixels[source + 2]; bgr[dest + 1] = pixels[source + 1]; bgr[dest + 2] = pixels[source]
            }
        }
        let memory = TestMemory(bgr)
        let cpu = ARM11CPU()
        cpu.registers[0] = 0x1000
        cpu.registers[2] = 720
        var stop = ARMStop.running
        while stop == .running { stop = cpu.step(memory: memory) }
        guard stop == .supervisorCall(0), cpu.registers[2] == 0,
              memory.framebuffer.prefix(720).allSatisfy({ $0 == 48 }) else {
            throw TestFrameError.cpuStopped(stop)
        }
        return try FramebufferDecoder.decode(ThreeDSFramebuffer(screen: screen, bytes: memory.framebuffer))
    }
}
