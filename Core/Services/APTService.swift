// input: APT:U/A/S applet-manager commands from the application.
// output: lock, notification and parameter replies that let an application start as the foreground applet, and
//         library applets (the software keyboard) that answer at once.
// pos: HLE of the 3DS applet manager with HOME Menu replaced by a fixed start-up parameter.
import Foundation

final class APTService: HLEService {
    let name = "APT:U"
    private var lock: UInt32?
    private var notification: UInt32?
    private var parameterHandle: UInt32?
    private var parameterEvent: KEvent?
    // The one parameter waiting for the application: HOME Menu's Wakeup at start, later replies from library applets.
    private struct Parameter { var sender: UInt32, signal: UInt32, buffer: [UInt8] = [], handle: UInt32 = 0 }
    private var parameter: Parameter? = Parameter(sender: 0x101, signal: 1)
    private static let keyboard: UInt32 = 0x401, application: UInt32 = 0x300
    var keyboardText = "Link"

    private func send(_ next: Parameter, _ kernel: Kernel) {
        parameter = next
        if let event = parameterEvent { event.signaled = true; kernel.signalChanged(event) }
    }

    private func lockHandle(_ kernel: Kernel) -> UInt32 {
        if lock == nil { let mutex = KMutex(); mutex.label = "APT lock"; lock = kernel.create(mutex) }
        return lock!
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        let command = request.command
        switch command {
        case 0x01: // GetLockHandle: attributes, APT state, lock handle
            return IPCReply(command: command, [0, 0, 0], translate: [0, lockHandle(kernel)])
        case 0x02: // Initialize(appId, attributes): notification and resume events
            if notification == nil {
                let notificationEvent = KEvent(reset: .oneShot), parameter = KEvent(reset: .oneShot)
                notificationEvent.label = "APT notification"
                parameter.label = "APT parameter"
                parameterEvent = parameter
                notification = kernel.create(notificationEvent)
                parameterHandle = kernel.create(parameter)
            }
            return IPCReply(command: command, [0], translate: [0x0400_0000, notification!, parameterHandle!])
        case 0x03: // Enable: HOME Menu answers with the Wakeup parameter
            if let parameter { send(parameter, kernel) }
            return IPCReply(command: command, [0])
        case 0x09: // IsRegistered(appId): only the application itself; library applets finish before control returns
            return IPCReply(command: command, [0, request.param(0) == Self.application ? 1 : 0])
        case 0x0C: // SendParameter(source, destination, signal, size, handle, buffer)
            // The keyboard's Request carries the capture-buffer size; it answers with that much shared memory.
            if request.param(1) == Self.keyboard, request.param(2) == 2,
               let size = try? kernel.memory.peek32(request.words[8]),
               let handle = kernel.create(KSharedMemory(pages: (0..<Int((size + 0xFFF) >> 12)).map { _ in MemoryPage() })) {
                send(Parameter(sender: Self.keyboard, signal: 3, handle: handle), kernel)
            }
            return IPCReply(command: command, [0])
        case 0x1E: // StartLibraryApplet(appId, size, handle, buffer)
            guard request.param(0) == Self.keyboard, let text = kernel.object(request.words[4], as: KSharedMemory.self),
                  let data = try? kernel.memory.readBytes(request.words[6], count: Int(request.param(1))), data.count == 0x400
            else { return nil }
            var config = [UInt8](data)
            finishKeyboard(&config, text: text)
            send(Parameter(sender: Self.keyboard, signal: 0xA, buffer: config), kernel)   // WakeupByExit
            return IPCReply(command: command, [0])
        // Finalize, CancelParameter, Preload/FinishPreloading/PrepareToStart LibraryApplet, StartSystemApplet,
        // PrepareToClose/CloseApplication, PrepareToJump/JumpToHomeMenu, CancelLibraryApplet, SendDspSleep/WakeUp,
        // ReplySleepQuery, ReplySleepNotificationComplete, SendCaptureBufferInfo, NotifyToWait, SetAppCpuTimeLimit
        case 0x04, 0x0F, 0x16, 0x17, 0x18, 0x19, 0x1F, 0x22, 0x27, 0x2B, 0x2C, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x43, 0x4F:
            return IPCReply(command: command, [0])
        case 0x05: // GetAppletManInfo(pos): active position, requested applet, HOME Menu, active applet
            return IPCReply(command: command, [0, 0, Self.application, 0x101, Self.application])
        case 0x06: // GetAppletInfo(appId): title id, media type, registered, loaded, attributes
            let registered: UInt32 = request.param(0) == Self.application ? 1 : 0
            return IPCReply(command: command, [0, 0, 0, 0, registered, registered, 0])
        case 0x4B, 0x51: // AppletUtility(command, input size, output size), GetStartupArgument(size, type): static-buffer output
            let size = Int(command == 0x4B ? request.param(2) : min(request.param(0), 0x1000))
            var out = [UInt8](repeating: 0, count: size)
            if command == 0x4B, request.param(0) == 6, size > 0 { out[0] = 1 }   // TryLockTransition succeeds
            let pointer = (try? kernel.memory.peek32(kernel.current.cpu.threadLocalStorageAddress + 0x184)) ?? 0
            try? kernel.memory.writeBytes(pointer, out)
            return IPCReply(command: command, [0, 0], translate: [UInt32(size) << 14 | 2, pointer])
        case 0x0B: // InquireNotification
            return IPCReply(command: command, [0, 0])
        case 0x0D, 0x0E: // ReceiveParameter, GlanceParameter(appId, size): the buffer goes to the static buffer at TLS + 0x180
            guard let parameter else { return IPCReply(command: command, [0, 0, 0, 0], translate: [0, 0, 2, 0]) }
            if command == 0x0D { self.parameter = nil }
            let pointer = (try? kernel.memory.peek32(kernel.current.cpu.threadLocalStorageAddress + 0x184)) ?? 0
            // The static buffer is padded to the requested size; the reply reports the parameter's own size.
            let size = Int(request.param(1)), buffer = Array(parameter.buffer.prefix(size))
            try? kernel.memory.writeBytes(pointer, buffer + [UInt8](repeating: 0, count: size - buffer.count))
            return IPCReply(command: command, [0, parameter.sender, parameter.signal, UInt32(buffer.count)],
                            translate: [0, parameter.handle, UInt32(size) << 14 | 2, pointer])
        default:
            return nil
        }
    }

    // Software keyboard config (0x400 bytes): buttons at 0x4, max length at 0x20, return code at 0x138, text offset at
    // 0x144 and length at 0x148. The text goes to the shared memory as UTF-16 with a terminator; the rightmost (OK) button is pressed.
    private func finishKeyboard(_ config: inout [UInt8], text memory: KSharedMemory) {
        func put(_ offset: Int, _ value: UInt32, _ count: Int = 4) { for i in 0..<count { config[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        let buttons = Int(config[4]), limit = Int(config[0x20]) | Int(config[0x21]) << 8
        let units = Array(keyboardText.utf16.prefix(limit == 0 ? Int.max : limit))
        for (i, unit) in (units + [0]).enumerated() {
            memory.pages[i * 2 >> 12].bytes[i * 2 & 0xFFF] = UInt8(unit & 0xFF)
            memory.pages[(i * 2 + 1) >> 12].bytes[(i * 2 + 1) & 0xFFF] = UInt8(unit >> 8)
        }
        put(0x138, buttons < 3 ? [0, 2, 5][buttons] : UInt32(bitPattern: -1))
        put(0x144, 0)
        put(0x148, UInt32(units.count), 2)
    }
}
