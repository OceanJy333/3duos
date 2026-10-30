// input: a booted Kernel from the self-developed core.
// output: the kernel stepped in slices on its own queue, plus the latest LCD frames and stop state for the UI.
// pos: bridge between the emulator core and the app's Metal screens.
import Foundation

final class GameRunner {
    struct Snapshot {
        var top: ThreeDSFramebuffer?
        var bottom: ThreeDSFramebuffer?
        var topHighRes: PICAHighResFrame?
        var bottomHighRes: PICAHighResFrame?
        var frames = 0
        var speed = 1.0          // emulated seconds per wall second; 1 means real time, capped there
        var stop: KernelStop?
    }

    private let kernel: Kernel
    private let queue = DispatchQueue(label: "3duos.core", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = Snapshot()
    private var cancelled = false

    private let hid: HIDService?
    private var buttons: UInt32 = 0

    init(kernel: Kernel) {
        self.kernel = kernel
        hid = kernel.serviceDirectory["hid:USER"] as? HIDService
        // The screens show the GPU's high-res frames; native LCD copies are made only for transfers the GPU did not render.
        kernel.gpu.renderer(memory: kernel.memory).keepsNativeFrames = false
    }

    private static let bits: [ConsoleButtonID: UInt32] = [
        .a: 1 << 0, .b: 1 << 1, .select: 1 << 2, .start: 1 << 3, .right: 1 << 4, .left: 1 << 5, .up: 1 << 6, .down: 1 << 7,
        .rightTrigger: 1 << 8, .leftTrigger: 1 << 9, .x: 1 << 10, .y: 1 << 11]

    func button(_ id: ConsoleButtonID, pressed: Bool) {
        guard let bit = Self.bits[id], let hid else { return }
        buttons = pressed ? buttons | bit : buttons & ~bit
        var input = hid.input
        input.buttons = buttons
        hid.input = input
    }

    func stick(_ position: (x: Float, y: Float)) {
        guard let hid else { return }
        var input = hid.input
        input.circle = (Int16(max(-1, min(1, position.x)) * 156), Int16(max(-1, min(1, position.y)) * 156))
        hid.input = input
    }

    // `point` is normalized over the 320x240 bottom screen; nil releases the touch.
    func touch(_ point: CGPoint?) {
        guard let hid else { return }
        var input = hid.input
        input.touch = point.map { (UInt16($0.x * 320), UInt16($0.y * 240)) }
        hid.input = input
    }

    // Before start(): the internal resolution as a multiple of the LCD. PICA_SCALE in the environment wins.
    func setInternalScale(_ scale: Int) {
        guard ProcessInfo.processInfo.environment["PICA_SCALE"] == nil else { return }
        kernel.gpu.renderer(memory: kernel.memory).internalScale = scale
    }

    // Before start(): temporal MetalFX needs jitter, exact motion and the reactive mask from the renderer.
    func setMetalFXInputs(_ on: Bool) { kernel.gpu.renderer(memory: kernel.memory).emitsMotionInputs = on }

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return latest }

    private static let ticksPerSecond = 268_111_856.0

    // Sleeps when the core runs ahead of the 3DS clock, so the host idles instead of spinning at full speed; falls
    // back to measuring when it is slower than real time. Returns the speed over the last second.
    private func pace(_ clock: inout (wall: UInt64, ticks: UInt64, speed: Double)) {
        let now = DispatchTime.now().uptimeNanoseconds
        let emulated = Double(kernel.ticks - clock.ticks) / Self.ticksPerSecond, elapsed = Double(now - clock.wall) / 1e9
        if emulated > elapsed + 0.002 { Thread.sleep(forTimeInterval: emulated - elapsed) }
        if elapsed >= 1 {
            clock.speed = min(1, emulated / elapsed)
            clock.wall = now; clock.ticks = kernel.ticks
        }
    }

    func start() {
        queue.async { [self] in
            var publishedFrame = -1
            // TDS_INPUT="start@1800,a@2600,stickright@3000,stickcenter@3010": scripted input by frame counter, for checks.
            let sticks: [String: (x: Float, y: Float)] = ["stickright": (1, 0), "stickleft": (-1, 0), "stickup": (0, 1), "stickdown": (0, -1), "stickcenter": (0, 0)]
            let names = Dictionary(uniqueKeysWithValues: Self.bits.keys.map { ("\($0)", $0) })
            var script = (ProcessInfo.processInfo.environment["TDS_INPUT"] ?? "").split(separator: ",").compactMap { step -> (String, Int)? in
                let parts = step.split(separator: "@")
                return parts.count == 2 ? Int(parts[1]).map { (String(parts[0]), $0) } : nil
            }
            var clock = (wall: DispatchTime.now().uptimeNanoseconds, ticks: kernel.ticks, speed: 1.0)
            while true {
                lock.lock(); let done = cancelled; lock.unlock()
                if done { return }
                let result = kernel.run(instructionBudget: 50_000)
                pace(&clock)
                let frame = kernel.gpu.frameCount
                guard frame != publishedFrame || result != .budgetReached else { continue }
                publishedFrame = frame
                while let step = script.first, frame >= step.1 {
                    if let id = names[step.0] { button(id, pressed: true); button(id, pressed: false) } else if let position = sticks[step.0] { stick(position) }
                    script.removeFirst()
                }
                // GPU-rendered screens are shown at the internal resolution; only the others are read back at 400x240.
                let topHighRes = kernel.gpu.highResFrame(.top), bottomHighRes = kernel.gpu.highResFrame(.bottom)
                if topHighRes == nil || bottomHighRes == nil { kernel.gpu.waitForIdle() }
                let top = topHighRes == nil ? kernel.gpu.framebuffer(.top, memory: kernel.memory) : nil
                let bottom = bottomHighRes == nil ? kernel.gpu.framebuffer(.bottom, memory: kernel.memory) : nil
                lock.lock()
                latest = Snapshot(top: top, bottom: bottom, topHighRes: topHighRes, bottomHighRes: bottomHighRes, frames: frame, speed: clock.speed, stop: result == .budgetReached ? nil : result)
                lock.unlock()
                if result != .budgetReached { FileHandle.standardError.write("3duos stop: \(result)\nstubbed: \(kernel.stubbedCalls.suffix(12).joined(separator: "\n"))\n".data(using: .utf8)!); return }
            }
        }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
