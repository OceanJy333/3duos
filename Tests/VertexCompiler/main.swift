// Input: program dumps (TDS_SHADERDUMP from the app) in a directory, or the built-in hand-assembled programs.
// Output: per program, the largest difference between the interpreter and the recompiled function over random inputs,
//         uniforms and bool/integer uniforms, run side by side on the GPU; exit status 1 on any mismatch.
// Pos: differential check of PICAMetalVertexCompiler against the interpreter in PICAMetalVertex.
import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
var generator = SystemRandomNumberGenerator()
var failures = 0, checked = 0

for file in files {
    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(directory)/\(file)"))) as! [String: Any]
    let code = (record["code"] as! [Int]).map { UInt32($0) }, swizzles = (record["swizzles"] as! [Int]).map { UInt32($0) }
    let key = PICAMetalVertexCompiler.Key(program: 0, entry: record["entry"] as! Int, inputs: record["inputs"] as! [Int],
                                          outputs: record["outputs"] as! [[Int]])
    guard let compiled = PICAMetalVertexCompiler.source(key, code: code, swizzles: swizzles) else { print("\(file): not compiled (interpreter)"); continue }
    // The recompiled program next to the interpreter; its vertex function is renamed so both fit in one library.
    let body = String(compiled.dropFirst(PICAMetalVertex.common.count)).replacingOccurrences(of: "shadeVertex(", with: "shadeVertexCompiled(")
    let kernel = """
    kernel void check(device const float4 *inputs [[buffer(0)]], constant float4 *u [[buffer(1)]], device float4 *interpreted [[buffer(2)]],
                      device float4 *recompiled [[buffer(3)]], constant uint4 &config [[buffer(4)]], const device uint *code [[buffer(5)]],
                      uint id [[thread_position_in_grid]]) {
        float4 file[48];
        for (int i = 0; i < 48; i++) file[i] = i < 16 ? inputs[id * 16 + i] : 0;
        uint4 ints = uint4(config.y, config.z, config.w, config.y ^ config.z);
        run(file, code, code + 4096, u, config.x, ints, \(key.entry));
        float4 v[16], o[16] = {};
        for (int i = 0; i < 16; i++) { v[i] = inputs[id * 16 + i]; interpreted[id * 16 + i] = file[32 + i]; }
        program(v, u, config.x, ints, o);
        for (int i = 0; i < 16; i++) recompiled[id * 16 + i] = o[i];
    }
    """
    let options = MTLCompileOptions(); options.mathMode = .safe
    let library = try device.makeLibrary(source: PICAMetalVertex.source + body + kernel, options: options)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check")!)
    let n = 4096
    var worst: Float = 0, mismatches = 0
    for round in 0..<8 {
        let inputs = (0..<n * 16).map { _ in SIMD4<Float>((0..<4).map { _ in Float.random(in: -4...4, using: &generator) }) }
        let uniforms = (0..<96).map { _ in SIMD4<Float>((0..<4).map { _ in Float.random(in: -2...2, using: &generator) }) }
        // Integer uniforms: loop count, start and step bytes kept small so loops stay short.
        func int() -> UInt32 { UInt32.random(in: 0...7) | UInt32.random(in: 0...3) << 8 | UInt32.random(in: 0...2) << 16 }
        var config = SIMD4<UInt32>([0, 0xFFFF, UInt32.random(in: 0...0xFFFF), UInt32.random(in: 0...0xFFFF)][round % 4], int(), int(), int())
        let program = code + swizzles
        let buffers = [inputs.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! },
                       uniforms.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! },
                       device.makeBuffer(length: n * 16 * 16)!, device.makeBuffer(length: n * 16 * 16)!,
                       device.makeBuffer(bytes: &config, length: 16)!,
                       program.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }]
        let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        for (i, b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        let a = buffers[2].contents().bindMemory(to: Float.self, capacity: n * 64), b = buffers[3].contents().bindMemory(to: Float.self, capacity: n * 64)
        for i in 0..<n * 64 where !(a[i].isNaN && b[i].isNaN) {
            let d = abs(a[i] - b[i]) / max(1, abs(a[i]))
            if !(d <= 1e-6) { mismatches += 1 }
            if d.isFinite { worst = max(worst, d) } else if a[i] != b[i] { worst = .infinity }
        }
    }
    checked += 1
    print(String(format: "%@: %@ max relative difference %.2e, %d mismatching components", file, mismatches == 0 ? "OK" : "FAIL", worst, mismatches))
    if mismatches > 0 { failures += 1 }
}
print(failures == 0 && checked > 0 ? "PASS: \(checked) programs match the interpreter" : "FAIL: \(failures) of \(checked)")
exit(failures == 0 && checked > 0 ? 0 : 1)
