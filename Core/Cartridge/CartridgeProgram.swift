// input: cartridge metadata and ExeFS .code; output: decoded, page-aligned program segments.
// pos: cartridge loading layer before CPU memory mapping.
import Foundation

struct CartridgeMappedSegment {
    let address: UInt32
    let bytes: Data
    let usedSize: UInt32
}

struct CartridgeProgram {
    let text: CartridgeMappedSegment
    let ro: CartridgeMappedSegment
    let data: CartridgeMappedSegment
    let bssSize: UInt32
    let stackSize: UInt32
}

enum CartridgeProgramLoader {
    // Matches the Old3DS APPMEMALLOC used by the boot probe.
    static let applicationMemoryLimit: UInt64 = 64 * 1024 * 1024

    static func load(_ cartridge: Cartridge, from url: URL) throws -> CartridgeProgram {
        guard let region = cartridge.executable, let segments = cartridge.codeSegments else {
            throw CartridgeError.invalid("executable or extended header is missing")
        }
        let allSegments = [segments.text, segments.ro, segments.data]
        let codeSize = allSegments.reduce(UInt64(0)) { $0 + UInt64($1.pages) * 0x1000 }
        guard codeSize + UInt64(segments.bssSize) + UInt64(segments.stackSize) <= applicationMemoryLimit,
              allSegments.allSatisfy({ UInt64($0.size) <= UInt64($0.pages) * 0x1000 &&
                  UInt64($0.address) + UInt64($0.pages) * 0x1000 <= UInt64(UInt32.max) + 1 }) else {
            throw CartridgeError.invalid("program segments exceed application memory or address space")
        }
        let code = try CartridgeReader.readRegion(region, from: url)
        let decoded = cartridge.codeCompressed ? try decompress(code) : code
        var cursor = 0
        func mapped(_ segment: CartridgeSegment) throws -> CartridgeMappedSegment {
            let pageBytes = UInt64(segment.pages) * 0x1000
            guard UInt64(segment.size) <= pageBytes, pageBytes <= UInt64(decoded.count - cursor),
                  UInt64(segment.address) + pageBytes <= UInt64(UInt32.max) + 1 else {
                throw CartridgeError.invalid("code segment exceeds its backing data or address space")
            }
            let next = cursor + Int(pageBytes)
            let result = CartridgeMappedSegment(address: segment.address, bytes: decoded.subdata(in: cursor..<next), usedSize: segment.size)
            cursor = next
            return result
        }
        let text = try mapped(segments.text)
        let ro = try mapped(segments.ro)
        let data = try mapped(segments.data)
        return CartridgeProgram(text: text, ro: ro, data: data, bssSize: segments.bssSize, stackSize: segments.stackSize)
    }

    static func decompress(_ source: Data) throws -> Data {
        guard UInt64(source.count) <= applicationMemoryLimit else { throw CartridgeError.invalid("compressed code is too large") }
        let input = [UInt8](source)
        guard input.count >= 8 else { throw CartridgeError.invalid("compressed code footer is missing") }
        let n = input.count
        let encoded = Int(input[n-8]) | Int(input[n-7]) << 8 | Int(input[n-6]) << 16
        let footer = Int(input[n-5])
        let extra = Int(input[n-4]) | Int(input[n-3]) << 8 | Int(input[n-2]) << 16 | Int(input[n-1]) << 24
        guard footer >= 8, encoded >= footer, encoded <= n, extra > 0 else {
            throw CartridgeError.invalid("compressed code footer is invalid")
        }
        guard UInt64(n) + UInt64(extra) <= applicationMemoryLimit else { throw CartridgeError.invalid("decompressed code is too large") }
        let begin = n - encoded
        var read = n - footer
        var output = input + [UInt8](repeating: 0, count: extra)
        var write = output.count
        while read > begin {
            read -= 1
            let flags = input[read]
            for bit in 0..<8 {
                if read <= begin { break }
                if flags & (0x80 >> bit) == 0 {
                    guard write > begin else { throw CartridgeError.invalid("compressed literal overflows output") }
                    read -= 1
                    write -= 1
                    output[write] = input[read]
                } else {
                    guard read - begin >= 2 else { throw CartridgeError.invalid("truncated compressed reference") }
                    read -= 1
                    let high = Int(input[read])
                    read -= 1
                    let low = Int(input[read])
                    let length = (high >> 4) + 3
                    let distance = ((high & 15) << 8 | low) + 3
                    guard length <= write - begin else { throw CartridgeError.invalid("compressed reference overflows output") }
                    for _ in 0..<length {
                        write -= 1
                        guard write + distance < output.count else { throw CartridgeError.invalid("invalid compressed reference") }
                        output[write] = output[write + distance]
                    }
                }
            }
        }
        guard write == begin else { throw CartridgeError.invalid("compressed code length mismatch") }
        return Data(output)
    }
}
