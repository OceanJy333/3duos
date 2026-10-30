// input: top-screen draws (vertex buffer key, uniforms) and, for the software path, their screen-space triangles.
// output: last frame's uniforms of each draw and, for the software path, a 400x240 LCD motion plane.
// pos: MetalFX motion source. A draw is matched to last frame's draw of the same vertex buffer with the most similar
//      uniforms; shading the vertices again with those uniforms gives where they were. No match: no motion.
import Foundation

final class PICAMotionTracker {
    private struct Key: Hashable { var mesh: Int, count: Int, first: Int, indexed: Bool }

    private static let maxMotion: Float = 64
    // Several instances of one mesh share a key; each frame's uniform sets are kept per key and matched by similarity.
    private var previous: [Key: [[SIMD4<Float>]]] = [:], current: [Key: [[SIMD4<Float>]]] = [:]
    private var buffer: [SIMD2<Float>] = [], nearest: [Float] = []
    private var width = 0
    private(set) var finishedFrames = 0
    private(set) var lcdMotion: [SIMD2<Float>] = []

    // Last frame's uniforms of the most similar draw of the same mesh (nil for a new mesh); records this frame's.
    func previousUniforms(mesh: Int, count: Int, first: Int, indexed: Bool, uniforms: [SIMD4<Float>]) -> [SIMD4<Float>]? {
        let key = Key(mesh: mesh, count: count, first: first, indexed: indexed)
        current[key, default: []].append(uniforms)
        return previous[key]?.min { Self.distance($0, uniforms) < Self.distance($1, uniforms) }
    }

    private static func distance(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += (d * d).sum() }
        return sum
    }

    var hasDraws: Bool { !current.isEmpty }

    func rasterize(_ triangles: [PICATriangle], state: PICADrawState) {
        let w = state.target.width, h = state.target.height
        if width != w { width = w; buffer = [SIMD2<Float>](repeating: .zero, count: w * h); nearest = [Float](repeating: .infinity, count: w * h) }
        let (halfWidth, halfHeight, cornerX, cornerY) = (state.viewport.halfWidth, state.viewport.halfHeight, state.viewport.cornerX, state.viewport.cornerY)
        let test = state.merger.depthTestEnabled, scale = state.viewport.depthScale, offset = state.viewport.depthOffset
        for t in triangles {
            let (a, b, c) = (t.v0, t.v1, t.v2)
            let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            guard abs(area) > 1e-6 else { continue }
            let x0 = max(0, Int(min(a.x, b.x, c.x))), x1 = min(w - 1, Int(max(a.x, b.x, c.x)))
            let y0 = max(0, Int(min(a.y, b.y, c.y))), y1 = min(h - 1, Int(max(a.y, b.y, c.y)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let w0 = ((b.x - px) * (c.y - py) - (c.x - px) * (b.y - py)) / area
                    let w1 = ((c.x - px) * (a.y - py) - (a.x - px) * (c.y - py)) / area
                    let w2 = 1 - w0 - w1
                    guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                    let z = (a.z * w0 + b.z * w1 + c.z * w2) * scale + offset, i = y * w + x
                    guard !test || z <= nearest[i] else { continue }
                    nearest[i] = z
                    // Perspective-correct last-frame clip position of this pixel, projected with the same viewport.
                    let invW = a.invW * w0 + b.invW * w1 + c.invW * w2
                    let p = (a.previous * w0 + b.previous * w1 + c.previous * w2) / invW
                    guard p.w > 0.00001 else { buffer[i] = .zero; continue }
                    let m = SIMD2((p.x / p.w + 1) * halfWidth + cornerX - px, (p.y / p.w + 1) * halfHeight + cornerY - py)
                    // A draw that matched a different object last frame jumps across the screen; treat that as new content.
                    buffer[i] = (m * m).sum() > Self.maxMotion * Self.maxMotion ? .zero : m
                }
            }
        }
    }

    // Converts the render-target motion to LCD pixels and starts the next frame. A no-op when nothing was drawn,
    // so the bottom-screen transfer that follows the top one does not discard the frame.
    func finishFrame() {
        guard !current.isEmpty else { return }
        let scaleX = max(1, width / 240)
        var plane = [SIMD2<Float>](repeating: .zero, count: 400 * 240)
        for row in 0..<240 {
            for column in 0..<400 {
                let m = buffer[column * width + (239 - row) * scaleX]
                plane[row * 400 + column] = SIMD2(m.y, -m.x / Float(scaleX))
            }
        }
        lcdMotion = plane
        finishedFrames += 1
        previous = current; current.removeAll()
        buffer = [SIMD2<Float>](repeating: .zero, count: buffer.count); nearest = [Float](repeating: .infinity, count: nearest.count)
    }
}
