// input: shaded clip-space vertices, the triangle topology and the viewport registers.
// output: screen-space triangles with attributes pre-divided by w, ready for perspective-correct rasterization.
// pos: primitive assembly, frustum clipping and viewport transform between the vertex shader and the pixel backend.

struct PICAScreenVertex {
    var x: Float = 0, y: Float = 0, z: Float = 0, invW: Float = 1
    var color = SIMD4<Float>(repeating: 0)          // color, texture01 and texture2W are already multiplied by invW
    var texture01 = SIMD4<Float>(repeating: 0)
    var texture2W = SIMD4<Float>(repeating: 0)
    var quaternion = SIMD4<Float>(repeating: 0), view = SIMD4<Float>(repeating: 0)
    var previous = SIMD4<Float>(repeating: 0)       // multiplied by invW like the other interpolants
}

struct PICATriangle {
    var v0: PICAScreenVertex, v1: PICAScreenVertex, v2: PICAScreenVertex
}

// Triangle list (0), strip (1) and fan (2). The shader topology (3) behaves like a list since geometry shaders are not run.
// Vertices are whatever a caller assembles: shaded vertices, slot indices or raw immediate-mode attributes.
struct PICAPrimitiveAssembler<Vertex> {
    var topology = 0 { didSet { reset() } }
    private var buffer: [Vertex?] = [nil, nil]
    private var index = 0, stripReady = false

    init(topology: Int = 0) { self.topology = topology }

    mutating func reset() { index = 0; stripReady = false }

    mutating func submit(_ vertex: Vertex, _ emit: (Vertex, Vertex, Vertex) -> Void) {
        if topology == 0 || topology == 3 {
            if index < 2 { buffer[index] = vertex; index += 1 } else { index = 0; emit(buffer[0]!, buffer[1]!, vertex) }
            return
        }
        if stripReady { emit(buffer[0]!, buffer[1]!, vertex) }
        buffer[index] = vertex
        stripReady = stripReady || index == 1
        index = topology == 1 ? 1 - index : 1
    }
}

enum PICAClipper {
    private static let planes: [SIMD4<Float>] = [
        SIMD4(-1, 0, 0, 1), SIMD4(1, 0, 0, 1), SIMD4(0, -1, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, -1, 0), SIMD4(0, 0, 1, 1),
        SIMD4(0, 0, 0, 1),
    ]
    private static let wEpsilon: Float = 0.00001

    // Appends the triangles that remain after clipping against the PICA view volume (-w <= z <= 0) and the user plane.
    static func clip(_ a: PICAClipVertex, _ b: PICAClipVertex, _ c: PICAClipVertex, viewport: PICAViewport,
                     into triangles: inout [PICATriangle]) {
        // Interpolate between the closer of q and -q so the normal does not flip across the triangle.
        var b = b, c = c
        if (a.quaternion * b.quaternion).sum() < 0 { b.quaternion = -b.quaternion }
        if (a.quaternion * c.quaternion).sum() < 0 { c.quaternion = -c.quaternion }
        var allPlanes = planes
        if viewport.clipEnabled { allPlanes.append(viewport.clipPlane) }
        func distance(_ v: PICAClipVertex, _ plane: Int) -> Float {
            let d = (v.position * allPlanes[plane]).sum()
            return plane == 6 ? d - wEpsilon : d
        }
        var outside = [0, 0, 0]
        for (i, v) in [a, b, c].enumerated() { for p in 0..<allPlanes.count where distance(v, p) < 0 { outside[i] |= 1 << p } }
        if outside[0] & outside[1] & outside[2] != 0 { return }
        if outside[0] | outside[1] | outside[2] == 0 {
            triangles.append(PICATriangle(v0: screen(a, viewport), v1: screen(b, viewport), v2: screen(c, viewport)))
            return
        }
        var polygon = [a, b, c]
        for plane in 0..<allPlanes.count {
            var clipped: [PICAClipVertex] = []
            var reference = polygon[polygon.count - 1]
            for vertex in polygon {
                let d = distance(vertex, plane), dReference = distance(reference, plane)
                if (d >= 0) != (dReference >= 0) {
                    var cut = reference
                    cut.lerp(vertex, dReference / (dReference - d))
                    clipped.append(cut)
                }
                if d >= 0 { clipped.append(vertex) }
                reference = vertex
            }
            guard clipped.count >= 3 else { return }
            polygon = clipped
        }
        let screenVertices = polygon.map { screen($0, viewport) }
        for i in 1..<(screenVertices.count - 1) {
            triangles.append(PICATriangle(v0: screenVertices[0], v1: screenVertices[i], v2: screenVertices[i + 1]))
        }
    }

    private static func screen(_ v: PICAClipVertex, _ viewport: PICAViewport) -> PICAScreenVertex {
        let invW = 1 / v.position.w
        var s = PICAScreenVertex()
        s.x = (v.position.x * invW + 1) * viewport.halfWidth + viewport.cornerX
        s.y = (v.position.y * invW + 1) * viewport.halfHeight + viewport.cornerY
        s.z = v.position.z * invW
        s.invW = invW
        s.color = v.color * invW
        s.texture01 = v.texture01 * invW
        s.texture2W = v.texture2W * invW
        s.quaternion = v.quaternion * invW
        s.view = v.view * invW
        s.previous = v.previous * invW
        return s
    }
}
