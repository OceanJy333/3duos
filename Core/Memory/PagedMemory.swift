// input: map/unmap/protect requests and guest loads and stores on a 32-bit address space.
// output: little-endian memory through 4 KiB pages that may be aliased at several addresses.
// pos: guest virtual memory shared by the CPU, kernel, and HLE services.
import Foundation

enum MemoryError: Error, Equatable {
    case unmapped(UInt32)
    case permission(UInt32)
    case misaligned(UInt32)
}

final class MemoryPage {
    let bytes: UnsafeMutablePointer<UInt8>
    init() {
        bytes = .allocate(capacity: 4096)
        bytes.initialize(repeating: 0, count: 4096)
    }
    deinit { bytes.deallocate() }
}

struct MemoryPermission: OptionSet {
    let rawValue: UInt8
    static let read = MemoryPermission(rawValue: 1)
    static let write = MemoryPermission(rawValue: 2)
    static let execute = MemoryPermission(rawValue: 4)
    static let readWrite: MemoryPermission = [.read, .write]
}

struct MemoryInfo {
    let base: UInt32
    let size: UInt32
    let permission: MemoryPermission
    let kind: UInt8
}

final class PagedMemory: ARMMemory {
    static let pageCount = 1 << 20
    // Fixed buffers, not Arrays: no copy-on-write, so one other thread (the GPU) may read and write mapped pages
    // while this one maps. Map, unmap and protect stay on the emulation thread; the game's GPU synchronization
    // keeps it from unmapping a range the GPU is still using.
    private let pages = UnsafeMutablePointer<MemoryPage?>.allocate(capacity: PagedMemory.pageCount)
    private let permissions = UnsafeMutablePointer<UInt8>.allocate(capacity: PagedMemory.pageCount)
    private let kinds = UnsafeMutablePointer<UInt8>.allocate(capacity: PagedMemory.pageCount)
    private(set) var mappedPages = 0
    // Host pointers derived from `pages` and `permissions`, for the CPU's direct loads and stores.
    private let table = ARMPageTable()
    var pageTable: ARMPageTable? { table }
    static let noWatch: UInt32 = 0xFFFF_FFFF
    // Debug aid: called for every store to `watchAddress`; its page leaves the CPU fast path.
    var watchAddress: UInt32 = noWatch {
        didSet { publish(Int(oldValue >> 12)); publish(Int(watchAddress >> 12)) }
    }
    var onWatch: ((UInt32) -> Void)?

    init() {
        pages.initialize(repeating: nil, count: Self.pageCount)
        permissions.initialize(repeating: 0, count: Self.pageCount)
        kinds.initialize(repeating: 0, count: Self.pageCount)
    }

    deinit {
        pages.deinitialize(count: Self.pageCount)
        pages.deallocate(); permissions.deallocate(); kinds.deallocate()
    }

    private func publish(_ index: Int) {
        let host = pages[index].map { UnsafeMutableRawPointer($0.bytes) }
        let permission = permissions[index]
        let watched = watchAddress != Self.noWatch && index == Int(watchAddress >> 12)
        table.set(page: index, read: permission & MemoryPermission.read.rawValue != 0 ? host : nil,
                  write: permission & MemoryPermission.write.rawValue != 0 && !watched ? host : nil)
    }

    func isFree(_ address: UInt32, size: UInt32) -> Bool {
        forEachPage(address, size) { pages[$0] == nil }
    }

    func isMapped(_ address: UInt32, size: UInt32) -> Bool {
        forEachPage(address, size) { pages[$0] != nil }
    }

    private func forEachPage(_ address: UInt32, _ size: UInt32, _ test: (Int) -> Bool) -> Bool {
        let first = Int(address >> 12)
        let last = Int((UInt64(address) + UInt64(max(size, 1)) - 1) >> 12)
        guard last < Self.pageCount else { return false }
        return (first...last).allSatisfy(test)
    }

    // Maps fresh zeroed pages, or the supplied pages when aliasing existing storage.
    @discardableResult
    func map(_ address: UInt32, size: UInt32, permission: MemoryPermission, kind: UInt8 = 0,
             backing: [MemoryPage]? = nil) -> [MemoryPage]? {
        guard size > 0, address & 0xFFF == 0, size & 0xFFF == 0, isFree(address, size: size) else { return nil }
        let count = Int(size >> 12)
        guard backing == nil || backing!.count == count else { return nil }
        let first = Int(address >> 12)
        var result: [MemoryPage] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let page = backing?[i] ?? MemoryPage()
            pages[first + i] = page
            permissions[first + i] = permission.rawValue
            kinds[first + i] = kind
            publish(first + i)
            result.append(page)
        }
        mappedPages += count
        return result
    }

    func unmap(_ address: UInt32, size: UInt32) {
        guard address & 0xFFF == 0, size & 0xFFF == 0 else { return }
        let first = Int(address >> 12)
        for i in first..<min(first + Int(size >> 12), Self.pageCount) where pages[i] != nil {
            pages[i] = nil
            permissions[i] = 0
            publish(i)
            mappedPages -= 1
        }
    }

    func protect(_ address: UInt32, size: UInt32, permission: MemoryPermission) {
        let first = Int(address >> 12)
        for i in first..<min(first + Int(size >> 12), Self.pageCount) where pages[i] != nil {
            permissions[i] = permission.rawValue
            publish(i)
        }
    }

    func backing(_ address: UInt32, size: UInt32) -> [MemoryPage]? {
        guard isMapped(address, size: size) else { return nil }
        let first = Int(address >> 12)
        return (0..<Int(size >> 12)).map { pages[first + $0]! }
    }

    // Extent of the run of pages around `address` that share permission and kind.
    func query(_ address: UInt32) -> MemoryInfo {
        let index = Int(address >> 12)
        let mapped = pages[index] != nil
        let permission = permissions[index], kind = kinds[index]
        func same(_ i: Int) -> Bool { (pages[i] != nil) == mapped && permissions[i] == permission && kinds[i] == kind }
        var first = index, last = index
        while first > 0, same(first - 1) { first -= 1 }
        while last + 1 < Self.pageCount, same(last + 1) { last += 1 }
        return MemoryInfo(base: UInt32(first) << 12, size: UInt32(last - first + 1) << 12,
                          permission: MemoryPermission(rawValue: permission), kind: kind)
    }

    private func pointer(_ address: UInt32, count: Int, _ needed: MemoryPermission) throws -> UnsafeMutablePointer<UInt8> {
        let offset = Int(address & 0xFFF)
        guard offset + count <= 4096 else { throw MemoryError.misaligned(address) }
        let index = Int(address >> 12)
        guard let page = pages[index] else { throw MemoryError.unmapped(address) }
        guard permissions[index] & needed.rawValue == needed.rawValue else { throw MemoryError.permission(address) }
        return page.bytes + offset
    }

    func read8(_ address: UInt32) throws -> UInt8 { try pointer(address, count: 1, .read).pointee }
    func write8(_ address: UInt32, _ value: UInt8) throws {
        try pointer(address, count: 1, .write).pointee = value
        if address &- watchAddress < 4 { onWatch?(UInt32(value)) }
    }
    func read16(_ address: UInt32) throws -> UInt16 {
        guard address & 1 == 0 else { throw MemoryError.misaligned(address) }
        return UnsafeRawPointer(try pointer(address, count: 2, .read)).loadUnaligned(as: UInt16.self)
    }
    func write16(_ address: UInt32, _ value: UInt16) throws {
        guard address & 1 == 0 else { throw MemoryError.misaligned(address) }
        UnsafeMutableRawPointer(try pointer(address, count: 2, .write)).storeBytes(of: value, as: UInt16.self)
        if address &- watchAddress < 4 { onWatch?(UInt32(value)) }
    }
    func read32(_ address: UInt32) throws -> UInt32 {
        guard address & 3 == 0 else { throw MemoryError.misaligned(address) }
        return UnsafeRawPointer(try pointer(address, count: 4, .read)).loadUnaligned(as: UInt32.self)
    }
    func write32(_ address: UInt32, _ value: UInt32) throws {
        guard address & 3 == 0 else { throw MemoryError.misaligned(address) }
        UnsafeMutableRawPointer(try pointer(address, count: 4, .write)).storeBytes(of: value, as: UInt32.self)
        if address == watchAddress { onWatch?(value) }
    }

    // Kernel-side accesses ignore page permissions but still need mapped pages.
    func readBytes(_ address: UInt32, count: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        try result.withUnsafeMutableBufferPointer { out in
            var done = 0
            while done < count {
                let at = address &+ UInt32(done)
                guard let page = pages[Int(at >> 12)] else { throw MemoryError.unmapped(at) }
                let chunk = min(count - done, 0x1000 - Int(at & 0xFFF))
                (out.baseAddress! + done).update(from: page.bytes + Int(at & 0xFFF), count: chunk)
                done += chunk
            }
        }
        return result
    }

    func writeBytes(_ address: UInt32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer { input in
            var done = 0
            while done < input.count {
                let at = address &+ UInt32(done)
                guard let page = pages[Int(at >> 12)] else { throw MemoryError.unmapped(at) }
                let chunk = min(input.count - done, 0x1000 - Int(at & 0xFFF))
                (page.bytes + Int(at & 0xFFF)).update(from: input.baseAddress! + done, count: chunk)
                if watchAddress &- at < UInt32(chunk) { onWatch?(UInt32(input[done + Int(watchAddress &- at)])) }
                done += chunk
            }
        }
    }

    func poke32(_ address: UInt32, _ value: UInt32) throws {
        try writeBytes(address, (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    func peek32(_ address: UInt32) throws -> UInt32 {
        try readBytes(address, count: 4).enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
}
