// input: an optional local decrypted CXI path, an instruction budget, and flags (--trace).
// output: the first point where the emulated kernel cannot continue, with the guest's SVC and service log.
// pos: standalone boot check; synthetic checks run first, then the supplied game.
import Foundation
import Metal

func segment(_ address: UInt32, _ words: [UInt32]) -> CartridgeMappedSegment {
    var bytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
    bytes += [UInt8](repeating: 0, count: (4096 - bytes.count % 4096) % 4096 + (bytes.isEmpty ? 4096 : 0))
    return CartridgeMappedSegment(address: address, bytes: Data(bytes), usedSize: UInt32(words.count * 4))
}
func program(_ words: [UInt32]) -> CartridgeProgram {
    CartridgeProgram(text: segment(0x0010_0000, words), ro: segment(0x0020_0000, [0x12345678]),
                     data: segment(0x0030_0000, [0x87654321]), bssSize: 0x1000, stackSize: 0x1000)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func run(_ words: [UInt32], budget: UInt64 = 1000) throws -> (KernelStop, Kernel) {
    let kernel = try ProcessLoader.boot(program(words))
    return (kernel.run(instructionBudget: budget), kernel)
}

// Segments, BSS, TLS and the configuration page are mapped; a thread can read them.
let (mapped, mappedKernel) = try run([0xE59F000C, 0xE5901040, 0xE3510301, 0x1F000043, 0xEF000003, 0x1FF80000])
check(mapped == .exited && mappedKernel.memory.isMapped(0x0030_1000, size: 0x1000), "mapping and APPMEMALLOC read")
// ControlMemory COMMIT of heap memory, then a store to it.
let (heap, heapKernel) = try run([0xE3A00003, 0xE3A01302, 0xE3A02000, 0xE3A03A01, 0xE3A04003, 0xEF000001,
                                  0xE3A02007, 0xE5812000, 0xEF000003])
check(heap == .exited && heapKernel.committedBytes > 0x1000, "heap commit")
let heapValue = try heapKernel.memory.peek32(0x0800_0000)
check(heapValue == 7, "heap store")
// A created thread runs, signals an event, and the main thread waits on it.
let (events, _) = try run([0xE3A00000, 0xE3A01000, 0xEF000017, 0xE1A04001, 0xEF000003], budget: 100)
check(events == .exited, "event creation")
// Unknown SVC stops with its number.
let (unknown, _) = try run([0xEF0000F0])
check(unknown == .unsupportedSVC(0xF0, pc: 0x0010_0000), "unsupported SVC")
// Unknown instruction stops with the thread.
let (undefined, _) = try run([0xE7F000F0])
check(undefined == .cpu(.undefined(0x0010_0000, 0xE7F000F0), thread: 1), "undefined instruction")
print("Boot synthetic checks passed")

if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let cartridge = try CartridgeReader.read(url: url)
    let decoded = try CartridgeProgramLoader.load(cartridge, from: url)
    let options = Array(CommandLine.arguments.dropFirst(2))
    if let dump = options.first(where: { $0.hasPrefix("--dump-text=") }) {
        try decoded.text.bytes.write(to: URL(fileURLWithPath: String(dump.dropFirst(12))))
    }
    let budget = options.first(where: { !$0.hasPrefix("--") }).flatMap { UInt64($0) } ?? 10_000_000
    let kernel = try ProcessLoader.boot(decoded, source: CartridgeSource(url: url, cartridge: cartridge), traceSVC: options.contains("--trace"))
    if let watch = options.first(where: { $0.hasPrefix("--watch=") }).flatMap({ UInt32(String($0.dropFirst(8)), radix: 16) }) {
        kernel.memory.watchAddress = watch
        kernel.memory.onWatch = { value in
            let thread = kernel.current!
            print(String(format: "watch %08X <- %08X by t%d pc=%08X lr=%08X ticks=%llu", watch, value, thread.id, thread.cpu.pc, thread.cpu.registers[14], kernel.ticks)); if options.contains("--stopon=\(String(value, radix: 16).uppercased())") { print("history@watch: " + kernel.history.map { String(format: "%X", $0 & 0x0FFF_FFFF) }.joined(separator: " ")) }; if options.contains("--regs") { print("  regs " + thread.cpu.registers.prefix(14).map { String(format: "%X", $0) }.joined(separator: " ")) }
            if options.contains("--stack") { print(Thread.callStackSymbols.prefix(8).joined(separator: "\n")) }
        }
    }
    var totalDraws = 0
    var transfers = 0, drawsByTarget: [UInt32: [Int]] = [:]   // draws, triangles, covered, depth-failed, alpha-failed, written
    var litDraws = 0, fogDraws = 0, mismatchedLighting = 0, lastBusy: UInt64 = 0, lastTransfers = 0
    if options.contains("--gpu") {
        DisplayTransfer.onRun = { t, source in
            transfers += 1
            guard transfers % 200 < 4 else { return }
            let nonzero = source.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            let targets = drawsByTarget.map { String(format: "%08X:", $0.key) + $0.value.map(String.init).joined(separator: "/") }.joined(separator: " ")
            print(String(format: "XFER %d in=%08X out=%08X %dx%d -> %dx%d flags=%08X nonzeroIn=%d/%d draws{%@}", transfers, t.input, t.output,
                         t.inputWidth, t.inputHeight, t.outputWidth, t.outputHeight, t.flags, nonzero, source.count, targets))
            let busy = kernel.gpu.renderer(memory: kernel.memory).busyNanoseconds
            print("     lit=\(litDraws) fog=\(fogDraws) lightingRegsDisagree=\(mismatchedLighting) renderMsPerTransfer=\(Double(busy - lastBusy) / 1e6 / Double(transfers - lastTransfers))")
            lastBusy = busy; lastTransfers = transfers
            drawsByTarget.removeAll(); litDraws = 0; fogDraws = 0; mismatchedLighting = 0
        }
    }
    if options.contains("--gpu") {
        let renderer = kernel.gpu.renderer(memory: kernel.memory)
        let dumpRange = options.first(where: { $0.hasPrefix("--dumpdraws=") }).map { $0.dropFirst(12).split(separator: ":").compactMap { Int($0) } }
        renderer.onDraw = { d in
            totalDraws += 1
            let st = ((renderer.backend as? PICARasterizer)?.stats ?? PICARasterStats())
            let add = [1, d.triangleCount, st.covered, st.depthFailed, st.alphaFailed, st.written]
            if d.state.lighting.enabled { litDraws += 1 }
            if d.state.fog.enabled { fogDraws += 1 }
            if (renderer.registers[0x8F] & 1 == 1) != (renderer.registers[0x1C6] & 1 == 0) { mismatchedLighting += 1 }
            drawsByTarget[d.state.target.colorAddress] = zip(drawsByTarget[d.state.target.colorAddress] ?? [0, 0, 0, 0, 0, 0], add).map { $0 + $1 }
            // --dumpdraws=A:B writes the RGBA8 render target after draws A...B to /tmp/draws.
            if let range = dumpRange, range.count == 2, (range[0]...range[1]).contains(totalDraws), let p = d.colorPointer {
                let w = d.targetWidth, h = d.targetHeight
                var ppm = Data("P6 \(w) \(h) 255\n".utf8)
                for row in 0..<h { for x in 0..<w {
                    let o = PICAMath.tiledIndex(x, h - 1 - row, width: w) * 4
                    ppm.append(contentsOf: [p[o + 3], p[o + 2], p[o + 1]])
                } }
                try? ppm.write(to: URL(fileURLWithPath: "/tmp/draws/\(String(format: "%06d", totalDraws)).ppm"))
            }
        }
    }
    kernel.recordHistory = options.contains("--history")
    if options.contains("--motion") { kernel.gpu.renderer(memory: kernel.memory).emitsMotionInputs = true }
    if options.contains("--texfilter") { kernel.gpu.renderer(memory: kernel.memory).filtersTextures = true }
    // --texpack=DIR loads replacement textures, --texdump=DIR writes the game's textures (Citra/Azahar names).
    let packPath = options.first(where: { $0.hasPrefix("--texpack=") }).map { URL(fileURLWithPath: String($0.dropFirst(10))) }
    let dumpPath = options.first(where: { $0.hasPrefix("--texdump=") }).map { URL(fileURLWithPath: String($0.dropFirst(10))) }
    if packPath != nil || dumpPath != nil { kernel.gpu.renderer(memory: kernel.memory).texturePack = PICATexturePack(directory: packPath, dumpDirectory: dumpPath) }
    let shotDirectory = options.first(where: { $0.hasPrefix("--shot=") }).map { String($0.dropFirst(7)) }
    func writeShots(_ suffix: String) throws {
        guard let shotDirectory else { return }
        kernel.gpu.waitForIdle()
        for screen in [ThreeDSScreen.top, .bottom] {
            guard let frame = kernel.gpu.framebuffer(screen, memory: kernel.memory) else { print("\(screen): no framebuffer"); continue }
            var ppm = Data("P6 \(screen.width) 240 255\n".utf8)
            for row in 0..<240 { for x in 0..<screen.width {
                let at = x * 240 * 3 + (239 - row) * 3
                ppm.append(contentsOf: [frame.bytes[at + 2], frame.bytes[at + 1], frame.bytes[at]])
            } }
            try ppm.write(to: URL(fileURLWithPath: "\(shotDirectory)/\(screen)\(suffix).ppm"))
            print("wrote \(screen)\(suffix).ppm frames=\(kernel.gpu.frameCount)")
            // The high-res LCD frame of the Metal backend, read back through a blit.
            if let frame = kernel.gpu.highResFrame(screen), let device = kernel.gpu.renderer(memory: kernel.memory).metalDevice {
                let w = frame.color.width, h = frame.color.height
                func read(_ texture: MTLTexture) -> [UInt8] {
                    let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared)!
                    let queue = device.makeCommandQueue()!, commands = queue.makeCommandBuffer()!, blit = commands.makeBlitCommandEncoder()!
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                              to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
                    blit.endEncoding(); commands.commit(); commands.waitUntilCompleted()
                    return [UInt8](UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: w * h * 4))
                }
                // -hires: the scene with the UI layer composited (rgb = ui.rgb + scene * ui.a); -ui: the UI layer over gray.
                let p = read(frame.color), ui = frame.layer.map(read)
                var hires = Data("P6 \(w) \(h) 255\n".utf8), layer = hires
                for i in 0..<(w * h) { for c in 0..<3 {
                    let t = ui.map { Int($0[i * 4 + 3]) } ?? 255, u = ui.map { Int($0[i * 4 + c]) } ?? 0
                    hires.append(UInt8(min(255, u + Int(p[i * 4 + c]) * t / 255))); layer.append(UInt8(min(255, u + 128 * t / 255)))
                } }
                try hires.write(to: URL(fileURLWithPath: "\(shotDirectory)/\(screen)-hires\(suffix).ppm"))
                if ui != nil { try layer.write(to: URL(fileURLWithPath: "\(shotDirectory)/\(screen)-ui\(suffix).ppm")) }
            }
            // --motion: motion magnitude as gray (8 px = white) and its mean/max, from the renderer's last finished frame.
            let motion = kernel.gpu.renderer(memory: kernel.memory).motion.lcdMotion
            if screen == .top, !motion.isEmpty {
                var map = Data("P5 400 240 255\n".utf8), moving = 0, peak: Float = 0
                for m in motion { let length = (m * m).sum().squareRoot(); peak = max(peak, length); if length > 0.1 { moving += 1 }; map.append(UInt8(min(255, length * 32))) }
                try map.write(to: URL(fileURLWithPath: "\(shotDirectory)/motion\(suffix).pgm"))
                print("motion\(suffix): moving pixels \(moving)/96000, peak \(peak) px, jitter \(kernel.gpu.renderer(memory: kernel.memory).published.shift)")
            }
        }
    }
    // --motioncheck=START: after START instructions, warp each finished top frame's predecessor by the renderer's motion and compare.
    if let start = options.first(where: { $0.hasPrefix("--motioncheck=") }).flatMap({ UInt64($0.dropFirst(14)) }) {
        _ = kernel.run(instructionBudget: start)
        let renderer = kernel.gpu.renderer(memory: kernel.memory)
        renderer.jittersTopScreen = false
        var target: (surface: PICASurface, format: Int)?
        var lastColorAddress: UInt32 = 0
        renderer.onDraw = { draw in
            let t = draw.state.target
            if t.height == 400, t.width == 240 || t.width == 480, let color = draw.color { target = (color, t.colorFormat); lastColorAddress = t.colorAddress }
        }
        var captured: [Float]?
        renderer.onFinishFrame = {
            guard let (surface, format) = target else { return }
            let scaleX = max(1, surface.width / 240)
            captured = (0..<240 * 400).map { i in
                let (row, column) = (i / 400, i % 400)
                let p = PICAColorFormat.read(surface.bytes + surface.offset((239 - row) * scaleX, column), format)
                let (r, g, b) = (p & 255, p >> 8 & 255, p >> 16 & 255)
                return 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
            }
        }
        func luma() -> [Float]? { captured }
        var previous: [Float]?, seen = renderer.motion.finishedFrames, reported = 0
        while reported < 4 {
            _ = kernel.run(instructionBudget: 150_000)
            guard renderer.motion.finishedFrames != seen else { continue }
            seen = renderer.motion.finishedFrames
            guard let now = luma() else { continue }
            if let before = previous {
                let m = renderer.motion.lcdMotion
                var plain: Float = 0, warped: Float = 0, flipped: Float = 0, flipX: Float = 0, flipY: Float = 0, swapped: Float = 0, count = 0
                func sample(_ f: [Float], _ x: Float, _ y: Float) -> Float {
                    let fx = min(398.999, max(0, x - 0.5)), fy = min(238.999, max(0, y - 0.5)), ix = Int(fx), iy = Int(fy), tx = fx - Float(ix), ty = fy - Float(iy)
                    let top = f[iy * 400 + ix] * (1 - tx) + f[iy * 400 + ix + 1] * tx, bottom = f[(iy + 1) * 400 + ix] * (1 - tx) + f[(iy + 1) * 400 + ix + 1] * tx
                    return top * (1 - ty) + bottom * ty
                }
                for y in 0..<240 { for x in 0..<400 {
                    let v = m[y * 400 + x]
                    guard v.x * v.x + v.y * v.y > 4, v.x * v.x + v.y * v.y < 400 else { continue }
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    plain += abs(now[y * 400 + x] - before[y * 400 + x]); warped += abs(now[y * 400 + x] - sample(before, px + v.x, py + v.y))
                    flipped += abs(now[y * 400 + x] - sample(before, px - v.x, py - v.y)); count += 1
                    flipX += abs(now[y * 400 + x] - sample(before, px - v.x, py + v.y)); flipY += abs(now[y * 400 + x] - sample(before, px + v.x, py - v.y)); swapped += abs(now[y * 400 + x] - sample(before, px + v.y, py + v.x))
                } }
                print("frame \(seen): moving \(count) px, identity error \(plain / Float(max(count, 1))), warped error \(warped / Float(max(count, 1))), flipped \(flipped / Float(max(count, 1))) flipX \(flipX / Float(max(count, 1))) flipY \(flipY / Float(max(count, 1))) swapped \(swapped / Float(max(count, 1)))")
                reported += 1
                var mean = SIMD2<Float>.zero, n = 0
                for v in m where v.x * v.x + v.y * v.y > 1 { mean += v; n += 1 }
                mean *= Float(96000) / Float(max(1, n))
                var best = (Float.infinity, 0, 0)
                for dy in -8...8 { for dx in -8...8 {
                    var e: Float = 0
                    for y in 20..<220 { for x in 20..<380 { e += abs(now[y * 400 + x] - before[(y + dy) * 400 + x + dx]) } }
                    if e < best.0 { best = (e, dx, dy) }
                } }
                print("  mean motion \(mean / 96000) | best global shift: now(p) ~ before(p + (\(best.1), \(best.2)))")
                if reported == 3 {
                    var flow = Data("P6 400 240 255\n".utf8)
                    for v in m { flow.append(contentsOf: [UInt8(max(0, min(255, 128 + v.x * 16))), UInt8(max(0, min(255, 128 + v.y * 16))), 128]) }
                    try? flow.write(to: URL(fileURLWithPath: "/tmp/lead-motion/flow.ppm"))
                    var cur = Data("P6 400 240 255\n".utf8)
                    for l in now { cur.append(contentsOf: [UInt8(l), UInt8(l), UInt8(l)]) }
                    try? cur.write(to: URL(fileURLWithPath: "/tmp/lead-motion/cur.ppm"))
                    var prev = Data("P6 400 240 255\n".utf8)
                    for l in before { prev.append(contentsOf: [UInt8(l), UInt8(l), UInt8(l)]) }
                    try? prev.write(to: URL(fileURLWithPath: "/tmp/lead-motion/prev.ppm"))
                }
            }
            previous = now
        }
        exit(0)
    }
    // --press=BIT,AT,HOLD: hold HID button BIT (3 = Start) for HOLD instructions after AT instructions, then continue.
    var budgetLeft = budget
    if let press = options.first(where: { $0.hasPrefix("--press=") }).map({ $0.dropFirst(8).split(separator: ",").compactMap { UInt64($0) } }), press.count == 3,
       let hid = kernel.serviceDirectory["hid:USER"] as? HIDService {
        _ = kernel.run(instructionBudget: press[1])
        hid.input.buttons = 1 << UInt32(press[0])
        _ = kernel.run(instructionBudget: press[2])
        hid.input.buttons = 0
        budgetLeft = budget - min(budget, press[1] + press[2])
    }
    // --drawlog=FRAME prints every draw of the first GPU frame from FRAME on: depth test/write, blend factors, triangles.
    if let at = options.first(where: { $0.hasPrefix("--drawlog=") }).flatMap({ Int($0.dropFirst(10)) }) {
        var logged: Int?
        kernel.gpu.renderer(memory: kernel.memory).onDraw = { d in
            if logged == nil, kernel.gpu.frameCount >= at { logged = kernel.gpu.frameCount }
            guard kernel.gpu.frameCount == logged else { return }
            let m = d.state.merger
            print("draw \(d.targetWidth)x\(d.targetHeight) depth=\(m.depthTestEnabled)/\(m.depthWrite) blend=\(m.blendEnabled) src=\(m.sourceRGB) dst=\(m.destRGB) tris=\(d.triangleCount) ui=\(d.state.overlay) tex=" + d.state.textures.filter(\.enabled).map { String(format: "%08X:%dx%d/f%d", $0.address, $0.width, $0.height, $0.format) }.joined(separator: ","))
        }
    }
    // --keys=start@1900,a@2600,touch160:120@2700,shot@2800: at a GPU frame count, tap a button or the touch screen (HID holds
    // either for a few frames) or write shots suffixed with the frame. Runs before the main budget.
    if let keys = options.first(where: { $0.hasPrefix("--keys=") }), let hid = kernel.serviceDirectory["hid:USER"] as? HIDService {
        let bits = ["a": 0, "b": 1, "select": 2, "start": 3, "right": 4, "left": 5, "up": 6, "down": 7, "r": 8, "l": 9, "x": 10, "y": 11]
        var steps = keys.dropFirst(7).split(separator: ",").compactMap { step -> (String, Int)? in
            let parts = step.split(separator: "@"); return parts.count == 2 ? Int(parts[1]).map { (String(parts[0]), $0) } : nil }
        while !steps.isEmpty, kernel.run(instructionBudget: 50_000) == .budgetReached {
            while let (name, frame) = steps.first, kernel.gpu.frameCount >= frame {
                steps.removeFirst()
                if name == "shot" { try writeShots("-\(frame)") }
                else if name.hasPrefix("touch") {
                    let xy = name.dropFirst(5).split(separator: ":").compactMap { UInt16($0) }
                    hid.input.touch = (xy[0], xy[1]); hid.input.touch = nil
                } else if let bit = bits[name] { hid.input.buttons = 1 << UInt32(bit); hid.input.buttons = 0 }
            }
        }
    }
    // --film=N writes N numbered snapshots over the run, otherwise one at the end.
    let film = options.first(where: { $0.hasPrefix("--film=") }).flatMap { Int($0.dropFirst(7)) } ?? 1
    var stop = KernelStop.budgetReached
    for part in 0..<film {
        stop = kernel.run(instructionBudget: budgetLeft / UInt64(film))
        try writeShots(film > 1 ? "-\(part)" : "")
        if stop != .budgetReached { break }
    }
    for target in options.filter({ $0.hasPrefix("--callers=") }).compactMap({ UInt32($0.dropFirst(10), radix: 16) }) {
        if let code = try? kernel.memory.readBytes(0x100000, count: 0x500000) {
            for i in stride(from: 0, to: code.count - 3, by: 4) {
                let w = (0..<4).reduce(UInt32(0)) { $0 | UInt32(code[i + $1]) << ($1 * 8) }
                let site = UInt32(0x100000 + i)
                if w >> 24 == 0xEB || w >> 24 == 0xEA, UInt32(truncatingIfNeeded: Int64(site) + 8 + Int64(Int32(bitPattern: w << 8) >> 6)) == target { print(String(format: "caller %08X (%08X)", site, w)) }
            }
        }
    }
    for dump in options.filter({ $0.hasPrefix("--dump=") }) {
        let parts = dump.dropFirst(7).split(separator: ":")
        if let address = UInt32(parts[0], radix: 16), let count = parts.count > 1 ? Int(parts[1]) : 16,
           let bytes = try? kernel.memory.readBytes(address, count: count * 4) {
            print(String(format: "dump %08X:", address) + (0..<count).map { i in String(format: " %08X", (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i * 4 + $1]) << ($1 * 8) }) }.joined())
        }
    }
    let tail = options.contains("--trace") ? 100000 : 30
    // --grep=TEXT prints every kept log line containing TEXT instead of the tail.
    if let text = options.first(where: { $0.hasPrefix("--grep=") }).map({ String($0.dropFirst(7)) }) {
        for line in kernel.log where line.contains(text) { print(line) }
    } else { for line in kernel.log.suffix(tail) { print(line) } }
    let threads = kernel.threads.map { String(format: "t%d prio=%d %@ pc=%08X waits=[%@]", $0.id, $0.priority, String(describing: $0.state), $0.cpu.pc, $0.waitObjects.map { $0.name }.joined(separator: ",")) }
    if case .cpu(_, let id) = stop, let thread = kernel.threads.first(where: { $0.id == id }) {
        print("regs: " + thread.cpu.registers.enumerated().map { String(format: "r%d=%08X", $0.offset, $0.element) }.joined(separator: " "))
    }
    if options.contains("--history") { print("history: " + kernel.history.map { String(format: "%X", $0 & 0x0FFF_FFFF) }.joined(separator: " ")) }
    if options.contains("--threads") {
        for thread in kernel.threads { print(String(format: "t%d arb=%@ wakeAt=%@ pc=%08X lr=%08X sp=%08X r0-r5=%@", thread.id, thread.arbitrationAddress.map { String(format: "%08X", $0) } ?? "-", thread.wakeAt.map { String($0) } ?? "-", thread.cpu.pc, thread.cpu.registers[14], thread.cpu.registers[13], thread.cpu.registers[0...5].map { String(format: "%X", $0) }.joined(separator: " "))) }
    }
    if options.contains("--gpu") { let r = kernel.gpu.renderer(memory: kernel.memory); print("renderer draws=\(r.drawCount) gsSkipped=\(r.skippedGeometryShaderDraws) lists=\(r.listCount) target=\(r.lastDraw.map { "\($0.targetWidth)x\($0.targetHeight)" } ?? "none") top=\(kernel.gpu.top) bottom=\(kernel.gpu.bottom)") }
    if options.contains("--gpu"), let d = kernel.gpu.renderer(memory: kernel.memory).lastDraw, let p = d.colorPointer {
        var nonzero = 0
        for i in 0..<(d.targetWidth * d.targetHeight * 4) where p[i] != 0 { nonzero += 1 }
        print("last render target nonzero bytes: \(nonzero) of \(d.targetWidth * d.targetHeight * 4)")
    }
    if options.contains("--gpu") { print("draws: \(totalDraws) transfers: \(transfers)") }
    print("stubbed: " + Array(Set(kernel.stubbedCalls)).sorted().joined(separator: ", "))
    print("stop=\(stop) ticks=\(kernel.ticks) committed=\(kernel.committedBytes)\nthreads: \(threads.joined(separator: "; "))")
}
