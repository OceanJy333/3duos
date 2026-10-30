// input: kernel object creation and signalling by SVCs and services.
// output: waitable objects with the synchronization rules of the 3DS kernel.
// pos: object model behind guest handles, scheduled by Kernel.
import Foundation

enum KernelResult {
    static let success: UInt32 = 0
    static let timeout: UInt32 = 0x0940_1BFE
    static let invalidHandle: UInt32 = 0xD8E0_07F7
    static let invalidAddress: UInt32 = 0xE0E0_1BF5
    static let invalidCombination: UInt32 = 0xE0E0_1BEE
    static let outOfMemory: UInt32 = 0xD860_03F3
    static let outOfHandles: UInt32 = 0xD860_0413
    static let invalidEnumValue: UInt32 = 0xD8E0_07ED
    static let notAuthorized: UInt32 = 0xD900_182F
    static let invalidSize: UInt32 = 0xE0E0_1BF2
    static let notFound: UInt32 = 0xD880_07FA
    static let semaphoreOverflow: UInt32 = 0xD840_0834
    static let notOwner: UInt32 = 0xD8E0_0802
}

class KObject {
    var waiters: [KThread] = []
    var label: String?
    var name: String { label ?? String(describing: type(of: self)) }
    func shouldWait(_ thread: KThread) -> Bool { false }
    func acquire(_ thread: KThread) {}
}

final class KProcess: KObject {}

final class KResourceLimit: KObject {}

final class KAddressArbiter: KObject {}

final class KEvent: KObject {
    enum Reset: UInt32 { case oneShot = 0, sticky = 1, pulse = 2 }
    let reset: Reset
    var signaled = false
    init(reset: Reset) { self.reset = reset }
    override func shouldWait(_ thread: KThread) -> Bool { !signaled }
    override func acquire(_ thread: KThread) { if reset == .oneShot { signaled = false } }
}

final class KMutex: KObject {
    var holder: KThread?
    var lockCount = 0
    override func shouldWait(_ thread: KThread) -> Bool { lockCount > 0 && holder !== thread }
    override func acquire(_ thread: KThread) { holder = thread; lockCount += 1 }
}

final class KSemaphore: KObject {
    var count: Int32
    let maximum: Int32
    init(count: Int32, maximum: Int32) { self.count = count; self.maximum = maximum }
    override func shouldWait(_ thread: KThread) -> Bool { count <= 0 }
    override func acquire(_ thread: KThread) { count -= 1 }
}

final class KTimer: KObject {
    let reset: KEvent.Reset
    var signaled = false
    var fireAt: UInt64?
    var interval: UInt64 = 0
    init(reset: KEvent.Reset) { self.reset = reset }
    override func shouldWait(_ thread: KThread) -> Bool { !signaled }
    override func acquire(_ thread: KThread) { if reset == .oneShot { signaled = false } }
}

final class KSharedMemory: KObject {
    let pages: [MemoryPage]
    init(pages: [MemoryPage]) { self.pages = pages }
}

final class KSession: KObject {
    let service: HLEService
    init(service: HLEService) { self.service = service }
    override var name: String { "Session(\(service.name))" }
}

final class KThread: KObject {
    enum State { case ready, waiting, dead }
    let id: UInt32
    let cpu = ARM11CPU()
    var priority: UInt32
    var state = State.ready
    var waitObjects: [KObject] = []
    var waitAll = false
    var wakeAt: UInt64?
    var arbitrationAddress: UInt32?

    init(id: UInt32, priority: UInt32, entry: UInt32, argument: UInt32, stackTop: UInt32, tls: UInt32) {
        self.id = id
        self.priority = priority
        cpu.pc = entry & ~1
        if entry & 1 != 0 { cpu.cpsr |= 0x20 }
        cpu.registers[0] = argument
        cpu.registers[13] = stackTop
        cpu.threadLocalStorageAddress = tls
        cpu.fpexc = 0x4000_0000
    }

    override func shouldWait(_ thread: KThread) -> Bool { state != .dead }
}
