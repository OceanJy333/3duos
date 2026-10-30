// input: nothing at run time; MSL source compiled with PICAMetalShaders.draw.
// output: kernels that move pixels between high-res GPU render targets, the guest's native tiled buffers and the LCD image.
// pos: the Metal backend's only bridges to guest memory (write-back, upload) and to the app (high-res LCD frame and UI layer).

extension PICAMetalShaders {
    static let kernels = """
    struct Surface { int width, height, format, scale; };   // format: color 0-4, depth 0/2/3

    static uint tiledIndex(int x, int y, int width) {
        int m = (x & 1) | (y & 1) << 1 | (x & 2) << 1 | (y & 2) << 2 | (x & 4) << 2 | (y & 4) << 3;
        return uint((x & ~7) * 8 + m + (y & ~7) * width);
    }

    // High-res color/depth -> native guest layout: the center sample of each native pixel, packed like PICAColorFormat/PICADepthFormat.
    kernel void writeBackColor(texture2d<float, access::read> color [[texture(0)]], device uchar *out [[buffer(0)]],
                               constant Surface &s [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= s.width || int(gid.y) >= s.height) return;
        uint4 c = uint4(color.read(gid * uint(s.scale) + uint(s.scale / 2)) * 255 + 0.5);
        uint bpp = s.format == 0 ? 4 : s.format == 1 ? 3 : 2;
        device uchar *p = out + tiledIndex(gid.x, s.height - 1 - gid.y, s.width) * bpp;
        switch (s.format) {
        case 0: p[0] = c.a; p[1] = c.b; p[2] = c.g; p[3] = c.r; break;
        case 1: p[0] = c.b; p[1] = c.g; p[2] = c.r; break;
        default: {
            uint v = s.format == 2 ? (c.r >> 3) << 11 | (c.g >> 3) << 6 | (c.b >> 3) << 1 | c.a >> 7
                   : s.format == 3 ? (c.r >> 3) << 11 | (c.g >> 2) << 5 | c.b >> 3
                   : (c.r >> 4) << 12 | (c.g >> 4) << 8 | (c.b >> 4) << 4 | c.a >> 4;
            p[0] = v & 255; p[1] = v >> 8;
        }
        }
    }

    kernel void writeBackDepth(depth2d<float, access::read> depth [[texture(0)]], texture2d<uint, access::read> stencil [[texture(1)]],
                               device uchar *out [[buffer(0)]], constant Surface &s [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= s.width || int(gid.y) >= s.height) return;
        uint2 at = gid * uint(s.scale) + uint(s.scale / 2);
        uint z = uint(depth.read(at) * 16777216.0);
        uint bpp = s.format == 0 ? 2 : s.format == 2 ? 3 : 4;
        device uchar *p = out + tiledIndex(gid.x, s.height - 1 - gid.y, s.width) * bpp;
        p[0] = z & 255; p[1] = (z >> 8) & 255;
        if (s.format != 0) p[2] = (z >> 16) & 255;
        if (s.format == 3) p[3] = stencil.read(at).r;
    }

    // Native guest buffer -> high-res target (nearest), as a full-screen pass so depth and stencil can be written too.
    struct UploadVaryings { float4 position [[position]]; };
    vertex UploadVaryings uploadVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        UploadVaryings o; o.position = float4(p * 2 - 1, 0, 1); return o;
    }
    static uint nativeOffset(float4 position, constant Surface &s, uint bpp) {
        int2 native = int2(position.xy) / s.scale;
        return tiledIndex(native.x, s.height - 1 - native.y, s.width) * bpp;
    }
    fragment float4 uploadColor(UploadVaryings in [[stage_in]], const device uchar *src [[buffer(0)]], constant Surface &s [[buffer(1)]]) {
        uint bpp = s.format == 0 ? 4 : s.format == 1 ? 3 : 2;
        const device uchar *p = src + nativeOffset(in.position, s, bpp);
        uint4 c;
        if (s.format == 0) c = uint4(p[3], p[2], p[1], p[0]);
        else if (s.format == 1) c = uint4(p[2], p[1], p[0], 255);
        else {
            uint v = uint(p[0]) | uint(p[1]) << 8;
            if (s.format == 2) c = uint4((v >> 11) << 3, ((v >> 6) & 31) << 3, ((v >> 1) & 31) << 3, (v & 1) * 255);
            else if (s.format == 3) c = uint4((v >> 11) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3, 255);
            else c = uint4((v >> 12) * 17, ((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17);
        }
        return float4(c) / 255;
    }
    struct DepthOut { float depth [[depth(any)]]; uint stencil [[stencil]]; };
    fragment DepthOut uploadDepth(UploadVaryings in [[stage_in]], const device uchar *src [[buffer(0)]], constant Surface &s [[buffer(1)]]) {
        uint bpp = s.format == 0 ? 2 : s.format == 2 ? 3 : 4;
        const device uchar *p = src + nativeOffset(in.position, s, bpp);
        uint z = uint(p[0]) | uint(p[1]) << 8 | (s.format != 0 ? uint(p[2]) << 16 : 0);
        DepthOut o; o.depth = float(z) / 16777216.0; o.stencil = s.format == 3 ? p[3] : 0; return o;
    }

    // Display transfer into the high-res LCD image: row 0 is the top LCD row, as GPUState.framebuffer + FramebufferDecoder show it.
    struct Transfer { int inputHeight, outputHeight, scaleX, scaleY, flip, scale, lcdWidth, hasDepth; float depthMax; int hasMotion; };
    kernel void lcdTransfer(texture2d<float, access::read> color [[texture(0)]], depth2d<float, access::read> depth [[texture(1)]],
                            texture2d<float, access::write> lcd [[texture(2)]], texture2d<float, access::write> lcdDepth [[texture(3)]],
                            texture2d<float, access::read> motion [[texture(4)]], texture2d<float, access::read> reactive [[texture(5)]],
                            texture2d<float, access::write> lcdMotion [[texture(6)]], texture2d<float, access::write> lcdReactive [[texture(7)]],
                            texture2d<float, access::read> layer [[texture(8)]], texture2d<float, access::write> lcdLayer [[texture(9)]],
                            constant Transfer &t [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= t.lcdWidth * t.scale || int(gid.y) >= 240 * t.scale) return;
        float S = float(t.scale);
        float ox = 240 - (float(gid.y) + 0.5) / S, oy = (float(gid.x) + 0.5) / S;    // LCD column/row -> linear output pixel
        float y = t.flip != 0 ? float(t.outputHeight) - oy : oy;
        float sx = ox * t.scaleX, sy = y * t.scaleY;                                 // native input position, rows bottom-up
        int2 base = int2(floor(sx * S - (t.scaleX - 1) * 0.5), floor((float(t.inputHeight) - sy) * S - (t.scaleY - 1) * 0.5));
        float4 sum = 0, ui = 0; float z = 0, r = 0; float2 m = 0;
        for (int j = 0; j < t.scaleY; j++) for (int i = 0; i < t.scaleX; i++) {
            uint2 at = uint2(clamp(base + int2(i, j), int2(0), int2(color.get_width() - 1, color.get_height() - 1)));
            sum += color.read(at);
            if (t.hasDepth != 0) z += depth.read(at);
            if (t.hasMotion != 0) { m += motion.read(at).xy; r = max(r, reactive.read(at).x); ui += layer.read(at); }
        }
        float n = float(t.scaleX * t.scaleY);
        lcd.write(float4(sum.rgb / n, 1), gid);
        lcdDepth.write(float4(z / n * 16777216.0 / t.depthMax), gid);
        if (t.hasMotion != 0) {
            m /= n;    // target pixels -> LCD pixels: column against y (flipped by the transfer), row against x
            lcdMotion.write(float4((t.flip != 0 ? m.y : -m.y) / t.scaleY, -m.x / t.scaleX, 0, 0), gid);
            lcdReactive.write(float4(r), gid);
            lcdLayer.write(ui / n, gid);
        }
    }

    // Composites the UI layer into its target once the LCD image is taken (target.rgb = layer.rgb + target.rgb * T by blending),
    // so the guest's own copy of the frame still shows the UI.
    fragment float4 mergeLayer(UploadVaryings in [[stage_in]], texture2d<float, access::read> layer [[texture(0)]]) {
        return layer.read(uint2(in.position.xy));
    }
    """
}
