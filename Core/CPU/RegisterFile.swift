// input: a fixed number of 32-bit words.
// output: a reference-semantics register array without copy-on-write checks on every store.
// pos: storage for the ARM11 interpreter's general and VFP registers.

struct RegisterFile: RandomAccessCollection {
    let base: UnsafeMutablePointer<UInt32>
    let count: Int
    var startIndex: Int { 0 }
    var endIndex: Int { count }

    init(count: Int) {
        self.count = count
        base = .allocate(capacity: count)
        base.initialize(repeating: 0, count: count)
    }

    func release() { base.deallocate() }

    subscript(index: Int) -> UInt32 {
        get { base[index] }
        nonmutating set { base[index] = newValue }
    }
}
