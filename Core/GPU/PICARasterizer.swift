// input: screen-space triangles, the decoded draw state, render-target surfaces and decoded textures.
// output: shaded, tested and blended pixels written into the surfaces' tiled mirrors.
// pos: the software pixel backend. Draws are queued and rasterized together on all cores when `finish` is called, so the
//      per-draw dispatch cost disappears; the Metal backend shares the PICAPixelBackend
//      queue protocol but draws meshes shaded on the GPU.
import Foundation

protocol PICAPixelBackend: AnyObject {
    // Completes deferred draws into the surfaces' mirrors. Called before mirrors are read, written back or evicted.
    func finish()
    // The renderer is about to rewrite the lighting or fog tables that queued draws point at.
    func tablesWillChange()
    // Starts the queued work at the end of a command list; mirrors may stay behind until `finish`.
    func submit()
}

// A triangle after culling: 12.4 fixed-point corners in counter-clockwise order plus per-vertex interpolants.
struct PICASetupTriangle {
    var x = SIMD3<Int>(repeating: 0), y = SIMD3<Int>(repeating: 0)
    var minX = 0, maxX = 0, minY = 0, maxY = 0
    var bias = SIMD3<Int>(repeating: 0)
    var area = 0
    var invW = SIMD3<Float>(repeating: 0), z = SIMD3<Float>(repeating: 0)
    var color = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
    var texture01 = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
    var texture2W = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
    var quaternion = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
    var view = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
}

// Pixel counts of the most recent batch, for diagnostics: covered pixels, then where they were dropped, then pixels written.
struct PICARasterStats { var covered = 0, depthFailed = 0, alphaFailed = 0, written = 0 }

final class PICARasterizer: PICAPixelBackend {
    private(set) var stats = PICARasterStats()

    // The queued batch. Contexts point into the stage and light pools only once the batch runs, since the pools may grow.
    private struct Pending { var context: PICARasterContext; var triangles: Range<Int>; var stages: Int; var lights: Int }
    private var pending: [Pending] = []
    private var setups: [PICASetupTriangle] = []
    private var stagePool: [PICATevStage] = [], lightPool: [PICALight] = []
    private var retained: [AnyObject] = []        // surfaces and textures the queued draws write or read
    private var pendingArea = 0

    func draw(_ triangles: [PICATriangle], state: PICADrawState, color: PICASurface?, depth: PICASurface?,
              textures: [PICADecodedTexture?]) {
        guard !triangles.isEmpty, state.target.width > 0, state.target.height > 0 else { return }
        let width = state.target.width, height = state.target.height
        let first = setups.count
        for t in triangles { if let s = Self.setup(t, state, width: width, height: height) { setups.append(s); pendingArea += (s.maxX - s.minX) * (s.maxY - s.minY) } }
        guard setups.count > first else { return }
        color?.markDirty(); depth?.markDirty()
        if let color { retained.append(color) }
        if let depth { retained.append(depth) }
        for case let t? in textures { retained.append(t) }
        pending.append(Pending(context: PICARasterContext(state: state, color: color, depth: depth, textures: textures),
                               triangles: first..<setups.count, stages: stagePool.count, lights: lightPool.count))
        stagePool += state.tevStages
        lightPool += state.lighting.lights
    }

    func tablesWillChange() { finish() }
    func submit() { finish() }

    func finish() {
        guard !pending.isEmpty else { return }
        defer {
            pending.removeAll(keepingCapacity: true); setups.removeAll(keepingCapacity: true)
            stagePool.removeAll(keepingCapacity: true); lightPool.removeAll(keepingCapacity: true)
            retained.removeAll(keepingCapacity: true); pendingArea = 0
        }
        // Small batches are not worth waking the other cores. Workers own interleaved 8-row strips (one tile row each, so
        // no two workers share a cache line) and see every draw in submission order, so overlap stays deterministic.
        let bands = pendingArea > 4_000 ? Self.workers : 1
        let bandStats = UnsafeMutablePointer<PICARasterStats>.allocate(capacity: bands)
        bandStats.initialize(repeating: PICARasterStats(), count: bands)
        defer { bandStats.deallocate() }
        stagePool.withUnsafeBufferPointer { stages in lightPool.withUnsafeBufferPointer { lights in
            for i in pending.indices {
                pending[i].context.bind(stages: stages.baseAddress.map { $0 + pending[i].stages },
                                        lights: lights.baseAddress.map { $0 + pending[i].lights })
            }
            pending.withUnsafeBufferPointer { draws in setups.withUnsafeBufferPointer { triangles in
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    Self.rasterize(draws, triangles, band: band, of: bands, stats: &bandStats[band])
                }
            }}
        }}
        stats = (0..<bands).reduce(into: PICARasterStats()) { s, b in
            s.covered += bandStats[b].covered; s.depthFailed += bandStats[b].depthFailed
            s.alphaFailed += bandStats[b].alphaFailed; s.written += bandStats[b].written
        }
    }

    private static func setup(_ t: PICATriangle, _ state: PICADrawState, width: Int, height: Int) -> PICASetupTriangle? {
        var v = (t.v0, t.v1, t.v2)
        for vertex in [v.0, v.1, v.2] where !(vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite && vertex.invW.isFinite) { return nil }
        func fixed(_ f: Float) -> Int { PICAMath.integer((f * 16).rounded()) }
        var x = SIMD3(fixed(v.0.x), fixed(v.1.x), fixed(v.2.x)), y = SIMD3(fixed(v.0.y), fixed(v.1.y), fixed(v.2.y))
        var area = (x[1] - x[0]) * (y[2] - y[0]) - (y[1] - y[0]) * (x[2] - x[0])
        let cull = state.viewport.cullMode
        if area == 0 || (cull == 1 && area > 0) || (cull == 2 && area < 0) { return nil }
        if area < 0 {   // always rasterize counter-clockwise
            swap(&v.1, &v.2); x = SIMD3(x[0], x[2], x[1]); y = SIMD3(y[0], y[2], y[1]); area = -area
        }
        var s = PICASetupTriangle()
        s.x = x; s.y = y; s.area = area
        // Fill rule: the pixel center on a right-hand or flat-bottom edge belongs to the neighbour.
        func rightSide(_ p: Int, _ a: Int, _ b: Int) -> Int {
            if y[a] == y[b] { return y[p] < y[a] ? -1 : 0 }
            return x[p] < x[a] + (x[b] - x[a]) * (y[p] - y[a]) / (y[b] - y[a]) ? -1 : 0
        }
        s.bias = SIMD3(rightSide(0, 1, 2), rightSide(1, 2, 0), rightSide(2, 0, 1))
        var minX = x.min() >> 4, maxX = (x.max() + 15) >> 4, minY = y.min() >> 4, maxY = (y.max() + 15) >> 4
        let sc = state.viewport.scissor
        if state.viewport.scissorMode == 3 { minX = max(minX, sc[0]); minY = max(minY, sc[1]); maxX = min(maxX, sc[2] + 1); maxY = min(maxY, sc[3] + 1) }
        s.minX = max(minX, 0); s.minY = max(minY, 0); s.maxX = min(maxX, width); s.maxY = min(maxY, height)
        guard s.minX < s.maxX, s.minY < s.maxY else { return nil }
        s.invW = SIMD3(v.0.invW, v.1.invW, v.2.invW); s.z = SIMD3(v.0.z, v.1.z, v.2.z)
        s.color = (v.0.color, v.1.color, v.2.color)
        s.texture01 = (v.0.texture01, v.1.texture01, v.2.texture01)
        s.texture2W = (v.0.texture2W, v.1.texture2W, v.2.texture2W)
        s.quaternion = (v.0.quaternion, v.1.quaternion, v.2.quaternion)
        s.view = (v.0.view, v.1.view, v.2.view)
        return s
    }

    private static let workers = min(16, max(1, ProcessInfo.processInfo.activeProcessorCount))

    private static func rasterize(_ draws: UnsafeBufferPointer<Pending>, _ triangles: UnsafeBufferPointer<PICASetupTriangle>,
                                  band: Int, of bands: Int, stats: inout PICARasterStats) {
        for draw in draws {
            let c = draw.context
            for i in draw.triangles {
                let t = triangles[i]
                // Edge i is opposite vertex i; E(p) = a * (px - ax) + b * (py - ay) is >= 0 inside a counter-clockwise triangle.
                let ax = SIMD3(t.x[1], t.x[2], t.x[0]), ay = SIMD3(t.y[1], t.y[2], t.y[0])
                let bx = SIMD3(t.x[2], t.x[0], t.x[1]), by = SIMD3(t.y[2], t.y[0], t.y[1])
                let stepX = (ay &- by) &* 16
                var strip = t.minY >> 3
                strip += (band - strip % bands + bands) % bands
                while strip << 3 < t.maxY {
                    for py in max(strip << 3, t.minY)..<min(strip << 3 + 8, t.maxY) {
                        let edge = (ay &- by) &* (t.minX &* 16 &+ 8 &- ax) &+ (bx &- ax) &* (py &* 16 &+ 8 &- ay)
                        guard let span = Self.span(edge &+ t.bias, stepX, count: t.maxX - t.minX) else { continue }
                        var e = edge &+ stepX &* span.lowerBound
                        for k in span {
                            defer { e &+= stepX }
                            let px = t.minX + k
                            if c.scissorMode == 1, px >= c.scissor[0], px <= c.scissor[2], py >= c.scissor[1], py <= c.scissor[3] { continue }
                            c.shade(t, px, py, e, &stats)
                        }
                    }
                    strip += bands
                }
            }
        }
    }

    // The pixel steps k in 0..<count where every biased edge value e + step * k is >= 0, solved exactly in integers.
    @inline(__always) private static func span(_ e: SIMD3<Int>, _ step: SIMD3<Int>, count: Int) -> ClosedRange<Int>? {
        var low = 0, high = count - 1
        for i in 0..<3 {
            let e = e[i], s = step[i]
            if s > 0 {
                if e < 0 { low = max(low, (-e + s - 1) / s) }
            } else if s < 0 {
                guard e >= 0 else { return nil }
                high = min(high, e / -s)
            } else if e < 0 {
                return nil
            }
        }
        return low <= high ? low...high : nil
    }
}
