// input: any command to a service that has no HLE yet.
// output: a success reply with one result word, recorded in the kernel's stub list.
// pos: placeholder so title start-up can move past non-critical services; every use stays visible in `Kernel.stubbedCalls`.
import Foundation

final class StubService: HLEService {
    let name: String
    init(name: String) { self.name = name }

    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? {
        let count = min(request.normalCount + request.translateCount, 12)
        let words = request.words[1..<(1 + count)].map { String(format: "%08X", $0) }.joined(separator: " ")
        kernel.stubbedCalls.append(String(format: "%@ 0x%04X header=%08X [%@]", name, request.command, request.header, words))
        return IPCReply(command: request.command, [0])
    }
}
