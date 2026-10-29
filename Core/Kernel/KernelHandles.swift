// input: kernel object creation, process lookup and handle-close requests
// output: typed process handles and kernel result codes
// pos: minimal per-process kernel handle table

final class KernelHandles {
    static let success: UInt32 = 0
    static let invalidHandle: UInt32 = 0xD8E0_07F7
    static let outOfHandles: UInt32 = 0xD860_0413
    static let currentProcess: UInt32 = 0xFFFF_8001

    enum Object {
        case addressArbiter
        case resourceLimit
    }
    private struct Slot {
        let handle: UInt32
        let object: Object
    }
    private var slots = [Slot?](repeating: nil, count: 4096)
    private var generation: UInt32 = 1

    func createAddressArbiter() -> (result: UInt32, handle: UInt32?) {
        create(.addressArbiter)
    }

    func getResourceLimit(process: UInt32) -> (result: UInt32, handle: UInt32?) {
        guard process == Self.currentProcess else { return (Self.invalidHandle, nil) }
        return create(.resourceLimit)
    }

    private func create(_ object: Object) -> (result: UInt32, handle: UInt32?) {
        guard let slot = slots.firstIndex(where: { $0 == nil }) else {
            return (Self.outOfHandles, nil)
        }
        let handle = UInt32(slot) << 15 | generation
        slots[slot] = Slot(handle: handle, object: object)
        generation = generation == 0x7FFF ? 1 : generation + 1
        return (Self.success, handle)
    }

    func isResourceLimit(_ handle: UInt32) -> Bool {
        let slot = Int(handle >> 15)
        guard slot < slots.count, let entry = slots[slot], entry.handle == handle else { return false }
        if case .resourceLimit = entry.object { return true }
        return false
    }

    func close(_ handle: UInt32) -> UInt32 {
        let slot = Int(handle >> 15)
        guard slot < slots.count, slots[slot]?.handle == handle else { return Self.invalidHandle }
        slots[slot] = nil
        return Self.success
    }
}
