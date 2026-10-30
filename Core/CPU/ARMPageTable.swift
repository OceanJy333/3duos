// input: host pointers for guest pages that the memory owner publishes on map, unmap and protect.
// output: direct 4 KiB page lookups for loads, stores and instruction fetch, plus per-page pre-decoded instructions.
// pos: fast path between ARM11CPU and guest memory; the memory owner stays the source of truth.

final class ARMPageTable {
    static let pageCount = 1 << 20
    // nil means "ask the ARMMemory": unmapped, not permitted, or watched.
    let readable: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    let writable: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    // Decoded instructions by virtual page; each entry is checked against the fetched word before use.
    private let decoded: UnsafeMutablePointer<UnsafeMutablePointer<ARMDecodedOp>?>

    init() {
        readable = .allocate(capacity: Self.pageCount)
        readable.initialize(repeating: nil, count: Self.pageCount)
        writable = .allocate(capacity: Self.pageCount)
        writable.initialize(repeating: nil, count: Self.pageCount)
        decoded = .allocate(capacity: Self.pageCount)
        decoded.initialize(repeating: nil, count: Self.pageCount)
    }

    deinit {
        for i in 0..<Self.pageCount { decoded[i]?.deallocate() }
        readable.deallocate(); writable.deallocate(); decoded.deallocate()
    }

    func set(page: Int, read: UnsafeMutableRawPointer?, write: UnsafeMutableRawPointer?) {
        readable[page] = read
        writable[page] = write
    }

    func decodedPage(_ page: Int) -> UnsafeMutablePointer<ARMDecodedOp> {
        if let existing = decoded[page] { return existing }
        let fresh = UnsafeMutablePointer<ARMDecodedOp>.allocate(capacity: 1024)
        fresh.initialize(repeating: ARMDecodedOp(), count: 1024)
        decoded[page] = fresh
        return fresh
    }

    // Word accesses must be aligned here; misaligned ones take the ARMMemory path and its fault.
    @inline(__always) func load32(_ address: UInt32) -> UInt32? {
        guard address & 3 == 0, let page = readable[Int(address >> 12)] else { return nil }
        return page.load(fromByteOffset: Int(address & 0xFFF), as: UInt32.self)
    }

    @inline(__always) func store32(_ address: UInt32, _ value: UInt32) -> Bool {
        guard address & 3 == 0, let page = writable[Int(address >> 12)] else { return false }
        page.storeBytes(of: value, toByteOffset: Int(address & 0xFFF), as: UInt32.self)
        return true
    }

    @inline(__always) func load8(_ address: UInt32) -> UInt8? {
        guard let page = readable[Int(address >> 12)] else { return nil }
        return page.load(fromByteOffset: Int(address & 0xFFF), as: UInt8.self)
    }

    @inline(__always) func store8(_ address: UInt32, _ value: UInt8) -> Bool {
        guard let page = writable[Int(address >> 12)] else { return false }
        page.storeBytes(of: value, toByteOffset: Int(address & 0xFFF), as: UInt8.self)
        return true
    }
}
