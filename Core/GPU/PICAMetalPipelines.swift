// input: pipeline keys (blend and attachment state) and each draw's `Draw` uniform block.
// output: the render pipeline for a draw: one specialized to its TEV/texture/lighting configuration once compiled, the uber
//         shader until then.
// pos: pipeline cache of PICAMetalBackend. Specialization folds the per-fragment switches and loops of the uber shader
//      away (the fragment stage was ~95% of GPU time); compiling in the background keeps new configurations from stalling.
import Metal

final class PICAMetalPipelines {
    private struct Specialized: Hashable { let key: PICAMetalState.PipelineKey; let config: [SIMD4<UInt32>] }

    private let device: MTLDevice, library: MTLLibrary, vertexFunction: MTLFunction
    private var uber: [PICAMetalState.PipelineKey: MTLRenderPipelineState] = [:]
    private let lock = NSLock()   // `ready` is filled on Metal's compiler threads
    private var ready: [Specialized: MTLRenderPipelineState] = [:], requested: Set<Specialized> = []

    init(device: MTLDevice, library: MTLLibrary, vertexFunction: MTLFunction) {
        self.device = device; self.library = library; self.vertexFunction = vertexFunction
    }

    func pipeline(_ key: PICAMetalState.PipelineKey, uniforms: [SIMD4<UInt32>]) -> MTLRenderPipelineState {
        var config = PICAMetalShaders.configSlots.map { uniforms[$0] }
        config[36].w = 0   // the alpha reference stays a uniform
        let specialized = Specialized(key: key, config: config)
        lock.lock()
        let compiled = ready[specialized], first = compiled == nil && requested.insert(specialized).inserted
        lock.unlock()
        if let compiled { return compiled }
        if first { compile(specialized) }
        return uberPipeline(key)
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

    private func descriptor(_ key: PICAMetalState.PipelineKey, _ fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertexFunction; d.fragmentFunction = fragment
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

    private func compile(_ s: Specialized) {
        library.makeFunction(name: name(s.key), constantValues: constants(s.config)) { [self] function, _ in
            guard let function else { return }
            device.makeRenderPipelineState(descriptor: descriptor(s.key, function)) { [self] state, _ in
                guard let state else { return }
                lock.lock(); ready[s] = state; lock.unlock()
            }
        }
    }
}
