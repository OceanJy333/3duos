// input: A32 VFP11 system-register transfer, CPSR mode and VFP control state
// output: FPSCR/FPEXC register transfer or unsupported-instruction stop
// pos: ARM11 VFP control state; arithmetic and exception handling are separate

extension ARM11CPU {
    func vfpSystemTransfer(_ op: UInt32, at address: UInt32) -> ARMStop {
        let systemRegister = (op >> 16) & 15
        let read = op & (1 << 20) != 0
        let rd = Int((op >> 12) & 15)
        guard systemRegister == 1 || systemRegister == 8 else { return .undefined(address, op) }
        // FPSCR is inaccessible when VFP is disabled. Exceptional VFP state needs
        // exception processing, which this interpreter does not yet implement.
        if systemRegister == 1 && (fpexc & 0x4000_0000 == 0 || fpexc & 0x8000_0000 != 0) {
            return .undefined(address, op)
        }
        // FPEXC is accessible only in privileged mode, whether VFP is enabled or not.
        if systemRegister == 8 && cpsr & 31 == 0x10 { return .undefined(address, op) }
        if rd == 15 && (!read || systemRegister != 1) { return .undefined(address, op) }
        if read {
            let value = systemRegister == 1 ? fpscr : fpexc
            if rd == 15 { cpsr = (cpsr & 0x0FFF_FFFF) | (value & 0xF000_0000) }
            else { registers[rd] = value }
        } else if systemRegister == 1 { fpscr = registers[rd] }
        else { fpexc = registers[rd] }
        pc = address &+ 4
        return .running
    }
}
