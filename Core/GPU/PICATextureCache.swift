// input: texture unit descriptions and the guest memory they point at.
// output: decoded linear RGBA8 textures, reused while the guest bytes stay unchanged.
// pos: per-renderer texture store; the rasterizer samples the decoded pixels directly.
import Foundation

final class PICADecodedTexture {
    let width: Int, height: Int
    let pixels: UnsafeMutablePointer<UInt32>
    fileprivate var raw: [UInt8]
    fileprivate var checkedAt = -1
    fileprivate(set) var version = 0      // bumped on every decode, so GPU copies know when to refresh
    fileprivate(set) var format = 0
    private var hashed: (version: Int, hash: UInt64) = (-1, 0)

    // CityHash64 of the raw level-0 bytes: the name texture packs use for this texture.
    var contentHash: UInt64 {
        if hashed.version != version { hashed = (version, raw.withUnsafeBytes { CityHash.hash64($0) }) }
        return hashed.hash
    }

    fileprivate init(width: Int, height: Int, raw: [UInt8]) {
        self.width = width; self.height = height; self.raw = raw
        pixels = .allocate(capacity: width * height)
    }
    deinit { pixels.deallocate() }
}

final class PICATextureCache {
    private struct Key: Hashable { let address: UInt32; let width: Int; let height: Int; let format: Int }
    private var entries: [Key: PICADecodedTexture] = [:]
    private var generation = 0

    // Guest memory may have changed: textures are compared with their source bytes again on next use.
    func invalidate() { generation += 1 }

    func texture(_ unit: PICATextureUnit, memory: PagedMemory) -> PICADecodedTexture? {
        let width = unit.width, height = unit.height
        guard width > 0, height > 0, width <= 1024, height <= 1024 else { return nil }
        let key = Key(address: unit.address, width: width, height: height, format: unit.format)
        if let entry = entries[key], entry.checkedAt == generation { return entry }
        let size = PICATextureFormat.byteCount(format: unit.format, width: width, height: height)
        var raw = [UInt8](repeating: 0, count: size)
        guard memory.copyOut(GPUState.virtualAddress(unit.address), to: &raw, count: size) else { return nil }
        if let entry = entries[key] {
            entry.checkedAt = generation
            if entry.raw != raw { entry.raw = raw; decode(entry, unit) }
            return entry
        }
        if entries.count > 256 { entries.removeAll() }
        let entry = PICADecodedTexture(width: width, height: height, raw: raw)
        entry.checkedAt = generation
        decode(entry, unit)
        entries[key] = entry
        return entry
    }

    private func decode(_ texture: PICADecodedTexture, _ unit: PICATextureUnit) {
        texture.version += 1
        texture.format = unit.format
        texture.raw.withUnsafeBufferPointer {
            PICATextureFormat.decode($0.baseAddress!, width: texture.width, height: texture.height, format: unit.format, into: texture.pixels)
        }
    }
}
