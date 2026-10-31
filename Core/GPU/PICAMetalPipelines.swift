// input: pipeline keys (blend and attachment state), each draw's `Draw` uniform block and its vertex program's key.
// output: the render pipeline for a draw: fragment stage specialized to its TEV/texture/lighting configuration and vertex
//         stage recompiled from its PICA program once both are compiled; the uber shader and interpreter until then.
// pos: pipeline cache of PICAMetalBackend. Specialization folds the per-fragment switches and loops of the uber shader
//      away (the fragment stage was ~95% of GPU time); compiling in the background keeps new configurations from stalling.
import Metal

final class PICAMetalPipelines {
    private struct Specialized: Hashable {
        let key: PICAMetalState.PipelineKey; let config: [SIMD4<UInt32>]; var vertex: PICAMetalVertexCompiler.Key?
    }

    private let device: MTLDevice, library: MTLLibrary, vertexFunction: MTLFunction
    private var uber: [PICAMetalState.PipelineKey: MTLRenderPipelineState] = [:]
    private let lock = NSLock()   // `ready` is filled on Metal's compiler threads
    private var ready: [Specialized: MTLRenderPipelineState] = [:], requested: Set<Specialized> = []
    private var vertexFunctions: [PICAMetalVertexCompiler.Key: MTLFunction] = [:], vertexRequested: Set<PICAMetalVertexCompiler.Key> = []

    init(device: MTLDevice, library: MTLLibrary, vertexFunction: MTLFunction) {
        self.device = device; self.library = library; self.vertexFunction = vertexFunction
    }

    // `vertex` names the draw's program; `source` generates its MSL the first time it is seen (nil keeps the interpreter).
    func pipeline(_ key: PICAMetalState.PipelineKey, uniforms: [SIMD4<UInt32>], vertex: PICAMetalVertexCompiler.Key,
                  source: () -> String?) -> MTLRenderPipelineState {
        var config = PICAMetalShaders.configSlots.map { uniforms[$0] }
        config[36].w = 0   // the alpha reference stays a uniform
        let interpreted = Specialized(key: key, config: config)
        var recompiled = interpreted
        recompiled.vertex = vertex
        lock.lock()
        let function = vertexFunctions[vertex], newProgram = function == nil && vertexRequested.insert(vertex).inserted
        let best = function == nil ? nil : ready[recompiled], fallback = ready[interpreted]
        let compileRecompiled = function != nil && best == nil && requested.insert(recompiled).inserted
        let compileInterpreted = fallback == nil && requested.insert(interpreted).inserted
        lock.unlock()
        if newProgram, let source = source() { compileVertex(vertex, source) }
        if compileRecompiled, let function { compile(recompiled, vertex: function) }
        if compileInterpreted { compile(interpreted, vertex: vertexFunction) }
        return best ?? fallback ?? uberPipeline(key)
    }

    private func compileVertex(_ key: PICAMetalVertexCompiler.Key, _ source: String) {
        let options = MTLCompileOptions(); options.mathMode = .safe   // as the interpreter: NaN and infinity rules hold
        device.makeLibrary(source: source, options: options) { [self] library, error in
            guard let function = library?.makeFunction(name: "shadeVertex") else {
                NSLog("3duos vertex recompile failed: %@", "\(error.map { "\($0)" } ?? "no function")")
                return
            }
            lock.lock(); vertexFunctions[key] = function; lock.unlock()
        }
    }

    private func constants(_ config: [SIMD4<UInt32>]?) -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        var on = config != nil
        values.setConstantValue(&on, type: .bool, index: 0)
        for k in PICAMetalShaders.configSlots.indices {
            var value = config?[k] ?? .zero
            values.setConstantValue(&value, type: .int4, index: k + 1)
        }
        return values
    }

    private func descriptor(_ key: PICAMetalState.PipelineKey, _ fragment: MTLFunction, vertex: MTLFunction? = nil) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex ?? vertexFunction; d.fragmentFunction = fragment
        PICAMetalState.describe(key, into: d)
        return d
    }

    private func name(_ key: PICAMetalState.PipelineKey) -> String { key.fragmentDepth ? "drawFragmentDepth" : "drawFragment" }

    private func uberPipeline(_ key: PICAMetalState.PipelineKey) -> MTLRenderPipelineState {
        if let p = uber[key] { return p }
        let p = try! device.makeRenderPipelineState(descriptor: descriptor(key, try! library.makeFunction(name: name(key), constantValues: constants(nil))))
        uber[key] = p
        return p
    }

    private func compile(_ s: Specialized, vertex: MTLFunction) {
        library.makeFunction(name: name(s.key), constantValues: constants(s.config)) { [self] function, _ in
            guard let function else { return }
            device.makeRenderPipelineState(descriptor: descriptor(s.key, function, vertex: vertex)) { [self] state, _ in
                guard let state else { return }
                lock.lock(); ready[s] = state; lock.unlock()
            }
        }
    }
}
