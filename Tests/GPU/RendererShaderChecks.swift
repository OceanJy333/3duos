// input: hand-assembled PICA vertex shaders and raw texture/uniform words.
// output: assertions on interpreter results, uniform upload packing and texture format decoding.
// pos: unit-style checks for the shader interpreter and texture decoder in Core/GPU.
import Foundation

private func run(_ code: [UInt32], _ descriptors: [UInt32], uniforms: [SIMD4<Float>] = [], bools: UInt32 = 0,
                 ints: SIMD4<UInt32> = .zero, inputs: [SIMD4<Float>] = []) -> PICAShaderUnit {
    let program = PICAShaderProgram()
    code.forEach(program.appendCode)
    descriptors.forEach(program.appendSwizzle)
    program.setUniformIndex(0)
    for u in uniforms { packUniform(u.x, u.y, u.z, u.w).forEach(program.appendUniform) }
    let unit = PICAShaderUnit()
    for (i, v) in inputs.enumerated() { unit.file[i] = v }
    program.code.withUnsafeBufferPointer { c in program.swizzles.withUnsafeBufferPointer { s in program.uniforms.withUnsafeBufferPointer { u in
        unit.run(code: c.baseAddress!, swizzles: s.baseAddress!, uniforms: u.baseAddress!, bools: bools, ints: ints, entry: 0)
    }}}
    return unit
}

private func output(_ unit: PICAShaderUnit, _ index: Int) -> [Float] { (0..<4).map { unit.file[32 + index][$0] } }

func rendererShaderChecks() {
    rcheck(PICAMath.float24(f24(1)) == 1 && PICAMath.float24(f24(-2.5)) == -2.5 && PICAMath.float24(f24(0.15625)) == 0.15625, "float24 decode")
    let program = PICAShaderProgram()
    program.setUniformIndex(3)
    packUniform(1, -2, 3.5, 4).forEach(program.appendUniform)
    rcheck(program.uniforms[3] == SIMD4(1, -2, 3.5, 4) && program.uniforms[2] == .zero, "float24 uniform upload packing and index")
    program.setUniformIndex(0x8000_0000 | 5)
    [4, 3, 2, 1].map { Float($0).bitPattern }.forEach(program.appendUniform)
    rcheck(program.uniforms[5] == SIMD4(1, 2, 3, 4), "float32 uniform upload is w-first")

    let identity = Asm.descriptor(), maskX = Asm.descriptor(mask: 8), negWZYX = Asm.descriptor(negate1: true, src1: [3, 2, 1, 0])
    let uniformSet = (0..<8).map { SIMD4<Float>(repeating: Float(2 * ($0 + 1))) }
    let v0 = SIMD4<Float>(1, 2, 3, 4), v1 = SIMD4<Float>(5, 6, 7, 8)
    let arithmetic = run([
        Asm.arith(0x00, dest: 0x10, src1: 0, src2: 1, desc: 0),                  // add r0, v0, v1
        Asm.arith(0x08, dest: 0x11, src1: 0x20, src2: 0x10, desc: 0),            // mul r1, c0, r0
        Asm.arith(0x01, dest: 0x12, src1: 0, src2: 1, desc: 1),                  // dp3 r2.x, v0, v1
        Asm.arith(0x13, dest: 0, src1: 0x11, desc: 0),                           // mov o0, r1
        Asm.arith(0x13, dest: 1, src1: 0x12, desc: 0),                           // mov o1, r2
        Asm.arith(0x13, dest: 2, src1: 0, desc: 2),                              // mov o2, -v0.wzyx
        Asm.mad(dest: 3, src1: 0, src2: 1, src3: 0, desc: 0),                    // mad o3, v0, v1, v0
        Asm.arith(0x12, dest: 0, src1: 2, desc: 1),                              // mova a0.x, v2.x
        Asm.arith(0x13, dest: 4, src1: 0x21, desc: 0, index: 1),                 // mov o4, c1[a0.x]
        Asm.arith(0x0E, dest: 5, src1: 1, desc: 0),                              // rcp o5, v1.x
        Asm.arith(0x0B, dest: 6, src1: 3, desc: 0),                              // flr o6, v3
        Asm.arith(0x0A, dest: 7, src1: 0, src2: 1, desc: 0),                     // slt o7, v0, v1
        Asm.end,
    ], [identity, maskX, negWZYX], uniforms: uniformSet, inputs: [v0, v1, SIMD4(2.7, 0, 0, 0), SIMD4(1.5, -1.5, 2, -0.2)])
    rcheck(output(arithmetic, 0) == [12, 16, 20, 24], "add, mul with uniform")
    rcheck(output(arithmetic, 1)[0] == 38, "dp3 with x write mask")
    rcheck(output(arithmetic, 1)[1] == 0, "write mask leaves other components")
    rcheck(output(arithmetic, 2) == [-4, -3, -2, -1], "swizzle wzyx with negate")
    rcheck(output(arithmetic, 3) == [6, 14, 24, 36], "mad")
    rcheck(output(arithmetic, 4) == [8, 8, 8, 8], "mova and relative uniform addressing (c1 + a0.x = c3)")
    rcheck(output(arithmetic, 5)[0] == 0.2, "rcp")
    rcheck(output(arithmetic, 6) == [1, -2, 2, -1], "flr")
    rcheck(output(arithmetic, 7) == [1, 1, 1, 1], "slt")

    // loop i0 runs (count + 1) times; aL starts at y and grows by z each pass.
    let loop = run([
        Asm.arith(0x13, dest: 0x10, src1: 0x28, desc: 0),                        // mov r0, c8 (zero)
        Asm.flow(0x29, target: 3, selector: 0),                                  // loop i0 .. instruction 3
        Asm.arith(0x00, dest: 0x10, src1: 0x21, src2: 0x10, desc: 0),            // add r0, c1, r0
        Asm.arith(0x00, dest: 0x11, src1: 0x20, src2: 0x11, desc: 0, index: 3),  // add r1, c0[aL], r1
        Asm.arith(0x13, dest: 0, src1: 0x10, desc: 0),
        Asm.arith(0x13, dest: 1, src1: 0x11, desc: 0),
        Asm.end,
    ], [identity], uniforms: uniformSet, ints: SIMD4(3 | 0 << 8 | 1 << 16, 0, 0, 0))
    rcheck(output(loop, 0) == [16, 16, 16, 16], "loop runs count + 1 times")
    rcheck(output(loop, 1) == [20, 20, 20, 20], "loop counter register aL indexes uniforms (2 + 4 + 6 + 8)")

    let branch: (UInt32) -> PICAShaderUnit = { bools in
        run([
            Asm.flow(0x27, target: 3, count: 1, selector: 0),                    // ifu b0: then 1-2, else 3
            Asm.arith(0x13, dest: 0x10, src1: 0x21, desc: 0),
            Asm.arith(0x13, dest: 0x11, src1: 0x21, desc: 0),
            Asm.arith(0x13, dest: 0x10, src1: 0x22, desc: 0),
            Asm.arith(0x13, dest: 0, src1: 0x10, desc: 0),
            Asm.end,
        ], [identity], uniforms: uniformSet, bools: bools)
    }
    rcheck(output(branch(1), 0)[0] == 4 && output(branch(0), 0)[0] == 6, "ifu selects then/else by bool uniform")

    let call = run([
        Asm.flow(0x24, target: 6, count: 1),                                     // call 6
        Asm.cmp(2, 5, src1: 0x20, src2: 0x10, desc: 0),                          // cmp x: c0.x < r0.x, y: c0.y >= r0.y
        Asm.flow(0x28, target: 4, count: 1, selector: 2 | 1 << 3),               // ifc justX refx=1: then 3, else 4
        Asm.arith(0x13, dest: 0, src1: 0x22, desc: 0),
        Asm.arith(0x13, dest: 0, src1: 0x23, desc: 0),
        Asm.end,
        Asm.arith(0x13, dest: 0x10, src1: 0x21, desc: 0),                        // subroutine: mov r0, c1
    ], [identity], uniforms: uniformSet)
    rcheck(output(call, 0)[0] == 6, "call/return, cmp and ifc")

    let jump = { (bools: UInt32) in run([
        Asm.flow(0x2D, target: 2, selector: 1),                                  // jmpu b1 -> 2
        Asm.arith(0x13, dest: 0, src1: 0x21, desc: 0),
        Asm.arith(0x13, dest: 1, src1: 0x22, desc: 0),
        Asm.end,
    ], [identity], uniforms: uniformSet, bools: bools) }
    rcheck(output(jump(2), 0)[0] == 0 && output(jump(2), 1)[0] == 6, "jmpu taken skips an instruction")
    rcheck(output(jump(0), 0)[0] == 4, "jmpu not taken runs the next instruction")
    let inf = run([Asm.arith(0x08, dest: 0, src1: 0, src2: 1, desc: 0), Asm.end], [identity], inputs: [SIMD4(0, 1, 2, 3), SIMD4(.infinity, 1, 1, 1)])
    rcheck(output(inf, 0)[0] == 0, "0 * infinity is 0 on PICA")
    print("PICA shader interpreter: \(rendererAssertions) assertions so far")

    func etc(_ low: UInt32, _ high: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: low >> UInt32(8 * $0)) } + (0..<4).map { UInt8(truncatingIfNeeded: high >> UInt32(8 * $0)) } }
    // Separate-color ETC1 block: base colors 0x8, 0x4, 0xC, table 0 (modifier 2, 8), all pixel indices 0 -> base + 2.
    let block = etc(0, 0x8 << 28 | 0x4 << 24 | 0xC << 20 | 0x8 << 16 | 0x4 << 12 | 0xC << 8)
    var tile = [UInt8](); for _ in 0..<4 { tile += block }
    var pixels = [UInt32](repeating: 0, count: 64)
    PICATextureFormat.decode(tile, width: 8, height: 8, format: 12, into: &pixels)
    rcheck(pixels[56] == PICATextureFormat.pack(0x88 + 2, 0xCC + 2, 0x44 + 2, 255), "ETC1 separate-mode block")
    rcheck(pixels[63] == PICATextureFormat.pack(0x44 + 2, 0x88 + 2, 0xCC + 2, 255), "ETC1 second sub-block color")
    var rgb565 = [UInt8](repeating: 0, count: 128)
    rgb565[2 * PICAMath.morton(3, 5)] = 0xE0; rgb565[2 * PICAMath.morton(3, 5) + 1] = 0xF8   // 0xF8E0: r=31, g=7, b=0
    PICATextureFormat.decode(rgb565, width: 8, height: 8, format: 3, into: &pixels)
    rcheck(pixels[(7 - 5) * 8 + 3] == PICATextureFormat.pack(255, PICATextureFormat.expand6(7), 0, 255), "RGB565 texel position and v flip")
    var a4 = [UInt8](repeating: 0, count: 32)
    a4[PICAMath.morton(1, 0) / 2] = 0xA0                                   // texel (1,0) is the high nibble of byte 0
    PICATextureFormat.decode(a4, width: 8, height: 8, format: 11, into: &pixels)
    rcheck(pixels[7 * 8 + 1] == PICATextureFormat.pack(0, 0, 0, 0xAA) && pixels[7 * 8] == 0, "A4 nibble order")
    print("PICA texture decode: \(rendererAssertions) assertions so far")
}
