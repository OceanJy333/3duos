// input: srv: IPC commands from the guest and the table of HLE services.
// output: service session handles and notification objects.
// pos: HLE of the 3DS service manager; every other service is reached through GetServiceHandle.
import Foundation

final class ServiceManager: HLEService {
    let name = "srv:"
    private var notification: UInt32?

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        switch request.command {
        case 0x01: // RegisterClient
            return IPCReply(command: 1, [0])
        case 0x02: // EnableNotification: returns a semaphore for service notifications.
            if notification == nil { notification = kernel.create(KSemaphore(count: 0, maximum: 1)) }
            return IPCReply(command: 2, [0], translate: [0, notification!])
        case 0x05: // GetServiceHandle(name[8], length, flags)
            let nameBytes = (1...2).flatMap { i in (0..<4).map { UInt8(truncatingIfNeeded: request.words[i] >> ($0 * 8)) } }
            let length = Int(min(request.param(2), 8))
            let service = String(decoding: nameBytes.prefix(length), as: UTF8.self)
            if kernel.serviceDirectory[service] == nil { kernel.serviceDirectory[service] = StubService(name: service) }
            let target = kernel.serviceDirectory[service]!
            guard let handle = kernel.create(KSession(service: target)) else { return IPCReply(command: 5, [KernelResult.outOfHandles], translate: [0, 0]) }
            kernel.note("GetServiceHandle(\(service))")
            return IPCReply(command: 5, [0], translate: [0, handle])
        default:
            return nil
        }
    }
}
