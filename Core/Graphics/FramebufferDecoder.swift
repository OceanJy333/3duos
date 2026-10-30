// Input: 3DS LCD framebuffer bytes in rotated, linear BGR8 order.
// Output: landscape RGBA8 pixels for a top or bottom screen.
// Pos: boundary between a future emulation core and the screen presenter.
import Foundation

enum ThreeDSScreen {
    case top, bottom

    var width: Int { self == .top ? 400 : 320 }
    var height: Int { 240 }
}

struct ThreeDSFramebuffer {
    let screen: ThreeDSScreen
    let bytes: Data
    // Distance between successive 240-pixel columns, in bytes.
    let stride: Int

    init(screen: ThreeDSScreen, bytes: Data, stride: Int = 240 * 3) {
        self.screen = screen
        self.bytes = bytes
        self.stride = stride
    }
}

struct DecodedScreenFrame {
    let screen: ThreeDSScreen
    let rgba: Data
    var depth: [Float]? = nil   // row-major 0...1, nearer is smaller; nil when the renderer has none
    var motion: [SIMD2<Float>]? = nil   // previous minus current position in LCD pixels; nil falls back to block matching
    var jitter = SIMD2<Float>.zero      // sub-pixel offset the renderer applied to this frame, in LCD pixels
}

enum FramebufferError: Error {
    case invalidStride
    case insufficientBytes
}

enum FramebufferDecoder {
    static func decode(_ frame: ThreeDSFramebuffer) throws -> DecodedScreenFrame {
        guard frame.stride >= 240 * 3 else { throw FramebufferError.invalidStride }
        let width = frame.screen.width
        guard frame.bytes.count >= (width - 1) * frame.stride + 240 * 3 else {
            throw FramebufferError.insufficientBytes
        }
        var output = Data(count: width * 240 * 4)
        frame.bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                let src = input.bindMemory(to: UInt8.self)
                let dst = result.bindMemory(to: UInt8.self)
                for y in 0..<240 {
                    for x in 0..<width {
                        let source = x * frame.stride + (239 - y) * 3
                        let target = (y * width + x) * 4
                        dst[target] = src[source + 2]
                        dst[target + 1] = src[source + 1]
                        dst[target + 2] = src[source]
                        dst[target + 3] = 255
                    }
                }
            }
        }
        return DecodedScreenFrame(screen: frame.screen, rgba: output)
    }
}
