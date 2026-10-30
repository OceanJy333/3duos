// input: a render target's guest address, size and pixel formats.
// output: a host mirror of the tiled guest buffers that the pixel backend renders into, written back on flush.
// pos: render-target storage between the guest's VRAM/FCRAM and the rasterizer; also the data a Metal backend would wrap.
import Foundation

// One guest buffer (color or depth/stencil) kept in the guest's own 8x8 Morton-tiled layout, rows stored bottom to top.
final class PICASurface {
    let address: UInt32                    // physical
    let width: Int, height: Int, bytesPerPixel: Int
    let bytes: UnsafeMutablePointer<UInt8>
    private let size: Int
    private(set) var dirty = false

    init(address: UInt32, width: Int, height: Int, bytesPerPixel: Int) {
        self.address = address; self.width = width; self.height = height; self.bytesPerPixel = bytesPerPixel
        size = width * ((height + 7) & ~7) * bytesPerPixel
        bytes = .allocate(capacity: size)
        bytes.initialize(repeating: 0, count: size)
    }
    deinit { bytes.deallocate() }

    func matches(address: UInt32, width: Int, height: Int, bytesPerPixel: Int) -> Bool {
        self.address == address && self.width == width && self.height == height && self.bytesPerPixel == bytesPerPixel
    }

    func overlaps(_ start: UInt32, length: Int) -> Bool {
        UInt64(start) < UInt64(address) + UInt64(size) && UInt64(address) < UInt64(start) + UInt64(length)
    }

    func markDirty() { dirty = true }

    func load(from memory: PagedMemory) {
        _ = memory.copyOut(GPUState.virtualAddress(address), to: bytes, count: size)
        dirty = false
    }

    func flush(to memory: PagedMemory) {
        guard dirty else { return }
        _ = memory.copyIn(GPUState.virtualAddress(address), from: bytes, count: size)
        dirty = false
    }

    // Byte offset of pixel (x, y) where y counts from the bottom row, as the guest stores it.
    @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { PICAMath.tiledIndex(x, y, width: width) * bytesPerPixel }
}

// Color formats: 0 RGBA8, 1 RGB8, 2 RGB5A1, 3 RGB565, 4 RGBA4. Pixels are packed with red in the low byte.
enum PICAColorFormat {
    @inline(__always) static func read(_ p: UnsafePointer<UInt8>, _ format: Int) -> UInt32 {
        switch format {
        case 0: return UInt32(bigEndian: UnsafeRawPointer(p).loadUnaligned(as: UInt32.self))
        case 1: return PICATextureFormat.pack(UInt32(p[2]), UInt32(p[1]), UInt32(p[0]), 255)
        default: return PICATextureFormat.pixel(format, p, 0)
        }
    }

    @inline(__always) static func write(_ p: UnsafeMutablePointer<UInt8>, _ format: Int, _ c: UInt32) {
        let r = c & 255, g = (c >> 8) & 255, b = (c >> 16) & 255, a = c >> 24
        switch format {
        case 0: UnsafeMutableRawPointer(p).storeBytes(of: c.bigEndian, as: UInt32.self)
        case 1: p[0] = UInt8(b); p[1] = UInt8(g); p[2] = UInt8(r)
        default:
            let v: UInt32
            switch format {
            case 2: v = (r >> 3) << 11 | (g >> 3) << 6 | (b >> 3) << 1 | a >> 7
            case 3: v = (r >> 3) << 11 | (g >> 2) << 5 | b >> 3
            default: v = (r >> 4) << 12 | (g >> 4) << 8 | (b >> 4) << 4 | a >> 4
            }
            p[0] = UInt8(v & 255); p[1] = UInt8(v >> 8)
        }
    }
}

// Depth formats: 0 D16, 2 D24, 3 D24S8 (stencil in the top byte). Depth is always presented as an integer of depthBits.
enum PICADepthFormat {
    @inline(__always) static func read(_ p: UnsafePointer<UInt8>, _ format: Int) -> UInt32 {
        switch format {
        case 0: return UInt32(p[0]) | UInt32(p[1]) << 8
        case 2: return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
        default: return UnsafeRawPointer(p).loadUnaligned(as: UInt32.self)
        }
    }

    @inline(__always) static func write(_ p: UnsafeMutablePointer<UInt8>, _ format: Int, depth: UInt32) {
        p[0] = UInt8(depth & 255); p[1] = UInt8((depth >> 8) & 255)
        if format != 0 { p[2] = UInt8((depth >> 16) & 255) }
    }
}

// Keeps one color and one depth surface per address for the duration of a command list.
final class PICASurfaceCache {
    private var surfaces: [PICASurface] = []
    private var loaded = Set<ObjectIdentifier>()
    var willEvict: (() -> Void)?        // lets the pixel backend land queued draws before surfaces are written back and dropped

    func beginCommandList() { loaded.removeAll() }

    func surface(address: UInt32, width: Int, height: Int, bytesPerPixel: Int, memory: PagedMemory) -> PICASurface {
        var surface = surfaces.first { $0.matches(address: address, width: width, height: height, bytesPerPixel: bytesPerPixel) }
        if surface == nil {
            if surfaces.count >= 12 { willEvict?(); flush(memory); surfaces.removeAll() }
            surface = PICASurface(address: address, width: width, height: height, bytesPerPixel: bytesPerPixel)
            surfaces.append(surface!)
        }
        if loaded.insert(ObjectIdentifier(surface!)).inserted { surface!.load(from: memory) }
        return surface!
    }

    func flush(_ memory: PagedMemory) { surfaces.forEach { $0.flush(to: memory) } }

    func isDirty(overlapping address: UInt32, length: Int) -> Bool {
        surfaces.contains { $0.dirty && $0.overlaps(address, length: length) }
    }

    // Writes back dirty surfaces overlapping a guest range (render-to-texture).
    func flush(overlapping address: UInt32, length: Int, memory: PagedMemory) {
        for s in surfaces where s.dirty && s.overlaps(address, length: length) { s.flush(to: memory) }
    }
}
