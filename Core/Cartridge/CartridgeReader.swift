// input: decrypted NCCH/CXI or NCSD/CCI URL; output: bounded cartridge metadata and regions.
// pos: file-format layer between imported images, the library UI, and the future loader.
import Foundation

struct CartridgeRegion: Equatable {
    let offset: UInt64
    let size: UInt64
}

struct CartridgeTitle {
    let short: String
    let long: String
    let publisher: String
}

struct CartridgeIcon {
    // Language order follows SMDH: Japanese, English, French, German, Italian,
    // Spanish, Simplified Chinese, Korean, Dutch, Portuguese, Russian, Traditional Chinese.
    let titles: [CartridgeTitle]
    // RGB565, top-to-bottom row-major, 48 pixels per row.
    let pixels: [UInt16]
}

struct CartridgeSegment {
    let address: UInt32
    let pages: UInt32
    let size: UInt32
}

struct CartridgeCodeSegments {
    let text: CartridgeSegment
    let ro: CartridgeSegment
    let data: CartridgeSegment
    let stackSize: UInt32
    let bssSize: UInt32
}

struct Cartridge {
    let programID: UInt64
    let productCode: String
    let codeCompressed: Bool
    let codeSegments: CartridgeCodeSegments?
    let executable: CartridgeRegion?
    let icon: CartridgeIcon?
    let exefs: [String: CartridgeRegion]
}

enum CartridgeError: Error, LocalizedError {
    case invalid(String)
    case encrypted
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid cartridge: \(reason)"
        case .encrypted: return "Encrypted NCCH is not supported; import a decrypted image."
        }
    }
}

enum CartridgeReader {
    static func read(url: URL) throws -> Cartridge {
        let file = try CartridgeFile(url: url)
        let header = try file.read(offset: 0, size: 0x200)
        let magic = header.ascii(0x100, 4)
        let partition: CartridgeRegion
        if magic == "NCCH" {
            partition = CartridgeRegion(offset: 0, size: file.size)
        } else if magic == "NCSD" {
            let declaredSize = header.u32(0x104) * 0x200
            var partitions: [CartridgeRegion] = []
            for index in 0..<8 {
                let offset = header.u32(0x120 + index * 8) * 0x200
                let size = header.u32(0x124 + index * 8) * 0x200
                if offset == 0 && size == 0 { continue }
                guard offset >= 0x200, size >= 0x200,
                      offset <= file.size, size <= file.size - offset,
                      offset <= declaredSize, size <= declaredSize - offset else {
                    throw CartridgeError.invalid("NCSD partition \(index) is out of bounds")
                }
                let entry = CartridgeRegion(offset: offset, size: size)
                guard !partitions.contains(where: { overlaps($0, entry) }) else {
                    throw CartridgeError.invalid("overlapping NCSD partitions")
                }
                partitions.append(entry)
            }
            let offset = header.u32(0x120) * 0x200
            let size = header.u32(0x124) * 0x200
            guard offset != 0 && size != 0 else {
                throw CartridgeError.invalid("NCSD executable partition is missing")
            }
            partition = CartridgeRegion(offset: offset, size: size)
        } else {
            throw CartridgeError.invalid("expected NCCH or NCSD magic")
        }
        return try readNCCH(file, partition: partition)
    }

    static func readRegion(_ region: CartridgeRegion, from url: URL) throws -> Data {
        let file = try CartridgeFile(url: url)
        guard region.size <= CartridgeProgramLoader.applicationMemoryLimit else {
            throw CartridgeError.invalid("region exceeds application memory")
        }
        return try file.read(offset: region.offset, size: Int(region.size))
    }

    private static func readNCCH(_ file: CartridgeFile, partition: CartridgeRegion) throws -> Cartridge {
        let header = try file.read(offset: partition.offset, size: 0x200)
        guard header.ascii(0x100, 4) == "NCCH" else { throw CartridgeError.invalid("partition is not NCCH") }
        let contentSize = header.u32(0x104) * 0x200
        guard contentSize >= 0x200, contentSize <= partition.size else {
            throw CartridgeError.invalid("NCCH content size is out of bounds")
        }
        guard header[0x18F] & 0x04 != 0 else { throw CartridgeError.encrypted }
        let extSize = header.u32(0x180)
        var segments: CartridgeCodeSegments?
        var compressed = false
        if extSize > 0 {
            guard extSize >= 0x40, extSize <= contentSize - 0x200 else {
                throw CartridgeError.invalid("extended header is out of bounds")
            }
            let ext = try file.read(offset: partition.offset + 0x200, size: 0x40)
            func segment(_ offset: Int) -> CartridgeSegment {
                CartridgeSegment(address: UInt32(ext.u32(offset)), pages: UInt32(ext.u32(offset + 4)), size: UInt32(ext.u32(offset + 8)))
            }
            segments = CartridgeCodeSegments(text: segment(0x10), ro: segment(0x20), data: segment(0x30),
                stackSize: UInt32(ext.u32(0x1C)), bssSize: UInt32(ext.u32(0x3C)))
            compressed = ext[0xD] & 1 != 0
        }
        let exefsOffset = header.u32(0x1A0) * 0x200
        let exefsSize = header.u32(0x1A4) * 0x200
        guard exefsOffset >= 0x200, exefsSize >= 0x200,
              exefsOffset <= contentSize, exefsSize <= contentSize - exefsOffset else {
            throw CartridgeError.invalid("ExeFS is out of bounds or missing")
        }
        let table = try file.read(offset: partition.offset + exefsOffset, size: 0x200)
        var entries: [String: CartridgeRegion] = [:]
        for index in 0..<10 {
            let start = index * 16
            let name = table.ascii(start, 8)
            let relativeOffset = table.u32(start + 8)
            let size = table.u32(start + 12)
            if name.isEmpty && relativeOffset == 0 && size == 0 { continue }
            guard !name.isEmpty, size > 0, entries[name] == nil,
                  relativeOffset <= exefsSize - 0x200,
                  size <= exefsSize - 0x200 - relativeOffset else {
                throw CartridgeError.invalid("invalid ExeFS entry \(index)")
            }
            let region = CartridgeRegion(offset: partition.offset + exefsOffset + 0x200 + relativeOffset, size: size)
            guard !entries.values.contains(where: { overlaps($0, region) }) else {
                throw CartridgeError.invalid("overlapping ExeFS entries")
            }
            entries[name] = region
        }
        var icon: CartridgeIcon?
        if let region = entries["icon"] {
            guard region.size >= 0x36C0 else { throw CartridgeError.invalid("SMDH is too short") }
            icon = try readIcon(file.read(offset: region.offset, size: 0x36C0))
        }
        return Cartridge(programID: header.u64(0x118), productCode: header.ascii(0x150, 16),
            codeCompressed: compressed, codeSegments: segments, executable: entries[".code"], icon: icon, exefs: entries)
    }

    private static func overlaps(_ a: CartridgeRegion, _ b: CartridgeRegion) -> Bool {
        a.offset < b.offset + b.size && b.offset < a.offset + a.size
    }

    private static func readIcon(_ data: Data) throws -> CartridgeIcon {
        guard data.ascii(0, 4) == "SMDH" else { throw CartridgeError.invalid("icon is not SMDH") }
        let titles = (0..<16).map { index in
            let start = 8 + index * 0x200
            return CartridgeTitle(short: data.utf16(start, 0x80), long: data.utf16(start + 0x80, 0x100), publisher: data.utf16(start + 0x180, 0x80))
        }
        var pixels = [UInt16](repeating: 0, count: 48 * 48)
        // Each 8x8 tile is stored in Morton (interleaved x/y bits) order.
        for y in 0..<48 {
            for x in 0..<48 {
                let tile = (y / 8) * 6 + x / 8
                let xx = x % 8, yy = y % 8
                let within = (xx & 1) | ((yy & 1) << 1) | ((xx & 2) << 1) | ((yy & 2) << 2) | ((xx & 4) << 2) | ((yy & 4) << 3)
                let offset = 0x24C0 + (tile * 64 + within) * 2
                pixels[y * 48 + x] = UInt16(data.u16(offset))
            }
        }
        return CartridgeIcon(titles: titles, pixels: pixels)
    }
}

private final class CartridgeFile {
    let handle: FileHandle
    let size: UInt64
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }
    deinit { try? handle.close() }
    func read(offset: UInt64, size count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw CartridgeError.invalid("read exceeds file size")
        }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw CartridgeError.invalid("short file read")
        }
        return data
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt64 { UInt64(self[offset]) | UInt64(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt64 { u16(offset) | u16(offset + 2) << 16 }
    func u64(_ offset: Int) -> UInt64 { u32(offset) | u32(offset + 4) << 32 }
    func ascii(_ offset: Int, _ length: Int) -> String {
        String(decoding: self[offset..<(offset + length)].prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    func utf16(_ offset: Int, _ length: Int) -> String {
        let units = stride(from: offset, to: offset + length, by: 2).map { UInt16(u16($0)) }.prefix(while: { $0 != 0 })
        return String(decoding: units, as: UTF16.self)
    }
}
