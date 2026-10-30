// input: fs:USER commands and the game's own NCCH (RomFS, ExeFS) read from the cartridge file.
// output: file sessions whose Read, GetSize and Close commands serve cartridge data.
// pos: HLE of the 3DS file system service for the self-NCCH archive; save data and SD archives are not provided.
import Foundation

struct CartridgeSource {
    let url: URL
    let cartridge: Cartridge
}

final class FileSession: HLEService {
    let name = "file"
    private let url: URL
    private let offset: UInt64
    private let fixedSize: UInt64?   // nil: a writable host file whose size is the file's size

    init(url: URL, region: CartridgeRegion) {
        self.url = url
        offset = region.offset
        fixedSize = region.size
    }

    init(hostFile url: URL) {
        self.url = url
        offset = 0
        fixedSize = nil
    }

    private var size: UInt64 {
        fixedSize ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        let range = UInt64(request.param(1)) << 32 | UInt64(request.param(0))
        switch request.command {
        case 0x0802: // Read(offset, size, buffer)
            let count = UInt64(request.param(2))
            let available = range >= size ? 0 : min(count, size - range)
            if available > 0, let file = try? FileHandle(forReadingFrom: url) {
                defer { try? file.close() }
                try? file.seek(toOffset: offset + range)
                if let data = try? file.read(upToCount: Int(available)) {
                    try? kernel.memory.writeBytes(request.words[5], [UInt8](data))
                    return IPCReply(command: 0x0802, [0, UInt32(data.count)], translate: [request.words[4], request.words[5]])
                }
            }
            return IPCReply(command: 0x0802, [0, 0], translate: [request.words[4], request.words[5]])
        case 0x0803 where fixedSize == nil: // Write(offset, size, flush option, buffer)
            let count = Int(request.param(2))
            guard let bytes = try? kernel.memory.readBytes(request.words[6], count: count), let file = try? FileHandle(forWritingTo: url) else {
                return IPCReply(command: 0x0803, [0xC880_44CA, 0], translate: [request.words[5], request.words[6]])
            }
            defer { try? file.close() }
            try? file.seek(toOffset: range)
            try? file.write(contentsOf: Data(bytes))
            return IPCReply(command: 0x0803, [0, UInt32(count)], translate: [request.words[5], request.words[6]])
        case 0x0804: // GetSize
            return IPCReply(command: 0x0804, [0, UInt32(truncatingIfNeeded: size), UInt32(size >> 32)])
        case 0x0805 where fixedSize == nil: // SetSize
            try? FileHandle(forWritingTo: url).truncate(atOffset: range)
            return IPCReply(command: 0x0805, [0])
        case 0x0808, 0x0809, 0x080A: // Close, Flush, SetPriority
            return IPCReply(command: request.command, [0])
        case 0x080B: // GetPriority
            return IPCReply(command: 0x080B, [0, 0])
        case 0x080C: // OpenLinkFile: a second session on the same file
            return IPCReply(command: 0x080C, [0], translate: [0x10, kernel.create(KSession(service: self)) ?? 0])
        default:
            return nil
        }
    }
}

final class FSService: HLEService {
    let name = "fs:USER"
    private let source: CartridgeSource?
    private let saves: SaveArchives

    init(source: CartridgeSource?, saveRoot: URL) {
        self.source = source
        saves = SaveArchives(root: saveRoot)
    }

    // The RomFS file the game sees is IVFC level 3 only; the hash levels in front of it are not exposed.
    private static func level3(of region: CartridgeRegion, url: URL) -> CartridgeRegion? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        try? file.seek(toOffset: region.offset)
        guard let header = try? file.read(upToCount: 0x60), header.count == 0x60, header.prefix(4) == Data("IVFC".utf8) else { return nil }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(header[at + $1]) << ($1 * 8) } }
        func u32(_ at: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(header[at + $1]) << ($1 * 8) } }
        let block = UInt64(1) << u32(0x4C)
        let dataStart = (0x60 + u32(0x08) + block - 1) / block * block
        return CartridgeRegion(offset: region.offset + dataStart, size: u64(0x44))
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        switch request.command {
        case 0x0801, 0x0861, 0x0862, 0x080D: // Initialize, InitializeWithSdkVersion, SetPriority, ControlArchive (writes are already on disk)
            return IPCReply(command: request.command, [0])
        case 0x0863: // GetPriority
            return IPCReply(command: 0x0863, [0, 0])
        case 0x0803: // OpenFileDirectly(transaction, archiveId, archivePath type/size, filePath type/size, flags, attributes)
            let archiveID = request.param(1), pathSize = Int(request.words[11] >> 14)
            guard archiveID == 3, let source, request.param(4) == 2, pathSize >= 4,
                  let path = try? kernel.memory.readBytes(request.words[12], count: pathSize) else {
                return IPCReply(command: 0x0803, [0xC880_44CA], translate: [0, 0])
            }
            let type = path[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            var region: CartridgeRegion?
            switch type {
            case 0: region = source.cartridge.romfs.flatMap { Self.level3(of: $0, url: source.url) }
            case 2:
                let name = String(decoding: path[4..<min(12, path.count)].prefix { $0 != 0 }, as: UTF8.self)
                region = source.cartridge.exefs[name]
            default: break
            }
            guard let region, let handle = kernel.create(KSession(service: FileSession(url: source.url, region: region))) else {
                return IPCReply(command: 0x0803, [0xC880_44CA], translate: [0, 0])
            }
            kernel.note("OpenFileDirectly(type \(type)) size \(region.size)")
            return IPCReply(command: 0x0803, [0], translate: [0x10, handle])
        default:
            return saves.handle(request, kernel: kernel)
        }
    }
}
