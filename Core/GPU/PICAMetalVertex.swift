// input: a draw's raw vertex attributes, triangle-list indices, shader registers, program and uniforms.
// output: `PICAMesh` (what the renderer hands the Metal backend), its packed `Shader` block, and the MSL interpreter vertex
//         function that runs any PICA vertex shader per vertex; `common` (helpers, clip-space output) is shared with
//         PICAMetalVertexCompiler's specialized functions.
// pos: GPU twin of PICAShaderUnit + PICAVertexProcessor + PICAClipper; compiled with safe math so NaN/infinity rules hold.

struct PICAMesh {
    var attributes: [SIMD4<Float>]       // `inputCount` shader inputs per vertex, before the input permutation
    var indices: [UInt32]                // triangle list
    var registers: PICARegisters
    var program: PICAShaderProgram
    var uniforms: [SIMD4<Float>]
    var previous: [SIMD4<Float>]?        // last frame's uniforms of this mesh: shades the MetalFX motion source
    var inputCount: Int { registers.field(PICAReg.inputConfig, 0, 4) + 1 }
}

enum PICAMetalVertex {
    // The `Shader` block: uniforms, previous uniforms, then 9 slots of configuration (3,252 bytes, under setVertexBytes' 4 KiB).
    static func block(_ m: PICAMesh, viewport v: PICAViewport, width: Int, height: Int) -> [SIMD4<Float>] {
        let r = m.registers
        var out = m.uniforms + (m.previous ?? m.uniforms)
        func u(_ a: UInt32, _ b: UInt32 = 0, _ c: UInt32 = 0, _ d: UInt32 = 0) {
            out.append(SIMD4(Float(bitPattern: a), Float(bitPattern: b), Float(bitPattern: c), Float(bitPattern: d)))
        }
        let outputs = (0..<16).filter { r[PICAReg.outputMask] >> UInt32($0) & 1 != 0 }
        let count = min(r.field(PICAReg.outputTotal, 0, 3), outputs.count)
        let semantics = (0..<8).map { a in a < count ? r[PICAReg.outputMap + a] & 0x1F1F_1F1F : 0 }
        let registers = (0..<8).map { UInt32($0 < count ? outputs[$0] : 0) }
        u(r[PICAReg.intUniforms], r[PICAReg.intUniforms + 1], r[PICAReg.intUniforms + 2], r[PICAReg.intUniforms + 3])
        u(r[PICAReg.boolUniforms], UInt32(r.field(PICAReg.entryPoint, 0, 16)), UInt32(m.inputCount), m.previous == nil ? 0 : 1)
        u(r[PICAReg.inputPermutation], r[PICAReg.inputPermutation + 1], UInt32(count), v.clipEnabled ? 1 : 0)
        u(registers[0], registers[1], registers[2], registers[3]); u(registers[4], registers[5], registers[6], registers[7])
        u(semantics[0], semantics[1], semantics[2], semantics[3]); u(semantics[4], semantics[5], semantics[6], semantics[7])
        out.append(SIMD4(v.halfWidth, v.halfHeight, v.cornerX, v.cornerY))
        out.append(SIMD4(Float(width), Float(height), v.depthScale, v.depthOffset))
        out.append(v.clipPlane)
        return out
    }

    static let source = common + interpreter

    static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct Shader {
        float4 uniforms[96], previous[96];
        uint4 ints;
        uint4 config;        // bool uniforms, entry point, input count, has previous uniforms
        uint4 map;           // input permutation low, high, output count, user clip plane enabled
        uint4 outputs[2];    // output register of each mapped output
        uint4 semantics[2];  // its four 5-bit semantic slots, one per byte
        float4 viewport;     // half width, half height, corner x, corner y
        float4 target;       // width, height, depth scale, depth offset
        float4 clipPlane;
    };
    // Must match drawFragment's Varyings by name; clip distances exist only on the vertex side.
    struct VertexOut {
        float4 position [[position]];
        float clip [[clip_distance]] [8];
        float depth [[center_no_perspective]];
        float w;
        float4 color, tex01, tex2W, quat, view, prev;
    };

    static float4 multiply(float4 a, float4 b) {
        float4 p = a * b;
        // The hardware returns 0 for 0 * infinity instead of NaN.
        for (int i = 0; i < 4; i++) if (isnan(p[i]) && !isnan(a[i]) && !isnan(b[i])) p[i] = 0;
        return p;
    }
    static float4 swizzle(float4 v, uint p, uint s, bool negate) {
        float4 r = float4(v[(p >> (s + 6)) & 3], v[(p >> (s + 4)) & 3], v[(p >> (s + 2)) & 3], v[(p >> s) & 3]);
        return negate ? -r : r;
    }
    static int integer(float f) { return isnan(f) ? 0 : int(clamp(f, -1e9, 1e9)); }
    static bool compare(uint op, float a, float b) {
        switch (op) { case 0: return a == b; case 1: return a != b; case 2: return a < b; case 3: return a <= b;
                      case 4: return a > b; case 5: return a >= b; default: return false; }
    }
    static float4 lit(float4 a) {
        float power = a.z > 0 ? pow(max(a.y, 0.0), clamp(a.w, -128.0, 128.0)) : 0;
        return float4(1, max(a.x, 0.0), a.x > 0 ? power : 0, 1);
    }

    // Semantic slots: 0-3 position, 4-7 quaternion, 8-11 color, 12-15 texcoord0/1, 16 texcoord0 w, 18-20 view, 22-23 texcoord2.
    static VertexOut clipOutput(thread float *slots, constant Shader &s) {
        VertexOut o;
        float4 p = float4(slots[0], slots[1], slots[2], slots[3]);
        // PICA view volume -w <= x, y <= w, -w <= z <= 0, w >= 1e-5, user plane; the viewport is folded into the target's clip space.
        o.position = float4(((p.x + p.w) * s.viewport.x + s.viewport.z * p.w) * 2 / s.target.x - p.w,
                            p.w - ((p.y + p.w) * s.viewport.y + s.viewport.w * p.w) * 2 / s.target.y, p.z * s.target.z + s.target.w * p.w, p.w);
        o.clip[0] = p.x + p.w; o.clip[1] = p.w - p.x; o.clip[2] = p.y + p.w; o.clip[3] = p.w - p.y; o.clip[4] = p.w - 0.00001;
        o.clip[5] = s.map.w != 0 ? dot(p, s.clipPlane) : 1;
        // z is the scaled PICA depth (clamped by the depth clip mode, like the hardware), so -w <= z <= 0 is clipped here.
        o.clip[6] = -p.z; o.clip[7] = p.z + p.w;
        o.depth = p.z / p.w; o.w = p.w;
        // The hardware takes the absolute value and saturates vertex colors before interpolation.
        o.color = min(abs(float4(slots[8], slots[9], slots[10], slots[11])), 1.0);
        o.tex01 = float4(slots[12], slots[13], slots[14], slots[15]);
        o.tex2W = float4(slots[22], slots[23], slots[16], 0);
        o.quat = float4(slots[4], slots[5], slots[6], slots[7]);
        o.view = float4(slots[18], slots[19], slots[20], 0);
        o.prev = 0;
        return o;
    }
    """

    static let interpreter = """
    static float4 readRegister(thread float4 *file, constant float4 *u, int3 address, int reg, int index) {
        if (reg < 0x20) return file[reg];
        if (index == 0) return u[reg - 0x20];
        int offset = address[index - 1];
        int i = (reg - 0x20 + (offset < -128 || offset > 127 ? 0 : offset)) & 0x7F;
        return i >= 96 ? float4(1) : u[i];
    }
    static void writeRegister(thread float4 *file, int destination, float4 value, uint mask) {
        int slot = destination < 0x10 ? 32 + destination : destination;
        for (int i = 0; i < 4; i++) if (mask & (8u >> i)) file[slot][i] = value[i];
    }
    static bool test(uint hex, bool cx, bool cy) {
        bool x = (((hex >> 25) & 1) != 0) == cx, y = (((hex >> 24) & 1) != 0) == cy;
        switch ((hex >> 22) & 3) { case 0: return x || y; case 1: return x && y; case 2: return x; default: return y; }
    }
    // PICAShaderUnit.run, instruction for instruction.
    static void run(thread float4 *file, const device uint *code, const device uint *swizzles, constant float4 *u,
                    uint bools, uint4 ints, int entry) {
        int3 address = 0;
        bool cx = false, cy = false;
        int2 ifStack[16], callStack[16];
        int4 loopStack[16];
        int ifCount = 0, callCount = 0, loopCount = 0, pc = entry;
        for (int budget = 0; budget < 65536; budget++) {
            int old = pc;
            uint hex = pc < 4095 ? code[pc] : 0x22u << 26, op = hex >> 26;
            bool isBreak = false;
            if (op <= 0x1F || op == 0x2E || op == 0x2F) {
                uint pattern = swizzles[hex & 0x7F];
                bool inverted = op >= 0x18 && op <= 0x1B;
                int index = (hex >> 19) & 3;
                int r1 = inverted ? (hex >> 14) & 0x1F : (hex >> 12) & 0x7F, r2 = inverted ? (hex >> 7) & 0x7F : (hex >> 7) & 0x1F;
                float4 a = swizzle(readRegister(file, u, address, r1, inverted ? 0 : index), pattern, 5, pattern & 0x10);
                float4 b = swizzle(readRegister(file, u, address, r2, inverted ? index : 0), pattern, 14, pattern & 0x2000);
                int destination = (hex >> 21) & 0x1F;
                uint mask = pattern & 0xF;
                switch (op) {
                case 0x00: writeRegister(file, destination, a + b, mask); break;
                case 0x01: writeRegister(file, destination, float4(a.x * b.x + a.y * b.y + a.z * b.z), mask); break;
                case 0x02: writeRegister(file, destination, float4(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w), mask); break;
                case 0x03: case 0x18: writeRegister(file, destination, float4(a.x * b.x + a.y * b.y + a.z * b.z + b.w), mask); break;
                case 0x04: case 0x19: writeRegister(file, destination, float4(1, a.y * b.y, a.z, b.w), mask); break;
                case 0x05: writeRegister(file, destination, float4(exp2(a.x)), mask); break;
                case 0x06: writeRegister(file, destination, float4(log2(a.x)), mask); break;
                case 0x07: writeRegister(file, destination, lit(a), mask); break;
                case 0x08: writeRegister(file, destination, multiply(a, b), mask); break;
                case 0x09: case 0x1A: writeRegister(file, destination, select(float4(0), float4(1), a >= b), mask); break;
                case 0x0A: case 0x1B: writeRegister(file, destination, select(float4(0), float4(1), a < b), mask); break;
                case 0x0B: writeRegister(file, destination, floor(a), mask); break;
                case 0x0C: writeRegister(file, destination, select(b, a, a > b), mask); break;
                case 0x0D: writeRegister(file, destination, select(b, a, a < b), mask); break;
                case 0x0E: writeRegister(file, destination, float4(1 / a.x), mask); break;
                case 0x0F: writeRegister(file, destination, float4(1 / sqrt(a.x)), mask); break;
                case 0x12: if (mask & 8) address.x = integer(a.x); if (mask & 4) address.y = integer(a.y); break;
                case 0x13: writeRegister(file, destination, a, mask); break;
                case 0x2E: case 0x2F: cx = compare((hex >> 24) & 7, a.x, b.x); cy = compare((hex >> 21) & 7, a.y, b.y); break;
                default: break;
                }
            } else if (op >= 0x30) {
                uint pattern = swizzles[hex & 0x1F];
                bool inverted = op < 0x38;
                int index = (hex >> 22) & 3;
                int r1 = (hex >> 17) & 0x1F, r2 = inverted ? (hex >> 12) & 0x1F : (hex >> 10) & 0x7F, r3 = inverted ? (hex >> 5) & 0x7F : (hex >> 5) & 0x1F;
                float4 a = swizzle(readRegister(file, u, address, r1, 0), pattern, 5, pattern & 0x10);
                float4 b = swizzle(readRegister(file, u, address, r2, inverted ? 0 : index), pattern, 14, pattern & 0x2000);
                float4 c = swizzle(readRegister(file, u, address, r3, inverted ? index : 0), pattern, 23, pattern & 0x400000);
                writeRegister(file, (hex >> 24) & 0x1F, multiply(a, b) + c, pattern & 0xF);
            } else {
                int target = (hex >> 10) & 0xFFF;
                bool flag = ((bools >> ((hex >> 22) & 0xF)) & 1) != 0;
                switch (op) {
                case 0x22: return;
                case 0x20: isBreak = true; break;
                case 0x23: isBreak = test(hex, cx, cy); break;
                case 0x24: case 0x25: case 0x26:
                    if (op == 0x24 || (op == 0x25 ? test(hex, cx, cy) : flag)) {
                        if (callCount < 16) callStack[callCount++] = int2(target + int(hex & 0xFF), pc + 1);
                        pc = target - 1;
                    }
                    break;
                case 0x27: case 0x28:
                    if (op == 0x28 ? test(hex, cx, cy) : flag) { if (ifCount < 16) ifStack[ifCount++] = int2(target, target + int(hex & 0xFF)); }
                    else pc = target - 1;
                    break;
                case 0x29: {
                    uint p = ints[(hex >> 22) & 3];
                    if (loopCount < 16) loopStack[loopCount++] = int4(pc + 1, target + 1, int(p & 0xFF) | int((p >> 16) & 0xFF) << 8, address.z);
                    address.z = int((p >> 8) & 0xFF);
                    break;
                }
                case 0x2C: if (test(hex, cx, cy)) pc = target - 1; break;
                case 0x2D: if (flag == ((hex & 1) == 0)) pc = target - 1; break;
                default: break;
                }
            }
            pc += 1;
            // Scopes close in the order CALL, IF, LOOP; a jump at the end of a scope is never taken.
            int next = old + 1;
            for (int i = 0; i < 4; i++) {
                if (callCount == 0 || callStack[callCount - 1].x != next) break;
                if (i < 3) { pc = callStack[callCount - 1].y; next = pc; }
                callCount--;
            }
            if (ifCount > 0 && ifStack[ifCount - 1].x == old + 1) pc = ifStack[--ifCount].y;
            if (loopCount > 0 && (loopStack[loopCount - 1].y == old + 1 || isBreak)) {
                int4 e = loopStack[loopCount - 1];
                address.z += e.z >> 8;
                if (!isBreak && (e.z & 0xFF) != 0) { e.z -= 1; loopStack[loopCount - 1] = e; pc = e.x; }
                else { pc = e.y; if (loopCount > 1) address.z = e.w; loopCount--; }
            }
        }
    }

    static void mapOutputs(thread float4 *file, constant Shader &s, thread float *slots) {
        for (uint a = 0; a < s.map.z; a++) {
            float4 v = file[32 + s.outputs[a / 4][a % 4]];
            uint packed = s.semantics[a / 4][a % 4];
            for (int c = 0; c < 4; c++) slots[(packed >> (8 * c)) & 31] = v[c];
        }
    }

    vertex VertexOut shadeVertex(uint id [[vertex_id]], const device float4 *attributes [[buffer(0)]], constant Shader &s [[buffer(1)]],
                                 const device uint *program [[buffer(2)]]) {
        float4 file[48];
        for (int i = 0; i < 48; i++) file[i] = 0;
        uint count = s.config.z;
        for (uint a = 0; a < count; a++) file[((a < 8 ? s.map.x >> (4 * a) : s.map.y >> (4 * (a - 8)))) & 15] = attributes[id * count + a];
        float slots[32];
        for (int i = 0; i < 32; i++) slots[i] = 1;   // outputs the map leaves unset read as 1
        run(file, program, program + 4096, s.uniforms, s.config.x, s.ints, int(s.config.y));
        mapOutputs(file, s, slots);
        VertexOut o = clipOutput(slots, s);
        if (s.config.w != 0) {
            run(file, program, program + 4096, s.previous, s.config.x, s.ints, int(s.config.y));
            for (int i = 0; i < 4; i++) slots[i] = 1;
            mapOutputs(file, s, slots);
            o.prev = float4(slots[0], slots[1], slots[2], slots[3]);
        }
        return o;
    }
    """
}
