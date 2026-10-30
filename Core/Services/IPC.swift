// input: the guest IPC command buffer (TLS + 0x80) of a SendSyncRequest.
// output: a decoded request for HLE services and the reply words written back.
// pos: boundary between the kernel's sessions and service implementations.

struct IPCRequest {
    let words: [UInt32]
    var header: UInt32 { words[0] }
    var command: UInt32 { header >> 16 }
    var normalCount: Int { Int((header >> 6) & 0x3F) }
    var translateCount: Int { Int(header & 0x3F) }
    // Normal parameter `index` (0-based, after the header).
    func param(_ index: Int) -> UInt32 { index + 1 < words.count ? words[index + 1] : 0 }
}

struct IPCReply {
    var command: UInt32
    var normal: [UInt32]
    var translate: [UInt32] = []
    var words: [UInt32] {
        [command << 16 | UInt32(normal.count) << 6 | UInt32(translate.count)] + normal + translate
    }
    init(command: UInt32, _ normal: [UInt32] = [], translate: [UInt32] = []) {
        self.command = command
        self.normal = normal
        self.translate = translate
    }
}

protocol HLEService: AnyObject {
    var name: String { get }
    // Returns nil for a command that is not implemented, which stops emulation so the gap stays visible.
    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply?
}
