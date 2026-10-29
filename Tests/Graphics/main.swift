// Input: synthetic 3DS BGR8 framebuffers with known corner colors.
// Output: decoder assertions and a two-layer macOS Metal validation window.
// Pos: standalone diagnostic, not an emulator or game screenshot.
import AppKit
import QuartzCore

func rgb(_ screen: ThreeDSScreen, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let right = x >= screen.width / 2
    let bottom = y >= 120
    if screen == .top {
        switch (right, bottom) {
        case (false, false): return (255, 0, 0)
        case (true, false): return (0, 255, 0)
        case (false, true): return (0, 0, 255)
        default: return (255, 255, 0)
        }
    }
    switch (right, bottom) {
    case (false, false): return (255, 0, 255)
    case (true, false): return (0, 255, 255)
    case (false, true): return (255, 255, 255)
    default: return (64, 64, 64)
    }
}

func fixture(_ screen: ThreeDSScreen) -> ThreeDSFramebuffer {
    let stride = 728 // Includes 8 bytes of column padding.
    var bytes = Data(repeating: 0x55, count: screen.width * stride)
    for x in 0..<screen.width {
        for y in 0..<240 {
            let (r, g, b) = rgb(screen, x, y)
            let i = x * stride + (239 - y) * 3
            bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r
        }
    }
    return ThreeDSFramebuffer(screen: screen, bytes: bytes, stride: stride)
}

func checkDecoder(_ screen: ThreeDSScreen) throws -> DecodedScreenFrame {
    let frame = try FramebufferDecoder.decode(fixture(screen))
    let samples = [(0, 0), (screen.width - 1, 0), (0, 239), (screen.width - 1, 239),
                   (screen.width / 2, 120)]
    for (x, y) in samples {
        let (r, g, b) = rgb(screen, x, y)
        let i = (y * screen.width + x) * 4
        precondition(Array(frame.rgba[i..<i + 4]) == [r, g, b, 255], "bad pixel at \(x),\(y)")
    }
    return frame
}

let top = try checkDecoder(.top)
let bottom = try checkDecoder(.bottom)
do {
    _ = try FramebufferDecoder.decode(ThreeDSFramebuffer(screen: .top, bytes: Data()))
    fatalError("short framebuffer accepted")
} catch FramebufferError.insufficientBytes {}
print("Decoder: top and bottom corner colors, column padding and short-buffer checks passed")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 500),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "3DS synthetic framebuffer Metal validation"
window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
window.contentView!.wantsLayer = true
window.contentView!.layer!.backgroundColor = NSColor.black.cgColor
let topLayer = CAMetalLayer()
topLayer.frame = CGRect(x: 0, y: 260, width: 400, height: 240)
topLayer.drawableSize = CGSize(width: 400, height: 240)
let bottomLayer = CAMetalLayer()
bottomLayer.frame = CGRect(x: 40, y: 0, width: 320, height: 240)
bottomLayer.drawableSize = CGSize(width: 320, height: 240)
window.contentView!.layer!.addSublayer(topLayer)
window.contentView!.layer!.addSublayer(bottomLayer)
let topPresenter = try MetalScreenPresenter(layer: topLayer)
let bottomPresenter = try MetalScreenPresenter(layer: bottomLayer)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    precondition(topPresenter.present(top) && bottomPresenter.present(bottom), "Metal submission failed")
    print("Metal: submitted both synthetic screens")
    fflush(stdout)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 12) { app.terminate(nil) }
app.run()
