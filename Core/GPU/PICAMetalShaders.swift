// input: nothing at run time; Metal Shading Language source compiled once by PICAMetalBackend.
// output: the draw fragment function that evaluates one PICA draw state from a uniform block.
// pos: GPU twin of PICAPixel/PICAFragment/PICALighting/PICAOutputMerger; integer TEV math matches the software rasterizer.

enum PICAMetalShaders {
    // Draw-state fields that select code paths, as int4 function constants: config slot k is `Draw` slot configSlots[k]
    // (TEV stages and buffer updates, alpha test, texture units, fog, flags, logic op, lighting inputs). With `spec` the
    // compiler folds them away (one pipeline per configuration); without it the same source is the uber shader.
    static let configSlots = Array(0..<30) + Array(36..<42) + [42, 44, 45, 46, 47, 54, 56, 71, 60] + Array(61..<68)
    static let specialization = "constant bool spec [[function_constant(0)]];\n"
        + configSlots.indices.map { "constant int4 k\($0) [[function_constant(\($0 + 1))]];" }.joined(separator: "\n")
        + "\nstatic int4 K(int i) { switch (i) { " + configSlots.indices.map { "case \($0): return k\($0);" }.joined(separator: " ")
        + " default: return 0; } }\n#define CFG(i, dynamic) (spec ? K(i) : (dynamic))"

    static let draw = """
    #include <metal_stdlib>
    using namespace metal;

    \(specialization)

    // Interpolants of PICAMetalVertex's VertexOut: z/w is affine on screen, w and the rest are perspective-correct.
    struct Varyings {
        float4 position [[position]];
        float depth [[center_no_perspective]];
        float w;
        float4 color, tex01, tex2W, quat, view, prev;
    };
    // MetalFX inputs of top-screen draws: the viewport that projects `prev` (half size, corner) and how translucent draws count.
    struct MotionInfo { float4 viewport; int blend, alphaCoverage; };
    struct Light { float4 specular0, specular1, diffuse, ambient, position, spot, distance; int4 flags, more; };
    struct Draw {
        int4 colorSource[6], alphaSource[6], colorModifier[6], alphaModifier[6], ops[6], constants[6], bufferUpdate[6];
        int4 misc;            // stage count, alpha test enabled, alpha func, alpha ref
        int4 bufferColor;
        int4 textureEnabled;  // units 0-2, project texture 0
        int4 wrap[3];         // wrapS, wrapT, linear, has pixels
        int4 size[3];
        int4 border[3];
        int4 fog, fogColor;   // enabled, flip
        int4 flags;           // texture 2 uses coordinate 1, w-buffering, scissor excludes, lighting enabled
        int4 scissor;         // x1, y1, x2, y2 in native pixels
        float4 depth;         // scale, offset, max depth, internal scale
        float4 target;        // native width, height
        int4 lighting;        // light count, clamp highlights, primary alpha, secondary alpha
        int4 inputs[7];       // distribution0, distribution1, fresnel, reflect r/g/b, spot: enabled, source, absolute, table
        float4 scales[2];
        float4 ambient;
        int4 logic;           // 0 copy, 1 clear, 2 set, 3 copy inverted
        Light lights[8];
    };

    static int4 unpack(uint c) { return int4(c & 255, (c >> 8) & 255, (c >> 16) & 255, c >> 24); }

    static int wrapCoordinate(int mode, int c, int size) {
        int m = c & (size - 1);
        switch (mode) {
        case 0: return clamp(c, 0, size - 1);
        case 1: return c >= 0 && c < size ? c : -1;
        case 3: { int r = (c % (2 * size) + 2 * size) & (2 * size - 1); return r >= size ? 2 * size - 1 - r : r; }
        case 4: return c < 0 ? m : min(c, size - 1);
        case 5: return c < 0 ? m : (c >= size ? -1 : c);
        default: return m;
        }
    }

    static int4 texel(texture2d<uint> t, constant Draw &d, int unit, int x, int y) {
        if (x < 0 || y < 0) return d.border[unit];
        return int4(t.read(uint2(x, y)));
    }

    static int4 sampleTexture(texture2d<uint> t, constant Draw &d, int unit, float u, float v) {
        if (CFG(38 + unit, d.wrap[unit]).w == 0) return int4(0, 0, 0, 255);
        int w = d.size[unit].x, h = d.size[unit].y, ws = CFG(38 + unit, d.wrap[unit]).x, wt = CFG(38 + unit, d.wrap[unit]).y;
        float x = u * float(w), y = v * float(h);
        if (CFG(38 + unit, d.wrap[unit]).z == 0) return texel(t, d, unit, wrapCoordinate(ws, int(floor(x)), w), wrapCoordinate(wt, int(floor(y)), h));
        float fx = x - 0.5, fy = y - 0.5, x0 = floor(fx), y0 = floor(fy);
        int wx = int((fx - x0) * 256), wy = int((fy - y0) * 256), ix = int(x0), iy = int(y0);
        int sx0 = wrapCoordinate(ws, ix, w), sx1 = wrapCoordinate(ws, ix + 1, w);
        int sy0 = wrapCoordinate(wt, iy, h), sy1 = wrapCoordinate(wt, iy + 1, h);
        int4 top = texel(t, d, unit, sx0, sy0) * (256 - wx) + texel(t, d, unit, sx1, sy0) * wx;
        int4 bottom = texel(t, d, unit, sx0, sy1) * (256 - wx) + texel(t, d, unit, sx1, sy1) * wx;
        int4 s = (top * (256 - wy) + bottom * wy) >> 16;
        if (CFG(38 + unit, d.wrap[unit]).z != 2) return s;
        // Glyph coverage read as a distance field: cut at half coverage, antialiased over one output pixel.
        float a = float(s.w) / 255, edge = max(fwidth(a) * 0.5, 0.02);
        return int4(s.xyz, int(smoothstep(0.5 - edge, 0.5 + edge, a) * 255 + 0.5));
    }

    static int4 divide255(int4 x) { int4 t = x + 1; return (t + (t >> 8)) >> 8; }

    static int4 colorModifier(int m, int4 v) {
        switch (m) {
        case 1: return 255 - v;
        case 2: return int4(v.w); case 3: return int4(255 - v.w);
        case 4: return int4(v.x); case 5: return int4(255 - v.x);
        case 8: return int4(v.y); case 9: return int4(255 - v.y);
        case 12: return int4(v.z); case 13: return int4(255 - v.z);
        default: return v;
        }
    }

    static int alphaModifier(int m, int4 v) {
        int c = (m >> 1) == 0 ? v.w : (m >> 1) == 1 ? v.x : (m >> 1) == 2 ? v.y : v.z;
        return (m & 1) == 0 ? c : 255 - c;
    }

    static int4 combine(int op, int4 a, int4 b, int4 c) {
        switch (op) {
        case 0: return a;
        case 1: return divide255(a * b);
        case 2: return min(a + b, 255);
        case 3: return clamp(a + b - 128, 0, 255);
        case 4: return divide255(a * c + b * (255 - c));
        case 5: return max(a - b, 0);
        case 6: case 7: {
            int4 p = (a * 2 - 255) * (b * 2 - 255) + 128;
            return int4(clamp(p.x / 256 + p.y / 256 + p.z / 256, 0, 255));
        }
        case 8: return min((a * b + c * 255) / 255, 255);
        default: return divide255(min(a + b, 255) * c);
        }
    }

    struct Sources { int4 primary, lit0, lit1, t0, t1, t2, buf, konst, previous; };
    static int4 source(thread const Sources &s, int id) {
        switch (id) {
        case 0: return s.primary; case 1: return s.lit0; case 2: return s.lit1;
        case 3: return s.t0; case 4: return s.t1; case 5: return s.t2;
        case 13: return s.buf; case 14: return s.konst; case 15: return s.previous;
        default: return int4(0);
        }
    }

    \(lighting)

    // motion: previous minus current position in render-target pixels, blended by coverage; reactive: how much MetalFX
    // must trust this frame over history (translucent effects; text and HUD go to the UI layer instead).
    struct Shaded { float4 color, motion, reactive, layer; float depth; };
    struct Output { float4 color [[color(0)]]; float4 motion [[color(1)]]; float4 reactive [[color(2)]]; float4 layer [[color(3)]]; };
    struct DepthOutput { float4 color [[color(0)]]; float4 motion [[color(1)]]; float4 reactive [[color(2)]]; float4 layer [[color(3)]]; float depth [[depth(any)]]; };

    static Shaded shade(Varyings in, constant Draw &d, const device uint *lut, const device uint *fog, constant MotionInfo &mi,
                        texture2d<uint> tex0, texture2d<uint> tex1, texture2d<uint> tex2);

    // Depth comes from the rasterizer (the vertex shader's z), so the GPU keeps early depth tests and hidden-surface removal.
    fragment Output drawFragment(Varyings in [[stage_in]], constant Draw &d [[buffer(1)]], const device uint *lut [[buffer(2)]],
                                 const device uint *fog [[buffer(3)]], constant MotionInfo &mi [[buffer(4)]],
                                 texture2d<uint> tex0 [[texture(0)]], texture2d<uint> tex1 [[texture(1)]], texture2d<uint> tex2 [[texture(2)]]) {
        Shaded s = shade(in, d, lut, fog, mi, tex0, tex1, tex2);
        return { s.color, s.motion, s.reactive, s.layer };
    }

    // W-buffered draws: depth is not affine on screen, so it is written per fragment.
    fragment DepthOutput drawFragmentDepth(Varyings in [[stage_in]], constant Draw &d [[buffer(1)]], const device uint *lut [[buffer(2)]],
                                 const device uint *fog [[buffer(3)]], constant MotionInfo &mi [[buffer(4)]],
                                 texture2d<uint> tex0 [[texture(0)]], texture2d<uint> tex1 [[texture(1)]], texture2d<uint> tex2 [[texture(2)]]) {
        Shaded s = shade(in, d, lut, fog, mi, tex0, tex1, tex2);
        return { s.color, s.motion, s.reactive, s.layer, s.depth };
    }

    static Shaded shade(Varyings in, constant Draw &d, const device uint *lut, const device uint *fog, constant MotionInfo &mi,
                        texture2d<uint> tex0, texture2d<uint> tex1, texture2d<uint> tex2) {
        float2 pixel = floor(in.position.xy / d.depth.w);
        if (CFG(42, d.flags).z != 0 && pixel.x >= d.scissor.x && pixel.x <= d.scissor.z && pixel.y >= d.scissor.y && pixel.y <= d.scissor.w) discard_fragment();
        if (!(in.w > 0)) discard_fragment();
        float depth = in.depth * d.depth.x + d.depth.y;
        if (CFG(42, d.flags).y != 0) depth *= in.w;
        float clamped = depth > 0 ? min(depth, 1.0) : 0;
        uint z = uint(clamped * d.depth.z);
        Sources s;
        float4 c = in.color * 255;
        s.primary = int4(select(int4(0), int4(min(c, 255.0) + 0.5), c > 0));
        s.lit0 = s.lit1 = s.t0 = s.t1 = s.t2 = int4(0);
        float4 uv01 = in.tex01, uv2W = in.tex2W;
        if (CFG(37, d.textureEnabled).x != 0) s.t0 = CFG(37, d.textureEnabled).w != 0 ? sampleTexture(tex0, d, 0, uv01.x / uv2W.z, uv01.y / uv2W.z)
                                                                     : sampleTexture(tex0, d, 0, uv01.x, uv01.y);
        if (CFG(37, d.textureEnabled).y != 0) s.t1 = sampleTexture(tex1, d, 1, uv01.z, uv01.w);
        if (CFG(37, d.textureEnabled).z != 0) s.t2 = CFG(42, d.flags).x != 0 ? sampleTexture(tex2, d, 2, uv01.z, uv01.w) : sampleTexture(tex2, d, 2, uv2W.x, uv2W.y);
        if (CFG(42, d.flags).w != 0) lightFragment(d, lut, in.quat, in.view.xyz, s.lit0, s.lit1);
        int4 output = int4(0), buffer = int4(0), nextBuffer = d.bufferColor;
        for (int i = 0, stages = CFG(36, d.misc).x; i < 6 && i < stages; i++) {
            s.buf = buffer; s.konst = d.constants[i]; s.previous = output;
            int3 cs = CFG(i, d.colorSource[i]).xyz;
            if (i == 0 && cs.x == 15) cs.x = cs.z;
            if (i == 0 && cs.y == 15) cs.y = cs.z;
            int4 color = combine(CFG(24 + i, d.ops[i]).x, colorModifier(CFG(12 + i, d.colorModifier[i]).x, source(s, cs.x)),
                                 colorModifier(CFG(12 + i, d.colorModifier[i]).y, source(s, cs.y)), colorModifier(CFG(12 + i, d.colorModifier[i]).z, source(s, CFG(i, d.colorSource[i]).z)));
            int alpha;
            if (CFG(24 + i, d.ops[i]).x == 7) alpha = color.x;
            else alpha = combine(CFG(24 + i, d.ops[i]).y, int4(alphaModifier(CFG(18 + i, d.alphaModifier[i]).x, source(s, CFG(6 + i, d.alphaSource[i]).x))),
                                 int4(alphaModifier(CFG(18 + i, d.alphaModifier[i]).y, source(s, CFG(6 + i, d.alphaSource[i]).y))),
                                 int4(alphaModifier(CFG(18 + i, d.alphaModifier[i]).z, source(s, CFG(6 + i, d.alphaSource[i]).z)))).x;
            color = min(color * CFG(24 + i, d.ops[i]).z, 255);
            output = int4(color.xyz, min(alpha * CFG(24 + i, d.ops[i]).w, 255));
            buffer = nextBuffer;
            if (CFG(30 + i, d.bufferUpdate[i]).x != 0) nextBuffer = int4(output.xyz, nextBuffer.w);
            if (CFG(30 + i, d.bufferUpdate[i]).y != 0) nextBuffer.w = output.w;
        }
        if (CFG(36, d.misc).y != 0) {
            int a = output.w, r = d.misc.w;
            bool pass = CFG(36, d.misc).z == 0 ? false : CFG(36, d.misc).z == 1 ? true : CFG(36, d.misc).z == 2 ? a == r : CFG(36, d.misc).z == 3 ? a != r
                      : CFG(36, d.misc).z == 4 ? a < r : CFG(36, d.misc).z == 5 ? a <= r : CFG(36, d.misc).z == 6 ? a > r : a >= r;
            if (!pass) discard_fragment();
        }
        if (CFG(41, d.fog).x != 0) {
            float index = (CFG(41, d.fog).y != 0 ? 1 - clamped : clamped) * 128, i = clamp(floor(index), 0.0, 127.0);
            uint entry = fog[int(i)];
            float difference = float(int(entry << 19) >> 19) / 2047;
            float factor = clamp(float((entry >> 13) & 0x7FF) / 2047 + difference * (index - i), 0.0, 1.0);
            output.xyz = int3(float3(output.xyz) * factor + float3(d.fogColor.xyz) * (1 - factor));
        }
        if (CFG(43, d.logic).x == 1) output = int4(0); else if (CFG(43, d.logic).x == 2) output = int4(255); else if (CFG(43, d.logic).x == 3) output = 255 - output;
        Shaded o;
        o.color = float4(output) / 255;
        float4 p = in.prev;
        float2 m = 0;
        if (p.w > 0.00001) {
            m = (p.xy / p.w + 1) * mi.viewport.xy + mi.viewport.zw - in.position.xy / d.depth.w;
            if (dot(m, m) > 64 * 64) m = 0;    // matched a different object last frame: new content
        }
        float coverage = mi.blend == 0 ? 1 : mi.alphaCoverage != 0 ? o.color.w : max3(o.color.x, o.color.y, o.color.z);
        o.motion = float4(m * d.depth.w, 0, coverage);
        o.reactive = float4(mi.blend != 0 ? coverage : 0);
        o.layer = o.color;   // the UI layer blends the same color (PICAMetalState)
        o.depth = float(z) / 16777216.0;
        return o;
    }
    """
}
