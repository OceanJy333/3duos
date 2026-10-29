// input: decoded cartridge segments and requested memory accesses.
// output: mapped little-endian memory or an address fault.
// pos: boot probe memory backing for the ARM11 interpreter.
import Foundation

enum ProgramMemoryError: Error {
    case invalidMapping(String)
    case address(UInt32)
}

final class ProgramMemory: KernelMemory {
    static let mainThreadTLS: UInt32 = 0x1FF8_2000
    private struct Region {
        let start: UInt32
        var bytes: [UInt8]
        let writable: Bool
        let readableOffsets: [Range<Int>]?
        var end: UInt64 { UInt64(start) + UInt64(bytes.count) }
    }
    private var regions: [Region] = []
    private var applicationBytes: UInt64 = 0

    init(program: CartridgeProgram) throws {
        let initialBytes = [program.text, program.ro, program.data].reduce(UInt64(0)) { $0 + UInt64($1.bytes.count) }
            + UInt64(program.bssSize) + UInt64(program.stackSize)
        guard initialBytes <= CartridgeProgramLoader.applicationMemoryLimit else {
            throw ProgramMemoryError.invalidMapping("program exceeds application memory")
        }
        for segment in [program.text, program.ro, program.data] {
            try map(segment.address, bytes: [UInt8](segment.bytes))
        }
        let bssStart = UInt64(program.data.address) + UInt64(program.data.bytes.count)
        guard bssStart <= UInt64(UInt32.max), UInt64(program.bssSize) <= UInt64(UInt32.max) + 1 - bssStart else {
            throw ProgramMemoryError.invalidMapping("BSS exceeds address space")
        }
        try map(UInt32(bssStart), bytes: [UInt8](repeating: 0, count: Int(program.bssSize)))
        let stackTop: UInt32 = 0x1000_0000
        guard program.stackSize <= stackTop else { throw ProgramMemoryError.invalidMapping("stack exceeds address space") }
        try map(stackTop - program.stackSize, bytes: [UInt8](repeating: 0, count: Int(program.stackSize)))
        try map(Self.mainThreadTLS, bytes: [UInt8](repeating: 0, count: 0x1000))
        // Old3DS retail, APPMEMTYPE 0: APPMEMALLOC is 64 MiB.
        var config = [UInt8](repeating: 0, count: 0x1000)
        config[0x43] = UInt8(CartridgeProgramLoader.applicationMemoryLimit >> 24)
        try map(0x1FF8_0000, bytes: config, writable: false,
                readableOffsets: [0x30..<0x34, 0x40..<0x44])
        applicationBytes = initialBytes
    }

    private func map(_ address: UInt32, bytes: [UInt8], writable: Bool = true,
                     readableOffsets: [Range<Int>]? = nil) throws {
        guard !bytes.isEmpty else { return }
        let end = UInt64(address) + UInt64(bytes.count)
        guard end <= UInt64(UInt32.max) + 1,
              !regions.contains(where: { UInt64(address) < $0.end && UInt64($0.start) < end }) else {
            throw ProgramMemoryError.invalidMapping("overlapping or out-of-range region")
        }
        regions.append(Region(start: address, bytes: bytes, writable: writable, readableOffsets: readableOffsets))
    }

    func commit(address: UInt32, size: UInt32, permission: UInt32) -> Bool {
        let end = UInt64(address) + UInt64(size)
        guard applicationBytes + UInt64(size) <= CartridgeProgramLoader.applicationMemoryLimit,
              end <= UInt64(UInt32.max) + 1,
              !regions.contains(where: { UInt64(address) < $0.end && UInt64($0.start) < end }) else { return false }
        do {
            try map(address, bytes: [UInt8](repeating: 0, count: Int(size)), writable: permission == 3)
            applicationBytes += UInt64(size)
            return true
        } catch {
            return false
        }
    }

    private func location(_ address: UInt32, count: Int, writing: Bool = false) throws -> (Int, Int) {
        guard let index = regions.firstIndex(where: { UInt64(address) >= UInt64($0.start) && UInt64(address) + UInt64(count) <= $0.end }) else {
            throw ProgramMemoryError.address(address)
        }
        let offset = Int(address - regions[index].start)
        let region = regions[index]
        guard (!writing || region.writable),
              region.readableOffsets?.contains(where: { offset >= $0.lowerBound && offset + count <= $0.upperBound }) ?? true else {
            throw ProgramMemoryError.address(address)
        }
        return (index, offset)
    }

    func read8(_ address: UInt32) throws -> UInt8 {
        let (region, offset) = try location(address, count: 1)
        return regions[region].bytes[offset]
    }
    func read32(_ address: UInt32) throws -> UInt32 {
        guard address & 3 == 0 else { throw ProgramMemoryError.address(address) }
        let (region, offset) = try location(address, count: 4)
        return (0..<4).reduce(0) { $0 | UInt32(regions[region].bytes[offset + $1]) << ($1 * 8) }
    }
    func write8(_ address: UInt32, _ value: UInt8) throws {
        let (region, offset) = try location(address, count: 1, writing: true)
        regions[region].bytes[offset] = value
    }
    func write32(_ address: UInt32, _ value: UInt32) throws {
        guard address & 3 == 0 else { throw ProgramMemoryError.address(address) }
        let (region, offset) = try location(address, count: 4, writing: true)
        for i in 0..<4 { regions[region].bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}
