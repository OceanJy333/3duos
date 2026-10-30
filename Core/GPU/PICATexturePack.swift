// input: a folder of Citra/Azahar-style replacement PNGs (`tex1_WxH_HASH_FORMAT[_mipN].png`, optional pack.json) and decoded
//        guest textures with their raw bytes.
// output: replacement RGBA8 images keyed by the CityHash64 of the raw level-0 bytes (Azahar's "new hash"), and dumps of
//         the textures a game uses, named the same way, so packs can be made and existing packs load unchanged.
// pos: custom texture side of the renderer; PICAMetalTextures binds a replacement in place of the decoded texture.
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class PICATexturePack {
    struct Image { let width: Int, height: Int, pixels: [UInt8] }   // RGBA8, bottom row first like decoded textures

    private var files: [UInt64: URL] = [:]
    private var loaded: [UInt64: Image?] = [:]
    private var upright = true             // pack.json "flip_png_files": false means PNG rows are stored bottom first
    private let dumpDirectory: URL?
    private var dumped: Set<UInt64> = []

    // `directory`: the pack (searched recursively); `dumpDirectory`: where to write the game's textures, nil for none.
    init(directory: URL?, dumpDirectory: URL? = nil) {
        self.dumpDirectory = dumpDirectory
        if let dumpDirectory { try? FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true) }
        guard let directory, let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            if url.lastPathComponent == "pack.json", let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                upright = (json["options"] as? [String: Any])?["flip_png_files"] as? Bool != false
            }
            guard url.pathExtension.lowercased() == "png", let hash = Self.hash(inName: url.lastPathComponent) else { continue }
            if !url.lastPathComponent.contains("_mip") || url.lastPathComponent.contains("_mip0") { files[hash] = url }
        }
    }

    var isEmpty: Bool { files.isEmpty && dumpDirectory == nil }

    // The replacement for a texture whose raw bytes hash to `hash`, loaded on first use.
    func image(_ hash: UInt64) -> Image? {
        if let cached = loaded[hash] { return cached }
        let image = files[hash].flatMap { load($0) }
        loaded[hash] = image
        return image
    }

    // Writes `pixels` (RGBA8, bottom row first) once per hash, as an upright PNG.
    func dump(hash: UInt64, width: Int, height: Int, format: Int, pixels: UnsafePointer<UInt32>) {
        guard let dumpDirectory, dumped.insert(hash).inserted else { return }
        let url = dumpDirectory.appendingPathComponent(String(format: "tex1_%dx%d_%016llX_%d_mip0.png", width, height, hash, format))
        guard !FileManager.default.fileExists(atPath: url.path),
              let provider = CGDataProvider(data: Data((0..<height).flatMap { row in
                  UnsafeBufferPointer(start: UnsafeRawPointer(pixels + (height - 1 - row) * width).assumingMemoryBound(to: UInt8.self), count: width * 4) }) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func hash(inName name: String) -> UInt64? {
        let parts = name.split(separator: "_")
        guard parts.count >= 4, parts[0] == "tex1" else { return nil }
        return UInt64(parts[2], radix: 16)
    }

    private func load(_ url: URL) -> Image? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Core Graphics draws premultiplied; translucent texels are divided back to straight alpha below.
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            if upright { context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] != 0 && pixels[i + 3] != 255 {
            let a = Int(pixels[i + 3])
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }
        return Image(width: width, height: height, pixels: pixels)
    }
}
