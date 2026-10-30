// input: fs:USER archive commands (OpenArchive, OpenFile, CreateFile, CreateDirectory, Delete*, CloseArchive) and guest path strings.
// output: files and directories under one host folder per title, and write-capable file sessions.
// pos: save-data side of the file system service; every opened archive is a subfolder of the title's save root.
import Foundation

final class SaveArchives {
    private let root: URL
    private var archives: [UInt64: URL] = [:]
    private var nextHandle: UInt64 = 1
    static let notFound: UInt32 = 0xC880_4478

    init(root: URL) { self.root = root }

    private func hostURL(archive: URL, pathType: UInt32, bytes: [UInt8]) -> URL {
        var text: String
        switch pathType {
        case 4: // UTF-16LE
            text = String(decoding: stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }, as: UTF16.self)
        default:
            text = String(decoding: bytes, as: UTF8.self)
        }
        text = text.replacingOccurrences(of: "\0", with: "")
        let parts = text.split(separator: "/").filter { $0 != ".." && $0 != "." }
        return parts.reduce(archive) { $0.appendingPathComponent(String($1)) }
    }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        let ok = { IPCReply(command: request.command, [0]) }
        let failed = { IPCReply(command: request.command, [0xC880_44CA]) }
        switch request.command {
        case 0x080C: // OpenArchive(archive id, path type, path size, path)
            let folder = root.appendingPathComponent(String(format: "archive-%X", request.param(0)))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let handle = nextHandle
            nextHandle += 1
            archives[handle] = folder
            return IPCReply(command: 0x080C, [0, UInt32(truncatingIfNeeded: handle), UInt32(handle >> 32)])
        case 0x080E: // CloseArchive
            archives[UInt64(request.param(1)) << 32 | UInt64(request.param(0))] = nil
            return ok()
        case 0x0802: // OpenFile(transaction, archive, path type, path size, flags, attributes, path)
            guard let url = location(request, kernel: kernel, typeIndex: 4, sizeIndex: 5, pointerIndex: 9),
                  FileManager.default.fileExists(atPath: url.path) || request.words[6] & 4 != 0 else { return IPCReply(command: 0x0802, [Self.notFound], translate: [0, 0]) }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let handle = kernel.create(KSession(service: FileSession(hostFile: url))) else { return failed() }
            return IPCReply(command: 0x0802, [0], translate: [0x10, handle])
        case 0x0808: // CreateFile(transaction, archive, path type, path size, attributes, size, path)
            guard let url = location(request, kernel: kernel, typeIndex: 4, sizeIndex: 5, pointerIndex: 10) else { return failed() }
            let size = Int(request.words[7])
            return FileManager.default.createFile(atPath: url.path, contents: Data(count: size)) ? ok() : failed()
        case 0x0809: // CreateDirectory(transaction, archive, path type, path size, attributes, path)
            guard let url = location(request, kernel: kernel, typeIndex: 4, sizeIndex: 5, pointerIndex: 8) else { return failed() }
            return (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ? ok() : failed()
        case 0x0804, 0x0806, 0x0807: // DeleteFile, DeleteDirectory, DeleteDirectoryRecursively
            guard let url = location(request, kernel: kernel, typeIndex: 4, sizeIndex: 5, pointerIndex: 7) else { return failed() }
            return (try? FileManager.default.removeItem(at: url)) != nil ? ok() : failed()
        default:
            return nil
        }
    }

    private func location(_ request: IPCRequest, kernel: Kernel, typeIndex: Int, sizeIndex: Int, pointerIndex: Int) -> URL? {
        let id = UInt64(request.words[3]) << 32 | UInt64(request.words[2])
        guard let archive = archives[id], let bytes = try? kernel.memory.readBytes(request.words[pointerIndex], count: Int(request.words[sizeIndex])) else { return nil }
        let url = hostURL(archive: archive, pathType: request.words[typeIndex], bytes: bytes)
        kernel.note("save path \(url.path.replacingOccurrences(of: root.path, with: ""))")
        return url
    }
}
