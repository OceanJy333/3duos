// input: hand-built PICA command lists (a hand-assembled vertex shader, vertex buffers, a texture and render-state registers).
// output: assertions on pixels and depth written to the guest's tiled VRAM buffers, and rough draw timings.
// pos: end-to-end checks of PICARenderer: command parsing, vertex input, shader, clipping, rasterization, TEV, depth, blend.
import Foundation

let colorPhysical: UInt32 = 0x1800_0000, depthPhysical: UInt32 = 0x1810_0000
let listPhysical: UInt32 = 0x2001_0000, vertexPhysical: UInt32 = 0x2002_0000, texturePhysical: UInt32 = 0x2003_0000
private func virtual(_ physical: UInt32) -> UInt32 { GPUState.virtualAddress(physical) }

struct Vertex { var position: SIMD3<Float>; var color: [UInt8]; var uv: SIMD2<Float> }

final class Scene {
    let memory = PagedMemory()
    let renderer: PICARenderer
    var size = 64

    // A twin renders every list on the Metal backend at scale 1 so its guest buffers can be compared with this (software) one.
    var twin: Scene?
    private(set) var twinDifference = (bytes: 0, differing: 0, maximum: 0)

    init(metal: Bool = false) {
        memory.map(0x1F00_0000, size: 0x60_0000, permission: .readWrite)
        memory.map(Kernel.linearBase, size: 0x10_0000, permission: .readWrite)
        renderer = PICARenderer(memory: memory, metal: metal, internalScale: 1)
    }

    func write(_ physical: UInt32, _ bytes: [UInt8]) {
        _ = memory.copyIn(virtual(physical), from: bytes, count: bytes.count)
        renderer.guestWritten(physical, length: bytes.count)
        twin?.write(physical, bytes)
    }
    func submit(_ list: CommandList) {
        write(listPhysical, list.words.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> UInt32(8 * $0)) } })
        renderer.processCommandList(address: listPhysical, size: UInt32(list.words.count * 4))
        guard let twin else { return }
        twin.size = size
        twin.submit(list)
        twin.renderer.syncGuest()
        for base in [colorPhysical, depthPhysical] {
            guard let a = try? memory.readBytes(virtual(base), count: size * size * 4),
                  let b = try? twin.memory.readBytes(virtual(base), count: size * size * 4) else { continue }
            for i in a.indices where a[i] != b[i] {
                twinDifference.differing += 1; twinDifference.maximum = max(twinDifference.maximum, abs(Int(a[i]) - Int(b[i])))
            }
            twinDifference.bytes += a.count
        }
    }
    func run(_ configure: (inout CommandList) -> Void) { var list = CommandList(); configure(&list); submit(list) }

    func clear(color: UInt8 = 0, depth: UInt32 = 0x00FF_FFFF) {
        write(colorPhysical, [UInt8](repeating: color, count: size * size * 4))
        write(depthPhysical, (0..<size * size).flatMap { _ in (0..<4).map { UInt8(truncatingIfNeeded: depth >> UInt32(8 * $0)) } })
    }

    func rawColor(_ x: Int, _ y: Int) -> [UInt8] {
        let offset = tiledByteOffset(x, size - 1 - y, width: size, bytes: 4)
        return (try? memory.readBytes(virtual(colorPhysical) + UInt32(offset), count: 4)) ?? []
    }
    // Screen coordinates with y up; RGBA8 is stored as A, B, G, R.
    func pixel(_ x: Int, _ y: Int) -> [Int] { let b = rawColor(x, y); return [Int(b[3]), Int(b[2]), Int(b[1]), Int(b[0])] }
    func depthWord(_ x: Int, _ y: Int) -> UInt32 {
        let offset = tiledByteOffset(x, size - 1 - y, width: size, bytes: 4)
        return (try? memory.read32(virtual(depthPhysical) + UInt32(offset))) ?? 0
    }

    func upload(_ vertices: [Vertex], at physical: UInt32 = vertexPhysical) {
        var bytes: [UInt8] = []
        for v in vertices {
            for f in [v.position.x, v.position.y, v.position.z] { bytes += (0..<4).map { UInt8(truncatingIfNeeded: f.bitPattern >> UInt32(8 * $0)) } }
            bytes += v.color
            for f in [v.uv.x, v.uv.y] { bytes += (0..<4).map { UInt8(truncatingIfNeeded: f.bitPattern >> UInt32(8 * $0)) } }
        }
        write(physical, bytes)
    }
}

func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, z: Float, color: [UInt8]) -> [Vertex] {
    func v(_ x: Float, _ y: Float, _ u: Float, _ vv: Float) -> Vertex { Vertex(position: SIMD3(x / 32 - 1, y / 32 - 1, z), color: color, uv: SIMD2(u, vv)) }
    let (a, b, c, d) = (v(x0, y0, 0, 0), v(x1, y0, 1, 0), v(x1, y1, 1, 1), v(x0, y1, 0, 1))
    return [a, b, c, a, c, d]
}

func configure(_ scene: Scene, _ list: inout CommandList, width: Int = 64, height: Int = 64) {
    // Render target: D24S8 depth, RGBA8 color, width x height.
    list.write(PICAReg.depthFormat, 3); list.write(PICAReg.colorFormat, 0)
    list.write(PICAReg.depthAddress, depthPhysical >> 3); list.write(PICAReg.colorAddress, colorPhysical >> 3)
    list.write(PICAReg.framebufferSize, UInt32(width) | UInt32(height - 1) << 12)
    list.write(PICAReg.colorWriteMask, 0xF); list.write(PICAReg.depthWriteMask, 3)
    list.write(PICAReg.depthColorMask, 1 | 4 << 4 | 0xF << 8 | 1 << 12)      // depth test less, write all, depth write
    list.write(PICAReg.logicOp, 3)                                           // copy (blending is off)
    list.write(PICAReg.viewportHalfWidth, f24(Float(width) / 2)); list.write(PICAReg.viewportHalfHeight, f24(Float(height) / 2))
    list.write(PICAReg.depthScale, f24(1)); list.write(PICAReg.depthOffset, f24(1)); list.write(PICAReg.depthMap, 1)
    // Vertex shader: o0 = mvp * v0 (identity rows), o1 = v1 / 255, o2 = v2.
    list.write(PICAReg.programOffset, 0)
    list.upload(PICAReg.programData, [
        Asm.arith(0x02, dest: 0, src1: 0x20, src2: 0, desc: 1), Asm.arith(0x02, dest: 0, src1: 0x21, src2: 0, desc: 2),
        Asm.arith(0x02, dest: 0, src1: 0x22, src2: 0, desc: 3), Asm.arith(0x02, dest: 0, src1: 0x23, src2: 0, desc: 4),
        Asm.arith(0x08, dest: 1, src1: 0x24, src2: 1, desc: 0), Asm.arith(0x13, dest: 2, src1: 2, desc: 0), Asm.end,
    ])
    list.write(PICAReg.swizzleOffset, 0)
    list.upload(PICAReg.swizzleData, [Asm.descriptor(), Asm.descriptor(mask: 8), Asm.descriptor(mask: 4), Asm.descriptor(mask: 2), Asm.descriptor(mask: 1)])
    list.write(PICAReg.uniformIndex, 0)
    let scale = 1.0 / 255.0 as Float
    let rows: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1], [scale, scale, scale, scale]]
    list.upload(PICAReg.uniformData, rows.flatMap { packUniform($0[0], $0[1], $0[2], $0[3]) })
    list.write(PICAReg.entryPoint, 0); list.write(PICAReg.inputConfig, 2); list.write(PICAReg.inputPermutation, 0x210)
    list.write(PICAReg.outputMask, 7); list.write(PICAReg.outputTotal, 3)
    list.writeRange(PICAReg.outputMap, [0x0302_0100, 0x0B0A_0908, 0x1F1F_0D0C])
    // Vertex buffer: float3 position, ubyte4 color, float2 texcoord, interleaved with a 24-byte stride.
    list.write(PICAReg.attributeBase, vertexPhysical >> 3)
    list.write(PICAReg.attributeFormats, 0xB | 0xD << 4 | 0x7 << 8); list.write(PICAReg.attributeFormatsHigh, 2 << 28)
    list.writeRange(PICAReg.attributeLoaders, [0, 0x210, 24 << 16 | 3 << 28])
    // Texture 0: 8x8 RGBA8, nearest, modulated with the vertex color; remaining TEV stages pass the result through.
    list.write(PICAReg.textureConfig, 1)
    list.write(PICAReg.texture0 + 1, 8 << 16 | 8); list.write(PICAReg.texture0 + 4, texturePhysical >> 3); list.write(PICAReg.texture0Format, 0)
    for stage in PICAReg.tevStages.dropFirst() { list.write(stage, 0x0FFF_0FFF) }
    list.write(PICAReg.tevStages[0], 3 | 0 << 4 | 0 << 8 | 3 << 16 | 0 << 20); list.write(PICAReg.tevStages[0] + 2, 1 | 1 << 16)
}

private func expected(_ x: Int, _ y: Int, quad q: (Float, Float, Float, Float), color: [Int]) -> [Int] {
    let tx = Int((Float(x) + 0.5 - q.0) / (q.2 - q.0) * 8), ty = Int((Float(y) + 0.5 - q.1) / (q.3 - q.1) * 8)
    let texel = [tx * 32 + 16, (7 - ty) * 32 + 16, 100, 255]
    return zip(texel, color).map { $0 * $1 / 255 }
}

func rendererDrawChecks() {
    let scene = Scene()
    scene.twin = Scene(metal: true)
    rcheck(scene.twin!.renderer.usesMetal, "Metal backend available")
    // 8x8 texture: red encodes the column, green the stored row, blue is constant.
    var texture = [UInt8](repeating: 0, count: 256)
    for ty in 0..<8 { for tx in 0..<8 {
        let o = tiledByteOffset(tx, ty, width: 8, bytes: 4)
        texture[o] = 255; texture[o + 1] = 100; texture[o + 2] = UInt8(ty * 32 + 16); texture[o + 3] = UInt8(tx * 32 + 16)
    } }
    scene.write(texturePhysical, texture)
    scene.run { configure(scene, &$0) }

    let far = quad(8, 8, 40, 40, z: -0.5, color: [255, 255, 255, 255]), near = quad(24, 24, 56, 56, z: -0.8, color: [128, 255, 255, 255])
    let (farRect, nearRect): ((Float, Float, Float, Float), (Float, Float, Float, Float)) = ((8, 8, 40, 40), (24, 24, 56, 56))
    for order in 0..<2 {
        scene.clear()
        scene.upload(order == 0 ? far + near : near + far)
        scene.run { $0.write(PICAReg.vertexCount, 12); $0.write(PICAReg.vertexOffset, 0); $0.write(PICAReg.drawArrays, 1) }
        for (x, y) in [(12, 12), (36, 12), (12, 36), (20, 38)] {
            rcheck(scene.pixel(x, y) == expected(x, y, quad: farRect, color: [255, 255, 255, 255]), "far quad only at \(x),\(y) order \(order): \(scene.pixel(x, y))")
        }
        for (x, y) in [(50, 50), (30, 52), (52, 30)] {
            rcheck(scene.pixel(x, y) == expected(x, y, quad: nearRect, color: [128, 255, 255, 255]), "near quad only at \(x),\(y) order \(order)")
        }
        for (x, y) in [(30, 30), (26, 38), (38, 26)] {
            rcheck(scene.pixel(x, y) == expected(x, y, quad: nearRect, color: [128, 255, 255, 255]), "depth test keeps the near quad in the overlap, order \(order): \(scene.pixel(x, y))")
        }
        rcheck(scene.pixel(4, 4) == [0, 0, 0, 0] && scene.pixel(60, 8) == [0, 0, 0, 0], "outside the quads stays cleared")
        rclose(Int(scene.depthWord(30, 30) & 0xFFFFFF), Int(0.2 * 16777215), 200, "depth in the overlap is the near quad's")
        rclose(Int(scene.depthWord(12, 12) & 0xFFFFFF), Int(0.5 * 16777215), 200, "depth of the far quad")
    }
    print("PICA end-to-end draw (textured, TEV modulate, depth test, both draw orders): \(rendererAssertions) assertions so far")

    // Display transfer reads the tiled target: row r of the linear output is memory row r (screen y = 63 - r).
    scene.write(0x2004_0000, [UInt8](repeating: 0, count: 64 * 64 * 4))
    DisplayTransfer(words: [3, colorPhysical, 0x2004_0000, 64 | 64 << 16, 64 | 64 << 16, 0]).run(memory: scene.memory)
    let linear = (try? scene.memory.readBytes(virtual(0x2004_0000) + UInt32((33 * 64 + 30) * 4), count: 4)) ?? []
    rcheck(linear.count == 4 && [Int(linear[3]), Int(linear[2]), Int(linear[1]), Int(linear[0])] == scene.pixel(30, 30), "DisplayTransfer reads the same tiled layout")
    // Regression: the 2x1 downscale (top screen SSAA) averages the pixel pair instead of dropping one.
    scene.write(0x2006_0000, [255, 0, 0, 200, 255, 0, 100, 0] + [UInt8](repeating: 0, count: 8 * 8 * 4 - 8))
    DisplayTransfer(words: [3, 0x2006_0000, 0x2006_1000, 8 | 8 << 16, 8 | 8 << 16, 1 << 24]).run(memory: scene.memory)
    let averaged = (try? scene.memory.readBytes(virtual(0x2006_1000), count: 4)) ?? []
    rcheck(averaged == [255, 0, 50, 100], "display transfer 2x1 box filter: \(averaged)")

    let white = [UInt8](repeating: 255, count: 4)
    let strip = quad(8, 8, 40, 40, z: -0.5, color: white)
    scene.upload([strip[0], strip[1], strip[5], strip[2]])                       // bottom-left, bottom-right, top-left, top-right
    scene.write(vertexPhysical + 0x1000, [0, 1, 2, 3])
    scene.run { $0.write(PICAReg.tevStages[0], 0); $0.write(PICAReg.tevStages[0] + 2, 0); $0.write(PICAReg.textureConfig, 0) }
    for (name, topology, indices): (String, UInt32, [UInt8]) in [("strip", 1, [0, 1, 2, 3]), ("fan", 2, [0, 1, 3, 2])] {
        scene.clear()
        scene.write(vertexPhysical + 0x1000, indices)
        scene.run { $0.write(PICAReg.topology, topology << 8); $0.write(PICAReg.indexArray, 0x1000); $0.write(PICAReg.vertexCount, 4); $0.write(PICAReg.drawElements, 1) }
        rcheck(scene.pixel(14, 12) == [255, 255, 255, 255] && scene.pixel(34, 36) == [255, 255, 255, 255], "indexed \(name) covers both triangles")
        rcheck(scene.pixel(44, 12) == [0, 0, 0, 0] && scene.pixel(6, 36) == [0, 0, 0, 0], "indexed \(name) stays inside the quad")
    }

    scene.run { $0.write(PICAReg.topology, 0); $0.write(PICAReg.cullMode, 1) }                    // keep clockwise only
    scene.upload(quad(8, 8, 40, 40, z: -0.5, color: white))
    scene.clear(); scene.run { $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1) }
    rcheck(scene.pixel(20, 20) == [0, 0, 0, 0], "clockwise-only culling drops a counter-clockwise quad")
    scene.run { $0.write(PICAReg.cullMode, 2) }
    scene.run { $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1) }
    rcheck(scene.pixel(20, 20) == [255, 255, 255, 255], "counter-clockwise culling keeps it")

    scene.run { $0.write(PICAReg.cullMode, 0); $0.write(PICAReg.scissorMode, 3); $0.write(PICAReg.scissorMin, 0); $0.write(PICAReg.scissorMax, 19 | 63 << 16) }
    scene.clear(); scene.run { $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1) }
    rcheck(scene.pixel(18, 20) == [255, 255, 255, 255] && scene.pixel(21, 20) == [0, 0, 0, 0], "scissor include rectangle")
    scene.run { $0.write(PICAReg.scissorMode, 0) }

    // A fixed (default) attribute replaces the buffer's vertex colors.
    scene.upload(quad(8, 8, 40, 40, z: -0.5, color: white)); scene.clear()
    scene.run {
        $0.write(PICAReg.attributeFormatsHigh, 2 << 28 | 0x2 << 16); $0.write(PICAReg.defaultAttributeIndex, 1)
        $0.upload(PICAReg.defaultAttributeData, packUniform(0, 255, 0, 255))
        $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1); $0.write(PICAReg.attributeFormatsHigh, 2 << 28)
    }
    rcheck(scene.pixel(20, 20) == [0, 255, 0, 255], "default attribute feeds the shader: \(scene.pixel(20, 20))")

    // A command-buffer trigger continues in another buffer and abandons the rest of the current list.
    var subroutine = CommandList(); subroutine.write(PICAReg.vertexCount, 6); subroutine.write(PICAReg.drawArrays, 1)
    scene.write(0x2005_0000, subroutine.words.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> UInt32(8 * $0)) } })
    scene.clear()
    scene.run {
        $0.write(PICAReg.commandBufferSize, UInt32(subroutine.words.count * 4 / 8)); $0.write(PICAReg.commandBufferAddress, 0x2005_0000 >> 3)
        $0.write(PICAReg.commandBufferTrigger, 1); $0.write(PICAReg.vertexCount, 3)
    }
    rcheck(scene.pixel(20, 20) == [255, 255, 255, 255] && scene.renderer.registers[PICAReg.vertexCount] == 6, "command buffer trigger runs the second buffer and drops the rest")

    // Immediate mode: three vertices of three attributes each arrive as float24 words through the default-attribute registers.
    scene.clear()
    scene.run {
        $0.write(PICAReg.topology, 0); $0.write(0x242, 2); $0.write(PICAReg.defaultAttributeIndex, 0xF)
        for (x, y) in [(-0.75, -0.75), (0.25, -0.75), (-0.75, 0.25)] as [(Float, Float)] {
            $0.upload(PICAReg.defaultAttributeData, packUniform(x, y, -0.5, 1))
            $0.upload(PICAReg.defaultAttributeData, packUniform(255, 255, 255, 255))
            $0.upload(PICAReg.defaultAttributeData, packUniform(0, 0, 0, 0))
        }
    }
    rcheck(scene.pixel(12, 12) == [255, 255, 255, 255] && scene.pixel(36, 36) == [0, 0, 0, 0], "immediate-mode triangle")

    // Non-finite vertex data and texture coordinates must not crash the pipeline.
    var broken = quad(8, 8, 40, 40, z: -0.5, color: white)
    broken[0].position.x = .nan; broken[1].uv = SIMD2(.nan, .infinity); broken[4].position.y = 3e38
    scene.upload(broken)
    scene.run { $0.write(PICAReg.textureConfig, 1); $0.write(PICAReg.tevStages[0], 3 | 3 << 16); $0.write(PICAReg.tevStages[0] + 2, 1 | 1 << 16) }
    let before = scene.renderer.drawCount
    scene.run { $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1) }
    rcheck(scene.renderer.drawCount >= before, "NaN and huge vertex data survive")
    scene.run { $0.write(PICAReg.tevStages[0], 0); $0.write(PICAReg.tevStages[0] + 2, 0); $0.write(PICAReg.textureConfig, 0) }

    // Alpha blend (source alpha, one minus source alpha) of a half-transparent blue quad over opaque red.
    scene.clear()
    scene.upload(quad(8, 8, 40, 40, z: -0.5, color: [255, 0, 0, 255]))
    scene.run { $0.write(PICAReg.depthColorMask, 0xF << 8); $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1) }
    scene.upload(quad(16, 16, 48, 48, z: -0.5, color: [0, 0, 255, 128]))
    scene.run {
        $0.write(PICAReg.blendEnable, 0x100); $0.write(PICAReg.blendFunction, 6 << 16 | 7 << 20 | 6 << 24 | 7 << 28)
        $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1)
    }
    rcheck(scene.pixel(30, 30) == [127, 0, 128, 191], "alpha blend over opaque red: \(scene.pixel(30, 30))")
    rcheck(scene.pixel(12, 12) == [255, 0, 0, 255] && scene.pixel(44, 44) == [0, 0, 128, 64], "blend over the cleared background: \(scene.pixel(44, 44))")

    // Stencil: always pass, replace with 0x55 where drawn; depth bits stay intact.
    scene.clear(); scene.upload(quad(8, 8, 40, 40, z: -0.5, color: white))
    scene.run {
        $0.write(PICAReg.blendEnable, 0); $0.write(PICAReg.depthColorMask, 1 | 4 << 4 | 0xF << 8 | 1 << 12)
        $0.write(PICAReg.stencilTest, 1 | 1 << 4 | 0xFF << 8 | 0x55 << 16 | 0xFF << 24); $0.write(PICAReg.stencilOp, 2 << 8)
        $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1)
    }
    rcheck(scene.depthWord(20, 20) >> 24 == 0x55 && scene.depthWord(50, 50) >> 24 == 0, "stencil replace on pass")
    rclose(Int(scene.depthWord(20, 20) & 0xFFFFFF), Int(0.5 * 16777215), 200, "depth kept next to stencil")
    rendererLightingChecks(scene)
    print("PICA topologies, culling, scissor, blend, stencil: \(rendererAssertions) assertions total")
    let d = scene.twinDifference
    print(String(format: "Metal scale 1 vs software: %d of %d bytes differ (%.3f%%), max difference %d", d.differing, d.bytes, Double(d.differing) * 100 / Double(max(d.bytes, 1)), d.maximum))
    scene.twin = nil
    rendererPerformance(scene)
    let metal = Scene(metal: true)
    rendererPerformance(metal)
}

private func rendererPerformance(_ scene: Scene) {
    scene.run { configure(scene, &$0, width: 240, height: 400) }
    scene.run { $0.write(PICAReg.stencilTest, 0); $0.write(PICAReg.textureConfig, 1); $0.write(PICAReg.tevStages[0], 3 | 3 << 16); $0.write(PICAReg.tevStages[0] + 2, 1 | 1 << 16) }
    func v(_ x: Float, _ y: Float, _ u: Float, _ vv: Float) -> Vertex { Vertex(position: SIMD3(x, y, -0.5), color: [255, 255, 255, 255], uv: SIMD2(u, vv)) }
    let (a, b, c, d) = (v(-1, -1, 0, 0), v(1, -1, 1, 0), v(1, 1, 1, 1), v(-1, 1, 0, 1))
    scene.upload([a, b, c, a, c, d])
    scene.run { $0.write(PICAReg.depthColorMask, 0xF << 8) }
    var list = CommandList(); list.write(PICAReg.vertexCount, 6); list.write(PICAReg.drawArrays, 1)
    var start = Date()
    for _ in 0..<60 { scene.submit(list) }
    let quadTime = Date().timeIntervalSince(start) / 60
    rcheck(scene.renderer.lastDraw?.targetWidth == 240 && scene.renderer.lastDraw?.targetHeight == 400, "draw info exposes the render-target size")
    rcheck(scene.renderer.lastDraw?.colorPointer != nil && scene.renderer.lastDraw?.depthPointer != nil, "draw info exposes color and depth pointers")
    // 30,000 vertices (10,000 small triangles) through the interpreter.
    var many: [Vertex] = []
    for i in 0..<10_000 { let x = Float(i % 100) / 50 - 1, y = Float(i / 100) / 50 - 1; many += [v(x, y, 0, 0), v(x + 0.01, y, 1, 0), v(x, y + 0.01, 0, 1)] }
    scene.upload(many)
    var heavy = CommandList(); heavy.write(PICAReg.vertexCount, 30_000); heavy.write(PICAReg.drawArrays, 1)
    start = Date()
    for _ in 0..<10 { scene.submit(heavy) }
    let vertexTime = Date().timeIntervalSince(start) / 10
    print(String(format: "PICA performance: full 240x400 textured+TEV quad %.2f ms/draw; 30000 vertices + 10000 tiny triangles %.2f ms/draw", quadTime * 1000, vertexTime * 1000))
}

// Fragment lighting: one directional light straight along the normal; o3 is the normal quaternion, o4 the view vector.
private func rendererLightingChecks(_ scene: Scene) {
    // Regression: FCRAM physical addresses follow the kernel's linear heap (the game computes them with that base).
    rcheck(GPUState.virtualAddress(0x2000_1000) == Kernel.linearBase + 0x1000, "FCRAM maps to the linear heap base")
    scene.clear(); scene.upload(quad(8, 8, 40, 40, z: -0.5, color: [255, 255, 255, 255]))
    scene.run {
        $0.write(PICAReg.stencilTest, 0); $0.write(PICAReg.textureConfig, 0)
        $0.write(PICAReg.programOffset, 6)
        $0.upload(PICAReg.programData, [Asm.arith(0x13, dest: 3, src1: 0x25, desc: 0), Asm.arith(0x13, dest: 4, src1: 0x26, desc: 0), Asm.end])
        $0.write(PICAReg.uniformIndex, 5); $0.upload(PICAReg.uniformData, packUniform(0, 0, 0, 1) + packUniform(0, 0, 1, 0))
        $0.write(PICAReg.outputMask, 0x1F); $0.write(PICAReg.outputTotal, 5)
        $0.writeRange(PICAReg.outputMap + 3, [0x0706_0504, 0x1F14_1312])
        $0.write(0x8F, 1); $0.write(0x1C6, 0); $0.write(0x1C2, 0); $0.write(0x1D9, 0); $0.write(0x1C3, 0); $0.write(0x1C0, 0)
        $0.write(0x140, 255 << 20 | 255 << 10 | 255); $0.write(0x141, 0)
        $0.write(0x142, 200 << 20); $0.write(0x143, 50 << 10)
        $0.write(0x144, UInt32(0x3C00) << 16); $0.write(0x145, 0x3C00); $0.write(0x149, 1)     // directional, position (0, 1, 1) in f16
        $0.write(0x1C4, 0x017B_0100)                                                           // every table off
        $0.write(PICAReg.tevStages[0], 1 | 1 << 16); $0.write(PICAReg.tevStages[0] + 2, 0)
        $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1)
    }
    // Light vector (0, 1, 1) / sqrt(2) against normal (0, 0, 1): diffuse 200 * 0.707 + ambient 50 green.
    rclose(scene.pixel(20, 20)[0], 141, 1, "lit diffuse red: \(scene.pixel(20, 20))")
    rcheck(scene.pixel(20, 20)[1] == 50 && scene.pixel(20, 20)[2] == 0 && scene.pixel(20, 20)[3] == 255, "lit ambient green: \(scene.pixel(20, 20))")
    // Distribution 0 table (input N.V = 1 picks the last entry) scales the white specular to one half.
    scene.clear()
    scene.run {
        $0.write(0x1C5, 0); $0.upload(0x1C8, [UInt32](repeating: 2048, count: 256))
        $0.write(0x1D1, 2); $0.write(0x1C4, 0x017A_0100)
        $0.write(PICAReg.tevStages[0], 2 | 2 << 16); $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.drawArrays, 1)
    }
    rclose(scene.pixel(20, 20)[0], 127, 1, "specular through the D0 table: \(scene.pixel(20, 20))")
    scene.run { $0.write(0x8F, 0); $0.write(PICAReg.outputMask, 7); $0.write(PICAReg.outputTotal, 3); $0.write(PICAReg.programOffset, 6); $0.upload(PICAReg.programData, [Asm.end]) }
}
