// input: decoded PICA register writes and a physical-memory reader
// output: register state and explicitly synthetic clip-space triangle vertices
// pos: GPU geometry bridge used to exercise command handling before PICA shaders exist

import Foundation

struct PICAPosition: Equatable {
    let x: Float
    let y: Float
}

enum PICASyntheticDrawError: Error, Equatable {
    case unsupportedConfiguration
    case vertexDataUnavailable
}

// This is a test bridge, not a PICA shader interpreter or full GPU pipeline.
// Register formats: https://www.3dbrew.org/wiki/GPU/Internal_Registers
struct PICASyntheticDraw {
    private(set) var registers: [UInt16: UInt32] = [:]
    subscript(_ register: UInt16) -> UInt32 { registers[register, default: 0] }

    mutating func execute(_ writes: [PICARegisterWrite], read: (UInt64, Int) -> [UInt8]?) throws -> [[PICAPosition]] {
        var draws: [[PICAPosition]] = []
        for write in writes {
            registers[write.register] = write.applying(to: self[write.register])
            if write.register == 0x22E && write.applying(to: 0) != 0 {
                draws.append(try vertices(read: read))
            }
        }
        return draws
    }

    private func vertices(read: (UInt64, Int) -> [UInt8]?) throws -> [PICAPosition] {
        // One float2 attribute, buffer 0, triangles, no geometry shader. A
        // fixed Metal vertex shader treats the attribute as clip-space XY.
        let stride = Int((self[0x205] >> 16) & 0xFF)
        guard self[0x201] & 0xF == 0x7,
              self[0x202] & 0xF001_0000 == 0,
              self[0x204] & 0xF == 0,
              self[0x205] >> 28 == 1,
              stride >= 8,
              self[0x229] & 0x8000_0103 == 0,
              self[0x25E] & 0x300 == 0 else {
            throw PICASyntheticDrawError.unsupportedConfiguration
        }
        let count = UInt64(self[0x228])
        let first = UInt64(self[0x22A])
        let base = UInt64(self[0x200] & 0x1FFF_FFFF) << 3
        let start = base + UInt64(self[0x203] & 0x0FFF_FFFF) + first * UInt64(stride)
        guard count <= 1_000_000 else { throw PICASyntheticDrawError.unsupportedConfiguration }
        if count == 0 { return [] }
        let length = Int((count - 1) * UInt64(stride) + 8)
        guard let bytes = read(start, length), bytes.count == length else {
            throw PICASyntheticDrawError.vertexDataUnavailable
        }
        func float(at offset: Int) -> Float {
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
            return Float(bitPattern: bits)
        }
        return (0..<Int(count)).map { i in
            PICAPosition(x: float(at: i * stride), y: float(at: i * stride + 4))
        }
    }
}
