// input: a PICA vertex shader program (code and swizzle words), its entry point and a draw's input and output mapping.
// output: MSL of a vertex function specialized to that program: registers as locals, swizzles and write masks resolved,
//         control flow structured (bool and integer uniforms stay runtime values); nil when its control flow does not
//         nest, and the interpreter in PICAMetalVertex runs it instead.
// pos: shader recompiler of PICAMetalBackend. The interpreter's per-instruction decode and dynamically indexed register
//      file made the vertex stage the largest share of GPU time; PICAMetalPipelines compiles this in the background.

import Foundation

enum PICAMetalVertexCompiler {
    // Everything the generated code depends on besides uniforms and per-draw bool/integer uniforms.
    struct Key: Hashable {
        let program: Int        // content hash of code and swizzles
        let entry: Int
        let inputs: [Int]       // input register of each attribute
        let outputs: [[Int]]    // per output register: the slot of each component (32 = unused)
    }

    static func key(_ m: PICAMesh, programHash: Int) -> Key {
        let r = m.registers
        let permutation = UInt64(r[PICAReg.inputPermutation]) | UInt64(r[PICAReg.inputPermutation + 1]) << 32
        let inputs = (0..<m.inputCount).map { Int(permutation >> (4 * UInt64($0)) & 15) }
        let mapped = (0..<16).filter { r[PICAReg.outputMask] >> UInt32($0) & 1 != 0 }
        var outputs = [[Int]](repeating: [32, 32, 32, 32], count: 16)
        for a in 0..<min(r.field(PICAReg.outputTotal, 0, 3), mapped.count, 8) {
            let packed = r[PICAReg.outputMap + a] & 0x1F1F_1F1F
            for c in 0..<4 { outputs[mapped[a]][c] = Int(packed >> (8 * UInt32(c)) & 31) }
        }
        return Key(program: programHash, entry: r.field(PICAReg.entryPoint, 0, 16), inputs: inputs, outputs: outputs)
    }

    static func source(_ key: Key, code: [UInt32], swizzles: [UInt32]) -> String? {
        let e = Emitter(code: code, swizzles: swizzles)
        guard e.region(key.entry, PICAShaderProgram.size) else { return nil }
        var main = key.inputs.enumerated().map { "    v[\($0.element)] = attributes[id * \(key.inputs.count) + \($0.offset)];" }
        func store(_ array: String, _ slots: String, below limit: Int) -> [String] {
            key.outputs.enumerated().flatMap { reg, components in
                components.enumerated().compactMap { c, slot in slot < limit ? "    \(slots)[\(slot)] = \(array)[\(reg)].\("xyzw".map(String.init)[c]);" : nil }
            }
        }
        main += ["    float4 o[16] = {};", "    program(v, s.uniforms, s.config.x, s.ints, o);",
                 "    float slots[32];", "    for (int i = 0; i < 32; i++) slots[i] = 1;"] + store("o", "slots", below: 32)
        main += ["    VertexOut out = clipOutput(slots, s);", "    if (s.config.w != 0) {", "    float4 q[16] = {};",
                 "    program(v, s.previous, s.config.x, s.ints, q);", "    float prev[4] = {1, 1, 1, 1};"] + store("q", "prev", below: 4)
        main += ["    out.prev = float4(prev[0], prev[1], prev[2], prev[3]);", "    }", "    return out;"]
        return PICAMetalVertex.common + header + """
        static void program(thread const float4 *v, constant float4 *u, uint bools, uint4 ints, thread float4 *o) {
            float4 \((0..<16).map { "r\($0) = 0" }.joined(separator: ", "));
            int3 a = 0;
            bool cx = false, cy = false;
        \(e.lines.joined(separator: "\n"))
        }
        vertex VertexOut shadeVertex(uint id [[vertex_id]], const device float4 *attributes [[buffer(0)]], constant Shader &s [[buffer(1)]]) {
            float4 v[16] = {};
        \(main.joined(separator: "\n"))
        }
        """
    }

    // TDS_SHADERDUMP=<directory> writes every program the renderer meets, for Tests/VertexCompiler.
    private static let dumpDirectory = ProcessInfo.processInfo.environment["TDS_SHADERDUMP"]
    static func dump(_ key: Key, code: [UInt32], swizzles: [UInt32], compiled: Bool) {
        guard let dumpDirectory else { return }
        let record: [String: Any] = ["entry": key.entry, "inputs": key.inputs, "outputs": key.outputs, "compiled": compiled,
                                     "code": code.map(Int.init), "swizzles": swizzles.map(Int.init)]
        let url = URL(fileURLWithPath: dumpDirectory).appendingPathComponent("\(UInt(bitPattern: key.hashValue)).json")
        try? JSONSerialization.data(withJSONObject: record).write(to: url)
    }

    // The interpreter's arithmetic, expression for expression, so both round the same way.
    private static let header = """
    static float4 rel(constant float4 *u, int base, int offset) {
        int i = (base + (offset < -128 || offset > 127 ? 0 : offset)) & 0x7F;
        return i >= 96 ? float4(1) : u[i];
    }
    static float4 dp3(float4 a, float4 b) { return float4(a.x * b.x + a.y * b.y + a.z * b.z); }
    static float4 dp4(float4 a, float4 b) { return float4(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w); }
    static float4 dph(float4 a, float4 b) { return float4(a.x * b.x + a.y * b.y + a.z * b.z + b.w); }

    """
}

private final class Emitter {
    let code: [UInt32], swizzles: [UInt32]
    private(set) var lines: [String] = []
    private var emitted = 0, depth = 0, steps: [String] = []   // steps: the innermost loops' aL increments

    init(code: [UInt32], swizzles: [UInt32]) { self.code = code; self.swizzles = swizzles }

    private func line(_ s: String) { lines.append(String(repeating: "    ", count: depth + 1) + s) }
    private func block(_ head: String, _ body: () -> Bool) -> Bool {
        line(head + " {"); depth += 1; defer { depth -= 1; line("}") }
        return body()
    }

    // Emits instructions start..<end; false when control flow leaves this range other than by END, BREAK or a call.
    func region(_ start: Int, _ end: Int) -> Bool {
        var pc = start
        while pc < end {
            emitted += 1
            guard emitted < 20_000, depth < 24 else { return false }
            let hex = pc < 4095 ? code[pc] : 0x22 << 26, op = hex >> 26
            let last = pc == end - 1
            let target = Int(hex >> 10 & 0xFFF), count = Int(hex & 0xFF)
            let flag = "((bools >> \(hex >> 22 & 0xF)) & 1u) != 0"
            switch op {
            case 0...0x1F, 0x2E, 0x2F: arithmetic(hex, op)
            case 0x30...: multiplyAdd(hex, op)
            case 0x22: line("return;"); return true                         // END
            case 0x20, 0x23:                                                   // BREAK, BREAKC
                guard let step = steps.last else { break }
                if op == 0x20 { line("a.z += \(step);"); line("break;"); return true }
                _ = block("if (\(test(hex)))") { line("a.z += \(step);"); line("break;"); return true }
            case 0x24, 0x25, 0x26:                                             // CALL, CALLC, CALLU
                guard !last else { break }                                     // a jump that ends a scope is never taken
                guard count > 0, target + count <= PICAShaderProgram.size else { return false }
                let condition = op == 0x24 ? "true" : op == 0x25 ? test(hex) : flag
                guard block("if (\(condition))", { region(target, target + count) }) else { return false }
            case 0x27, 0x28:                                                   // IFU, IFC
                guard !last, target > pc, target + count <= end else { return false }
                guard block("if (\(op == 0x27 ? flag : test(hex)))", { region(pc + 1, target) }),
                      block("else", { region(target, target + count) }) else { return false }
                pc = target + count; continue
            case 0x29:                                                         // LOOP
                guard !last, target > pc, target + 1 <= end else { return false }
                let n = lines.count, step = "step\(n)", nested = !steps.isEmpty
                let ok = block("") {
                    line("uint p\(n) = ints[\(hex >> 22 & 3)]; int saved\(n) = a.z, \(step) = int((p\(n) >> 16) & 0xFF);")
                    line("a.z = int((p\(n) >> 8) & 0xFF);")
                    steps.append(step); defer { steps.removeLast() }
                    let body = block("for (int i\(n) = int(p\(n) & 0xFF); i\(n) >= 0; i\(n)--)") {
                        defer { line("a.z += \(step);") }
                        return region(pc + 1, target + 1)
                    }
                    if nested { line("a.z = saved\(n);") }
                    return body
                }
                guard ok else { return false }
                pc = target + 1; continue
            case 0x2C, 0x2D:                                                   // JMPC, JMPU
                guard !last else { break }
                guard target > pc, target < end else { return false }
                let condition = op == 0x2C ? test(hex) : hex & 1 == 0 ? flag : "!(\(flag))"
                guard block("if (!(\(condition)))", { region(pc + 1, target) }) else { return false }
                pc = target; continue
            default: break                                                     // NOP, EMIT, SETEMIT
            }
            pc += 1
        }
        return true
    }

    private func test(_ hex: UInt32) -> String {
        let x = hex >> 25 & 1 != 0 ? "cx" : "!cx", y = hex >> 24 & 1 != 0 ? "cy" : "!cy"
        switch hex >> 22 & 3 { case 0: return "(\(x) || \(y))"; case 1: return "(\(x) && \(y))"; case 2: return x; default: return y }
    }

    private func source(_ reg: Int, _ index: Int) -> String {
        if reg < 0x10 { return "v[\(reg)]" }
        if reg < 0x20 { return "r\(reg - 0x10)" }
        return index == 0 ? "u[\(reg - 0x20)]" : "rel(u, \(reg - 0x20), a.\(["x", "y", "z"][index - 1]))"
    }

    private func swizzle(_ value: String, _ pattern: UInt32, _ shift: UInt32, negate: Bool) -> String {
        let components = [6, 4, 2, 0].map { "xyzw".map(String.init)[Int(pattern >> (shift + UInt32($0)) & 3)] }.joined()
        return "\(negate ? "-" : "")\(value)\(components == "xyzw" ? "" : "." + components)"
    }

    private func write(_ destination: Int, _ value: String, _ mask: UInt32) {
        guard mask != 0 else { return }
        let target = destination < 0x10 ? "o[\(destination)]" : "r\(destination - 0x10)"
        if mask == 15 { line("\(target) = \(value);"); return }
        let parts = (0..<4).filter { mask & (8 >> UInt32($0)) != 0 }.map { "\(target).\("xyzw".map(String.init)[$0]) = t.\("xyzw".map(String.init)[$0]);" }
        line("{ float4 t = \(value); \(parts.joined(separator: " ")) }")
    }

    private func arithmetic(_ hex: UInt32, _ op: UInt32) {
        let pattern = swizzles[Int(hex & 0x7F)], inverted = (0x18...0x1B).contains(op), index = Int(hex >> 19 & 3)
        let r1 = Int(inverted ? hex >> 14 & 0x1F : hex >> 12 & 0x7F), r2 = Int(inverted ? hex >> 7 & 0x7F : hex >> 7 & 0x1F)
        let a = "(" + swizzle(source(r1, inverted ? 0 : index), pattern, 5, negate: pattern & 0x10 != 0) + ")"
        let b = "(" + swizzle(source(r2, inverted ? index : 0), pattern, 14, negate: pattern & 0x2000 != 0) + ")"
        let destination = Int(hex >> 21 & 0x1F), mask = pattern & 0xF
        let value: String?
        switch op {
        case 0x00: value = "\(a) + \(b)"
        case 0x01: value = "dp3(\(a), \(b))"
        case 0x02: value = "dp4(\(a), \(b))"
        case 0x03, 0x18: value = "dph(\(a), \(b))"
        case 0x04, 0x19: value = "float4(1, \(a).y * \(b).y, \(a).z, \(b).w)"
        case 0x05: value = "float4(exp2(\(a).x))"
        case 0x06: value = "float4(log2(\(a).x))"
        case 0x07: value = "lit(\(a))"
        case 0x08: value = "multiply(\(a), \(b))"
        case 0x09, 0x1A: value = "select(float4(0), float4(1), \(a) >= \(b))"
        case 0x0A, 0x1B: value = "select(float4(0), float4(1), \(a) < \(b))"
        case 0x0B: value = "floor(\(a))"
        case 0x0C: value = "select(\(b), \(a), \(a) > \(b))"
        case 0x0D: value = "select(\(b), \(a), \(a) < \(b))"
        case 0x0E: value = "float4(1 / \(a).x)"
        case 0x0F: value = "float4(1 / sqrt(\(a).x))"
        case 0x13: value = a
        case 0x12:
            value = nil
            if mask & 8 != 0 { line("a.x = integer(\(a).x);") }
            if mask & 4 != 0 { line("a.y = integer(\(a).y);") }
        case 0x2E, 0x2F:
            value = nil
            func compare(_ op: UInt32, _ c: String) -> String {
                op > 5 ? "false" : "(\(a).\(c) \(["==", "!=", "<", "<=", ">", ">="][Int(op)]) \(b).\(c))"
            }
            line("cx = \(compare(hex >> 24 & 7, "x")); cy = \(compare(hex >> 21 & 7, "y"));")
        default: value = nil
        }
        if let value { write(destination, value, mask) }
    }

    private func multiplyAdd(_ hex: UInt32, _ op: UInt32) {
        let pattern = swizzles[Int(hex & 0x1F)], inverted = op < 0x38, index = Int(hex >> 22 & 3)
        let r1 = Int(hex >> 17 & 0x1F), r2 = Int(inverted ? hex >> 12 & 0x1F : hex >> 10 & 0x7F), r3 = Int(inverted ? hex >> 5 & 0x7F : hex >> 5 & 0x1F)
        let a = swizzle(source(r1, 0), pattern, 5, negate: pattern & 0x10 != 0)
        let b = swizzle(source(r2, inverted ? 0 : index), pattern, 14, negate: pattern & 0x2000 != 0)
        let c = swizzle(source(r3, inverted ? index : 0), pattern, 23, negate: pattern & 0x400000 != 0)
        write(Int(hex >> 24 & 0x1F), "multiply((\(a)), (\(b))) + (\(c))", pattern & 0xF)
    }
}
