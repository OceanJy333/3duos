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
        var gameFrames = 0       // new top-screen images; their rate is the game's own frame rate (30 or 60)
        var speed = 1.0          // emulated seconds per wall second; 1 means real time, capped there
        var stop: KernelStop?
    }

    private let kernel: Kernel
    private let queue = DispatchQueue(label: "3duos.core", qos: .userInitiated)
    private let lock = NSCondition()
    private var latest = Snapshot()
    private var cancelled = false
    private var suspended = false

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

    func releaseInput() {
        buttons = 0
        hid?.releaseInput()
    }

    func setSuspended(_ suspended: Bool) {
        lock.lock()
        if self.suspended && !suspended { kernel.setClock() }   // the core thread is parked until this lock is released
        self.suspended = suspended
        NSLog("3duos core: %@ at frame %d", suspended ? "pause" : "resume", latest.frames)
        lock.broadcast()
        lock.unlock()
    }

    // Before start(): the internal resolution as a multiple of the LCD. PICA_SCALE in the environment wins.
    func setInternalScale(_ scale: Int) {
        guard ProcessInfo.processInfo.environment["PICA_SCALE"] == nil else { return }
        kernel.gpu.renderer(memory: kernel.memory).internalScale = scale
    }

    // Before start(): replacement textures from Documents/textures/<program ID>/ (Citra/Azahar layout). TDS_TEXDUMP=1 also
    // writes every texture the game uses to Documents/dump/textures/<program ID>/, named for making a pack.
    func setTexturePack(programID: UInt64) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], id = String(format: "%016llX", programID)
        let dump = ProcessInfo.processInfo.environment["TDS_TEXDUMP"] == "1" ? documents.appendingPathComponent("dump/textures/\(id)") : nil
        let pack = PICATexturePack(directory: documents.appendingPathComponent("textures/\(id)"), dumpDirectory: dump)
        kernel.gpu.renderer(memory: kernel.memory).texturePack = pack.isEmpty ? nil : pack
    }

    // Before start(): sharper magnified textures. TDS_TEXFILTER=0 in the environment turns it off for comparisons.
    func setTextureFiltering(_ on: Bool) {
        kernel.gpu.renderer(memory: kernel.memory).filtersTextures = on && ProcessInfo.processInfo.environment["TDS_TEXFILTER"] != "0"
    }

    // Before start(): temporal MetalFX needs jitter, exact motion and the reactive mask from the renderer.
    func setMetalFXInputs(_ on: Bool) { kernel.gpu.renderer(memory: kernel.memory).emitsMotionInputs = on }

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return latest }

    private static let ticksPerSecond = 268_111_856.0

    // Device log every 5 s: share of the core thread spent sleeping (headroom) and blocked on GX work, GPU time of the
    // emulated GPU's command buffers, the longest gap between two new top images, and stale images held back.
    private var perf = (start: 0.0, slept: 0.0, worstGap: 0.0, lastImage: 0.0, stale: 0, gx: UInt64(0), gpu: UInt64(0))
    private func report(_ now: Double) {
        guard now - perf.start >= 5 else { return }
        let elapsed = now - perf.start, gx = kernel.gpu.gxWaitNanoseconds
        let gpu = kernel.gpu.renderer(memory: kernel.memory).metal?.statistics.snapshot.nanoseconds ?? 0
        if perf.start > 0 {
            NSLog("3duos perf: sleep %.0f%% · gx wait %.0f%% · GPU %.0f ms/s · worst frame gap %.0f ms · stale %d", perf.slept / elapsed * 100,
                  Double(gx - perf.gx) / 1e7 / elapsed, Double(gpu - perf.gpu) / 1e6 / elapsed, perf.worstGap * 1000, perf.stale)
            if let events = kernel.gpu.renderer(memory: kernel.memory).metal?.statistics.takeEvents(), !events.isEmpty {
                NSLog("3duos passes/s: %@", events.sorted { $0.key < $1.key }.map { "\($0.key) \(Int(Double($0.value) / elapsed))" }.joined(separator: " · "))
            }
        }
        perf = (now, 0, 0, perf.lastImage, 0, gx, gpu)
    }

    // Sleeps when the core runs ahead of the 3DS clock, so the host idles instead of spinning at full speed; falls
    // back to measuring when it is slower than real time. Returns the speed over the last second.
    private func pace(_ clock: inout (wall: UInt64, ticks: UInt64, speed: Double)) {
        let now = DispatchTime.now().uptimeNanoseconds
        let emulated = Double(kernel.ticks - clock.ticks) / Self.ticksPerSecond, elapsed = Double(now - clock.wall) / 1e9
        if emulated > elapsed + 0.002 { Thread.sleep(forTimeInterval: emulated - elapsed); perf.slept += emulated - elapsed }
        if elapsed >= 1 {
            clock.speed = min(1, emulated / elapsed)
            report(Double(now) / 1e9)
            clock.wall = now; clock.ticks = kernel.ticks
        }
    }

    func start() {
        queue.async { [self] in
            var publishedFrame = -1, gameFrames = 0
            // TDS_INPUT="start@1800,a@2600,stickright@3000,stickcenter@3010": scripted input by frame counter, for checks.
            let sticks: [String: (x: Float, y: Float)] = ["stickright": (1, 0), "stickleft": (-1, 0), "stickup": (0, 1), "stickdown": (0, -1), "stickcenter": (0, 0)]
            let names = Dictionary(uniqueKeysWithValues: Self.bits.keys.map { ("\($0)", $0) })
            var script = (ProcessInfo.processInfo.environment["TDS_INPUT"] ?? "").split(separator: ",").compactMap { step -> (String, Int)? in
                let parts = step.split(separator: "@")
                return parts.count == 2 ? Int(parts[1]).map { (String(parts[0]), $0) } : nil
            }
            var clock = (wall: DispatchTime.now().uptimeNanoseconds, ticks: kernel.ticks, speed: 1.0)
            while true {
                lock.lock()
                if suspended {
                    while suspended && !cancelled { lock.wait() }
                    // Closed-lid time is not emulated time; resume without running a catch-up burst.
                    clock = (wall: DispatchTime.now().uptimeNanoseconds, ticks: kernel.ticks, speed: 1.0)
                }
                let done = cancelled
                lock.unlock()
                if done { return }
                let result = kernel.run(instructionBudget: 50_000)
                pace(&clock)
                let frame = kernel.gpu.frameCount
                // The displayed buffer's GPU image completes asynchronously: right after a swap it can still hold the image of
                // two frames ago. Never step back; publish as soon as a newer image completes instead of waiting for a vblank.
                var topHighRes = kernel.gpu.highResFrame(.top)
                if let image = topHighRes, let shown = latest.topHighRes, image.sequence < shown.sequence {
                    if frame != publishedFrame { perf.stale += 1 }
                    topHighRes = shown
                }
                guard frame != publishedFrame || result != .budgetReached || topHighRes?.sequence != latest.topHighRes?.sequence else { continue }
                publishedFrame = frame
                while let step = script.first, frame >= step.1 {
                    if let id = names[step.0] { button(id, pressed: true); button(id, pressed: false) } else if let position = sticks[step.0] { stick(position) }
                    script.removeFirst()
                }
                // GPU-rendered screens are shown at the internal resolution; only the others are read back at 400x240.
                let bottomHighRes = kernel.gpu.highResFrame(.bottom)
                if topHighRes == nil || bottomHighRes == nil { kernel.gpu.waitForIdle() }
                let top = topHighRes == nil ? kernel.gpu.framebuffer(.top, memory: kernel.memory) : nil
                let bottom = bottomHighRes == nil ? kernel.gpu.framebuffer(.bottom, memory: kernel.memory) : nil
                if topHighRes == nil || topHighRes?.sequence != latest.topHighRes?.sequence {
                    gameFrames += 1
                    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                    perf.worstGap = max(perf.worstGap, now - perf.lastImage); perf.lastImage = now
                }
                lock.lock()
                latest = Snapshot(top: top, bottom: bottom, topHighRes: topHighRes, bottomHighRes: bottomHighRes, frames: frame, gameFrames: gameFrames,
                                  speed: clock.speed, stop: result == .budgetReached ? nil : result)
                lock.unlock()
                if result != .budgetReached { FileHandle.standardError.write("3duos stop: \(result)\nstubbed: \(kernel.stubbedCalls.suffix(12).joined(separator: "\n"))\n".data(using: .utf8)!); return }
            }
        }
    }

    func cancel() { lock.lock(); cancelled = true; lock.broadcast(); lock.unlock() }
}
