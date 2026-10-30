// input: thread, wait and synchronization-object SVC registers.
// output: thread creation and scheduling effects, object state changes, and wake-ups.
// pos: SVC bodies for concurrency; ABI argument placement follows the 3DS kernel.
import Foundation

extension Kernel {
    private func timeout(_ low: UInt32, _ high: UInt32) -> Int64 { Int64(bitPattern: UInt64(high) << 32 | UInt64(low)) }

    func createThread(_ cpu: ARM11CPU) {
        let priority = cpu.registers[0], entry = cpu.registers[1], argument = cpu.registers[2], stackTop = cpu.registers[3]
        guard priority <= 0x3F else { cpu.registers[0] = KernelResult.invalidEnumValue; return }
        guard let thread = addThread(priority: priority, entry: entry, argument: argument, stackTop: stackTop),
              let handle = create(thread) else { cpu.registers[0] = KernelResult.outOfHandles; return }
        cpu.registers[0] = KernelResult.success
        cpu.registers[1] = handle
    }

    func exitThread(_ thread: KThread) {
        thread.state = .dead
        signalChanged(thread)
        if !threads.contains(where: { $0.state != .dead }) { stop = .exited }
    }

    func sleepThread(_ thread: KThread) {
        let ns = timeout(thread.cpu.registers[0], thread.cpu.registers[1])
        sleep(thread, nanoseconds: ns)
        if ns <= 0 { thread.state = .ready; thread.wakeAt = nil }
        thread.cpu.registers[0] = 0
    }

    func getThreadPriority(_ cpu: ARM11CPU) {
        guard let thread = object(cpu.registers[1], as: KThread.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        cpu.registers[0] = 0
        cpu.registers[1] = thread.priority
    }

    func setThreadPriority(_ cpu: ARM11CPU) {
        guard let thread = object(cpu.registers[0], as: KThread.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        thread.priority = cpu.registers[1] & 0x3F
        cpu.registers[0] = 0
    }

    func getThreadID(_ cpu: ARM11CPU) {
        guard let thread = object(cpu.registers[1], as: KThread.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        cpu.registers[0] = 0
        cpu.registers[1] = thread.id
    }

    private func store(_ object: KObject, _ cpu: ARM11CPU) {
        guard let handle = create(object) else { cpu.registers[0] = KernelResult.outOfHandles; return }
        cpu.registers[0] = 0
        cpu.registers[1] = handle
    }

    func createMutex(_ cpu: ARM11CPU) {
        let mutex = KMutex()
        if cpu.registers[1] & 1 != 0 { mutex.holder = current; mutex.lockCount = 1 }
        store(mutex, cpu)
    }

    func releaseMutex(_ thread: KThread) {
        let cpu = thread.cpu
        guard let mutex = object(cpu.registers[0], as: KMutex.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        guard mutex.holder === thread else { cpu.registers[0] = KernelResult.notOwner; return }
        mutex.lockCount -= 1
        if mutex.lockCount == 0 { mutex.holder = nil; signalChanged(mutex) }
        cpu.registers[0] = 0
    }

    func createSemaphore(_ cpu: ARM11CPU) {
        store(KSemaphore(count: Int32(bitPattern: cpu.registers[1]), maximum: Int32(bitPattern: cpu.registers[2])), cpu)
    }

    func releaseSemaphore(_ cpu: ARM11CPU) {
        guard let semaphore = object(cpu.registers[1], as: KSemaphore.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        let release = Int32(bitPattern: cpu.registers[2])
        guard release >= 0, Int64(semaphore.count) + Int64(release) <= Int64(semaphore.maximum) else {
            cpu.registers[0] = KernelResult.semaphoreOverflow; return
        }
        cpu.registers[0] = 0
        cpu.registers[1] = UInt32(bitPattern: semaphore.count)
        semaphore.count += release
        signalChanged(semaphore)
    }

    func createEvent(_ cpu: ARM11CPU) {
        guard let reset = KEvent.Reset(rawValue: cpu.registers[1]) else { cpu.registers[0] = KernelResult.invalidEnumValue; return }
        store(KEvent(reset: reset), cpu)
    }

    func signalEvent(_ cpu: ARM11CPU) {
        guard let event = object(cpu.registers[0], as: KEvent.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        event.signaled = true
        signalChanged(event)
        if event.reset == .pulse { event.signaled = false }
        cpu.registers[0] = 0
    }

    func clearEvent(_ cpu: ARM11CPU) {
        guard let event = object(cpu.registers[0], as: KEvent.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        event.signaled = false
        cpu.registers[0] = 0
    }

    func createTimer(_ cpu: ARM11CPU) {
        guard let reset = KEvent.Reset(rawValue: cpu.registers[1]) else { cpu.registers[0] = KernelResult.invalidEnumValue; return }
        store(KTimer(reset: reset), cpu)
    }

    func setTimer(_ cpu: ARM11CPU) {
        guard let timer = object(cpu.registers[0], as: KTimer.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        let initial = timeout(cpu.registers[2], cpu.registers[3]), interval = timeout(cpu.registers[1], cpu.registers[4])
        timer.signaled = false
        timer.fireAt = ticks + nanosecondsToTicks(UInt64(max(initial, 0)))
        timer.interval = nanosecondsToTicks(UInt64(max(interval, 0)))
        cpu.registers[0] = 0
    }

    func cancelTimer(_ cpu: ARM11CPU) {
        guard let timer = object(cpu.registers[0], as: KTimer.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        timer.fireAt = nil
        cpu.registers[0] = 0
    }

    func clearTimer(_ cpu: ARM11CPU) {
        guard let timer = object(cpu.registers[0], as: KTimer.self) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        timer.signaled = false
        cpu.registers[0] = 0
    }

    func createAddressArbiter(_ cpu: ARM11CPU) { store(KAddressArbiter(), cpu) }

    // Types: 0 signal, 1/3 wait if less than, 2/4 decrement and wait if less than (3 and 4 with timeout).
    func arbitrateAddress(_ thread: KThread) {
        let cpu = thread.cpu
        guard object(cpu.registers[0], as: KAddressArbiter.self) != nil else { cpu.registers[0] = KernelResult.invalidHandle; return }
        let address = cpu.registers[1], type = cpu.registers[2], value = Int32(bitPattern: cpu.registers[3])
        if type == 0 {
            var count = value < 0 ? Int.max : Int(value)
            let waiting = threads.filter { $0.state == .waiting && $0.arbitrationAddress == address }
                .sorted { $0.priority < $1.priority }
            for waiter in waiting where count > 0 { wake(waiter, result: 0); count -= 1 }
            cpu.registers[0] = 0
            return
        }
        guard (1...4).contains(type), address & 3 == 0, let current = try? memory.read32(address) else {
            cpu.registers[0] = type > 4 ? KernelResult.invalidEnumValue : KernelResult.invalidAddress; return
        }
        cpu.registers[0] = 0
        guard Int32(bitPattern: current) < value else { return }
        if type == 2 || type == 4 { try? memory.write32(address, current &- 1) }
        let limit = type >= 3 ? timeout(cpu.registers[4], cpu.registers[5]) : -1
        thread.arbitrationAddress = address
        thread.state = .waiting
        thread.wakeAt = limit < 0 ? nil : ticks + nanosecondsToTicks(UInt64(limit))
    }

    func waitSynchronization1(_ thread: KThread) {
        let cpu = thread.cpu
        guard let target = object(cpu.registers[0]) else { cpu.registers[0] = KernelResult.invalidHandle; return }
        let limit = timeout(cpu.registers[2], cpu.registers[3])
        if !target.shouldWait(thread) { target.acquire(thread); cpu.registers[0] = 0 }
        else if limit == 0 { cpu.registers[0] = KernelResult.timeout }
        else { block(thread, on: [target], all: false, timeoutNanoseconds: limit) }
    }

    func waitSynchronizationN(_ thread: KThread) {
        let cpu = thread.cpu
        let count = Int(cpu.registers[2]), all = cpu.registers[3] & 1 != 0, limit = timeout(cpu.registers[0], cpu.registers[4])
        guard count > 0, count <= 0x40, let words = try? memory.readBytes(cpu.registers[1], count: count * 4) else {
            cpu.registers[0] = KernelResult.invalidAddress; return
        }
        var objects: [KObject] = []
        for i in 0..<count {
            let handle = (0..<4).reduce(UInt32(0)) { $0 | UInt32(words[i * 4 + $1]) << ($1 * 8) }
            guard let object = object(handle) else { cpu.registers[0] = KernelResult.invalidHandle; return }
            objects.append(object)
        }
        let ready = all ? (objects.allSatisfy { !$0.shouldWait(thread) } ? 0 : nil)
                        : objects.firstIndex { !$0.shouldWait(thread) }
        if let index = ready {
            if all { objects.forEach { $0.acquire(thread) } } else { objects[index].acquire(thread) }
            cpu.registers[0] = 0
            cpu.registers[1] = UInt32(index)
        } else if limit == 0 { cpu.registers[0] = KernelResult.timeout }
        else { block(thread, on: objects, all: all, timeoutNanoseconds: limit) }
    }
}
