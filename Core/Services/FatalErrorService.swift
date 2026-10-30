// input: ThrowFatalError from a title that hit an error it cannot recover from (err:f port).
// output: no reply, so emulation stops and shows the error info words (type, result code, PC) the title sent.
// pos: HLE of the 3DS fatal-error reporter; on hardware this is the "An error has occurred" screen.

final class FatalErrorService: HLEService {
    let name = "err:f"
    func handle(_ request: IPCRequest, kernel: Kernel) -> IPCReply? { nil }
}
