// input: hid:USER commands and the host's button, circle-pad and touch state.
// output: the HID shared-memory page (pad, touch and enabled sensor rings updated once per frame), five input events, and sensor replies.
// pos: HLE of the input service; the host sets `input` and the next frame's ring-buffer entry carries it.
import Foundation

struct HIDInput {
    var buttons: UInt32 = 0            // bit 0 A, 1 B, 2 Select, 3 Start, 4-7 D-pad R/L/U/D, 8 R, 9 L, 10 X, 11 Y
    var circle: (x: Int16, y: Int16) = (0, 0)
    var touch: (x: UInt16, y: UInt16)?  // bottom-screen pixel, nil when not touching
}

final class HIDService: HLEService {
    private let inputLock = NSLock()
    private var pending = HIDInput()
    var input: HIDInput {
        get { inputLock.lock(); defer { inputLock.unlock() }; return pending }
        set {
            inputLock.lock()
            let pressed = newValue.buttons & ~pending.buttons
            if pressed != 0 { latched |= pressed; latchedFrames = Self.minimumHoldFrames }
            if let touch = newValue.touch, pending.touch == nil { latchedTouch = touch; touchFrames = Self.minimumHoldFrames }
            pending = newValue
            inputLock.unlock()
        }
    }
    // Games poll at 30 Hz or slower; a press or tap shorter than a few frames (a mouse click) must still be seen.
    private static let minimumHoldFrames = 4
    private var latched: UInt32 = 0, latchedFrames = 0
    private var latchedTouch: (x: UInt16, y: UInt16)?, touchFrames = 0
    private var padIndex: UInt32 = 0, touchIndex: UInt32 = 0, previousButtons: UInt32 = 0
    private var sensorsOn = [false, false], sensorIndex: [UInt32] = [0, 0]   // accelerometer, gyroscope

    static let updateTicks: UInt64 = 4_468_531   // pads update once per frame

    let name = "hid:USER"
    private var shared: KSharedMemory?
    private var events: [KEvent] = []
    private var handles: [UInt32] = []

    private func put32(_ page: [MemoryPage], _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { page[offset >> 12].bytes[(offset & 0xFFF) + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    // Pad ring (3DS layout): reset ticks at 0x0/0x8, latest index at 0x10, current state at 0x1C, 8 entries of 16 bytes
    // from 0x28. Touch ring: reset ticks at 0xA8/0xB0, latest index at 0xB8, raw entry at 0xC0, 8 entries of 8 bytes from 0xC8.
    // Reset ticks change only when an index wraps to 0, as on hardware.
    private func publish(_ kernel: Kernel) {
        guard let pages = shared?.pages else { return }
        var input = self.input
        inputLock.lock()
        input.buttons |= latched
        // The circle pad also reports a direction (bits 28-31: right, left, up, down) past radius 40, split at 30/60 degrees.
        let x = Int(input.circle.x), y = Int(input.circle.y), slope = abs(Double(y) / Double(x))
        if x * x + y * y > 1600 {
            if x != 0, slope < 3.0.squareRoot() { input.buttons |= x > 0 ? 1 << 28 : 1 << 29 }
            if x == 0 || slope > 1 / 3.0.squareRoot() { input.buttons |= y > 0 ? 1 << 30 : 1 << 31 }
        }
        if input.touch == nil, touchFrames > 0 { input.touch = latchedTouch }
        if latchedFrames > 0 { latchedFrames -= 1 }
        if latchedFrames == 0 { latched = 0 }
        if touchFrames > 0 { touchFrames -= 1 }
        inputLock.unlock()
        func resetTicks(_ base: Int) {
            let tick = kernel.ticks
            for i in 0..<8 { pages[0].bytes[base + 8 + i] = pages[0].bytes[base + i] }
            put32(pages, base, UInt32(truncatingIfNeeded: tick)); put32(pages, base + 4, UInt32(truncatingIfNeeded: tick >> 32))
        }
        padIndex = (padIndex + 1) % 8
        if padIndex == 0 { resetTicks(0x0) }
        put32(pages, 0x10, padIndex)
        put32(pages, 0x1C, input.buttons)
        let entry = 0x28 + Int(padIndex) * 0x10
        put32(pages, entry, input.buttons)
        put32(pages, entry + 4, input.buttons & ~previousButtons)
        put32(pages, entry + 8, previousButtons & ~input.buttons)
        put32(pages, entry + 12, UInt32(UInt16(bitPattern: input.circle.x)) | UInt32(UInt16(bitPattern: input.circle.y)) << 16)
        previousButtons = input.buttons
        touchIndex = (touchIndex + 1) % 8
        if touchIndex == 0 { resetTicks(0xA8) }
        put32(pages, 0xB8, touchIndex)
        let point = input.touch.map { UInt32($0.x) | UInt32($0.y) << 16 } ?? 0, valid: UInt32 = input.touch == nil ? 0 : 1
        for base in [0xC0, 0xC8 + Int(touchIndex) * 8] { put32(pages, base, point); put32(pages, base + 4, valid) }
        // Sensor rings: accelerometer at 0x108 (8 entries from 0x128), gyroscope at 0x158 (32 entries from 0x178), 6 bytes
        // per x/y/z entry. The console lies still: gravity on the accelerometer (512 per g), no rotation.
        for (sensor, base, count, sample) in [(0, 0x108, 8, (0, -512, 0)), (1, 0x158, 32, (0, 0, 0))] where sensorsOn[sensor] {
            sensorIndex[sensor] = (sensorIndex[sensor] + 1) % UInt32(count)
            if sensorIndex[sensor] == 0 { resetTicks(base) }
            put32(pages, base + 0x10, sensorIndex[sensor])
            let entry = base + 0x20 + Int(sensorIndex[sensor]) * 6
            put32(pages, entry, UInt32(UInt16(bitPattern: Int16(sample.0))) | UInt32(UInt16(bitPattern: Int16(sample.1))) << 16)
            for i in 0..<2 { pages[0].bytes[entry + 4 + i] = UInt8(truncatingIfNeeded: sample.2 >> (8 * i)) }
            events[2 + sensor].signaled = true; kernel.signalChanged(events[2 + sensor])
        }
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        let command = request.command
        switch command {
        case 0x0A: // GetIPCHandles: shared memory, then pad0, pad1, accelerometer, gyroscope, debug pad events
            if shared == nil {
                let memory = KSharedMemory(pages: (0..<2).map { _ in MemoryPage() })
                memory.label = "HID shared memory"
                shared = memory
                events = (0..<5).map { index in
                    let event = KEvent(reset: .oneShot)
                    event.label = "HID event \(index)"
                    return event
                }
                handles = [kernel.create(memory)!] + events.map { kernel.create($0)! }
                kernel.hostEvents.append(HostEvent(fireAt: kernel.ticks + Self.updateTicks, interval: Self.updateTicks) { [weak self, weak kernel] in
                    guard let self, let kernel else { return }
                    self.publish(kernel)
                    for event in self.events.prefix(2) { event.signaled = true; kernel.signalChanged(event) }
                })
            }
            return IPCReply(command: command, [0], translate: [0x1400_0000] + handles)
        case 0x11, 0x12, 0x13, 0x14: // EnableAccelerometer, DisableAccelerometer, EnableGyroscope, DisableGyroscope
            sensorsOn[Int(command - 0x11) / 2] = command & 1 == 1
            return IPCReply(command: command, [0])
        case 0x15: // GetGyroscopeRawToDpsCoefficient
            return IPCReply(command: command, [0, Float(14.375).bitPattern])
        case 0x16: // GetGyroscopeCalibrateParam
            // Three axes of (zero, plus, minus) as s16, the approximate hardware values.
            let axis: [UInt16] = [0, 6700, UInt16(bitPattern: -6700)]
            let halves = axis + axis + axis + [0]
            return IPCReply(command: command, [0] + (0..<5).map { UInt32(halves[$0 * 2]) | UInt32(halves[$0 * 2 + 1]) << 16 })
        case 0x17: // GetSoundVolume
            return IPCReply(command: command, [0, 0x3F])
        default:
            return nil
        }
    }
}
