// input: cfg:u/i/s configuration-block and region queries.
// output: the user-config values of a Taiwan-region console with Traditional Chinese selected.
// pos: HLE of the system configuration service backed by a fixed block table.
import Foundation

final class CFGService: HLEService {
    static let regionTaiwan: UInt32 = 6
    static let languageTraditionalChinese: UInt8 = 11

    let name = "cfg:u"
    private let blocks: [UInt32: [UInt8]] = [
        0x0007_0001: [1],                                   // sound output: stereo
        0x000A_0000: Array("Ocean".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] },  // user name
        0x000A_0001: [1, 1],                                // birthday: month, day
        0x000A_0002: [CFGService.languageTraditionalChinese],
        // Stereo camera defaults (the values every console ships with); games build projection matrices from them.
        0x0005_0005: [Float(62), 289, 76.80000305175781, 46.08000183105469, 10, 5, 55.58000183105469, 21.56999969482422]
            .flatMap { f in (0..<4).map { UInt8(truncatingIfNeeded: f.bitPattern >> UInt32(8 * $0)) } },
    ]

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        switch request.command {
        case 0x0001: // GetConfigInfoBlk2(size, block id, buffer)
            let size = Int(request.param(0)), id = request.param(1)
            var bytes = blocks[id] ?? []
            bytes += [UInt8](repeating: 0, count: max(0, size - bytes.count))
            try? kernel.memory.writeBytes(request.words[4], Array(bytes.prefix(size)))
            if blocks[id] == nil { kernel.note(String(format: "cfg: unknown block %08X, zeros", id)) }
            return IPCReply(command: 0x0001, [0], translate: [request.words[3], request.words[4]])
        case 0x0002: // SecureInfoGetRegion
            return IPCReply(command: 0x0002, [0, Self.regionTaiwan])
        case 0x0003: // GetTransferableId: a fixed per-console value
            return IPCReply(command: 0x0003, [0, 0x3D05_0CEA, 0x0000_0333])
        case 0x0004: // IsCoppacsSupported
            return IPCReply(command: 0x0004, [0, 0])
        case 0x0005, 0x0006: // GetSystemModel (1: 3DS XL), GetModelNintendo2DS (1: not a 2DS)
            return IPCReply(command: request.command, [0, 1])
        default:
            return nil
        }
    }
}
