// input: a guest program, its memory, and an instruction budget.
// output: execution of every guest thread until the budget ends, the program exits, or something unsupported happens.
// pos: emulated 3DS kernel: handle table, thread scheduler, virtual clock; SVC bodies live in the SVC*.swift extensions.
import Foundation

enum KernelStop: Equatable {
    case budgetReached
    case exited
    case cpu(ARMStop, thread: UInt32)
    case unsupportedSVC(UInt32, pc: UInt32)
    case unsupported(String)
    case deadlock
}

// Work the emulator itself performs at a virtual time, for example GSP's 60 Hz VBlank interrupt.
// interval 0 fires once; otherwise the event repeats every `interval` ticks.
struct HostEvent {
    var fireAt: UInt64
    let interval: UInt64
    let action: () -> Void
}

final class Kernel {
    static let currentProcessHandle: UInt32 = 0xFFFF_8001
    static let currentThreadHandle: UInt32 = 0xFFFF_8000
    static let ticksPerNanosecond = 0.268_111_856
    static let sliceLength = 20_000

    let memory = PagedMemory()
    var services: [String: HLEService] = [:]   // ports reachable by ConnectToPort
    var serviceDirectory: [String: HLEService] = [:]   // names resolved by srv: GetServiceHandle
    var threads: [KThread] = []
    var current: KThread!
    var ticks: UInt64 = 0
    var stop: KernelStop?
    var log: [String] = []
    var stubbedCalls: [String] = []
    var traceSVC = false
    // Debug aid: the most recent program counters, oldest first once `history` is full.
    var recordHistory = false
    var history: [UInt32] = []
    let process = KProcess()
    var memoryLimit: UInt32 = 64 * 1024 * 1024
    var committedBytes: UInt32 = 0
    var linearTop: UInt32 = 0
    var nextThreadID: UInt32 = 1
    var hostEvents: [HostEvent] = []
    private let postedLock = NSLock()
    private var posted: [HostEvent] = []
    var gpu = GPUState()
    private var slots = [KObject?](repeating: nil, count: 4096)
    private var generations = [UInt32](repeating: 1, count: 4096)
    private var handleValues = [UInt32](repeating: 0, count: 4096)

    // MARK: Handles

    func create(_ object: KObject) -> UInt32? {
        guard let slot = slots.firstIndex(where: { $0 == nil }) else { return nil }
        slots[slot] = object
        let handle = UInt32(slot) << 15 | generations[slot]
        generations[slot] = generations[slot] == 0x7FFF ? 1 : generations[slot] + 1
        handleValues[slot] = handle
        return handle
    }

    func object(_ handle: UInt32) -> KObject? {
        switch handle {
        case Self.currentProcessHandle: return process
        case Self.currentThreadHandle: return current
        default:
            let slot = Int(handle >> 15)
            guard slot < slots.count, handleValues[slot] == handle else { return nil }
            return slots[slot]
        }
    }

    func object<T: KObject>(_ handle: UInt32, as type: T.Type) -> T? { object(handle) as? T }

    func close(_ handle: UInt32) -> UInt32 {
        let slot = Int(handle >> 15)
        guard slot < slots.count, slots[slot] != nil, handleValues[slot] == handle else { return KernelResult.invalidHandle }
        slots[slot] = nil
        return KernelResult.success
    }

    // MARK: Scheduling

    func nanosecondsToTicks(_ ns: UInt64) -> UInt64 { UInt64(Double(ns) * Self.ticksPerNanosecond) }

    func addThread(priority: UInt32, entry: UInt32, argument: UInt32, stackTop: UInt32) -> KThread? {
        let id = nextThreadID
        let tls = 0x1FF8_2000 + (id - 1) * 0x200
        if memory.isFree(tls & ~0xFFF, size: 0x1000) {
            memory.map(tls & ~0xFFF, size: 0x1000, permission: .readWrite, kind: 0x10)
        }
        nextThreadID += 1
        let thread = KThread(id: id, priority: priority, entry: entry, argument: argument, stackTop: stackTop, tls: tls)
        threads.append(thread)
        return thread
    }

    func block(_ thread: KThread, on objects: [KObject], all: Bool, timeoutNanoseconds: Int64) {
        thread.state = .waiting
        thread.waitObjects = objects
        thread.waitAll = all
        thread.wakeAt = timeoutNanoseconds < 0 ? nil : ticks + nanosecondsToTicks(UInt64(timeoutNanoseconds))
        for object in objects { object.waiters.append(thread) }
    }

    func sleep(_ thread: KThread, nanoseconds: Int64) {
        thread.state = .waiting
        thread.waitObjects = []
        thread.wakeAt = ticks + nanosecondsToTicks(UInt64(max(nanoseconds, 0)))
    }

    private func resume(_ thread: KThread, result: UInt32, index: UInt32 = 0) {
        for object in thread.waitObjects { object.waiters.removeAll { $0 === thread } }
        thread.waitObjects = []
        thread.wakeAt = nil
        thread.arbitrationAddress = nil
        thread.cpu.registers[0] = result
        thread.cpu.registers[1] = index
        thread.state = .ready
    }

    // Wakes a waiter if its wait condition now holds.
    func tryWake(_ thread: KThread) {
        guard thread.state == .waiting, !thread.waitObjects.isEmpty else { return }
        if thread.waitAll {
            guard thread.waitObjects.allSatisfy({ !$0.shouldWait(thread) }) else { return }
            thread.waitObjects.forEach { $0.acquire(thread) }
            resume(thread, result: KernelResult.success)
        } else if let index = thread.waitObjects.firstIndex(where: { !$0.shouldWait(thread) }) {
            thread.waitObjects[index].acquire(thread)
            resume(thread, result: KernelResult.success, index: UInt32(index))
        }
    }

    func signalChanged(_ object: KObject) {
        for waiter in object.waiters { tryWake(waiter) }
    }

    func wake(_ thread: KThread, result: UInt32) { resume(thread, result: result) }

    private func expireTimers() {
        for thread in threads where thread.state == .waiting {
            if let at = thread.wakeAt, at <= ticks {
                resume(thread, result: thread.waitObjects.isEmpty && thread.arbitrationAddress == nil ? 0 : KernelResult.timeout)
            }
        }
        fireHostEvents()
        for case let timer as KTimer in slots.compactMap({ $0 }) {
            guard let at = timer.fireAt, at <= ticks else { continue }
            timer.signaled = true
            timer.fireAt = timer.interval > 0 ? at + timer.interval : nil
            signalChanged(timer)
        }
    }

    // MARK: Host events

    // One-shot work at an emulated tick; emulation thread only.
    func schedule(atTick tick: UInt64, _ action: @escaping () -> Void) {
        hostEvents.append(HostEvent(fireAt: tick, interval: 0, action: action))
    }

    // Any thread: the action runs on the emulation thread at the next slice boundary whose tick is >= `tick`.
    // Delivery is at a later tick when the post arrives after the kernel already passed `tick`; for an exact
    // tick, schedule(atTick:) from the emulation thread and have that action wait for the other thread's result.
    func post(atTick tick: UInt64, _ action: @escaping () -> Void) {
        postedLock.lock()
        posted.append(HostEvent(fireAt: tick, interval: 0, action: action))
        postedLock.unlock()
    }

    private func fireHostEvents() {
        postedLock.lock()
        if !posted.isEmpty { hostEvents += posted; posted.removeAll() }
        postedLock.unlock()
        // Events an action adds wait for the next pass, as periodic events always have.
        var index = 0
        for _ in 0..<hostEvents.count {
            guard hostEvents[index].fireAt <= ticks else { index += 1; continue }
            let event = hostEvents[index]
            if event.interval > 0 { hostEvents[index].fireAt += event.interval; index += 1 }
            else { hostEvents.remove(at: index) }
            event.action()
        }
    }

    private func pickThread() -> KThread? {
        guard let best = threads.filter({ $0.state == .ready }).map({ $0.priority }).min(),
              let index = threads.firstIndex(where: { $0.state == .ready && $0.priority == best }) else { return nil }
        let thread = threads.remove(at: index)
        threads.append(thread)
        return thread
    }

    private func nextWakeTime() -> UInt64? {
        let sleepers = threads.compactMap { $0.state == .waiting ? $0.wakeAt : nil }
        let timers = slots.compactMap { ($0 as? KTimer)?.fireAt }
        return (sleepers + timers + hostEvents.map { $0.fireAt }).min()
    }

    func note(_ text: String) {
        if log.count >= 200_000 { log.removeFirst(100_000) }
        log.append(text)
    }

    // MARK: Run loop

    func run(instructionBudget: UInt64) -> KernelStop {
        var executed: UInt64 = 0
        while executed < instructionBudget {
            expireTimers()
            guard let thread = pickThread() else {
                guard let wake = nextWakeTime() else { return stop ?? .deadlock }
                ticks = max(ticks, wake)
                continue
            }
            current = thread
            // The 3DS kernel executes CLREX on every exception return, so an LDREX/STREX pair cut by an interrupt or a
            // thread switch fails and retries instead of overwriting what HLE services or other threads stored meanwhile.
            thread.cpu.clearExclusiveMonitor()
            var slice = 0
            // Debug aids that observe single instructions run the CPU one step at a time.
            let stepwise = recordHistory || memory.watchAddress != PagedMemory.noWatch
            while slice < Self.sliceLength, thread.state == .ready, executed < instructionBudget {
                if recordHistory { if history.count >= 400 { history.removeFirst() }; history.append(thread.id << 28 | thread.cpu.pc >> 0 & 0x0FFF_FFFF) }
                let limit = stepwise ? 1 : min(Self.sliceLength - slice, Int(instructionBudget - executed))
                let (result, count) = thread.cpu.run(memory: memory, limit: limit)
                ticks &+= UInt64(count); executed &+= UInt64(count); slice += count
                switch result {
                case .running: continue
                case .supervisorCall(let number):
                    thread.cpu.clearExclusiveMonitor()
                    if let halted = dispatchSVC(number, thread: thread) { return halted }
                default:
                    return .cpu(result, thread: thread.id)
                }
                if let halted = stop { return halted }
            }
        }
        return .budgetReached
    }
}
