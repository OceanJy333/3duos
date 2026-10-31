// Input: local game files and files selected in the document picker.
// Output: a sorted library under Documents/games, with each game's title and icon from its cartridge.
// Pos: standalone app game library.

import UIKit

struct GameLibrary {
    private let extensions = ["3ds", "cxi", "cci"]
    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("games", isDirectory: true)
    }

    func games() throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func importGames(_ urls: [URL]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
            guard extensions.contains(url.pathExtension.lowercased()) else {
                throw ImportError.unsupported(url.lastPathComponent)
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let target = directory.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw ImportError.exists(url.lastPathComponent)
            }
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    // Title (Traditional Chinese, then English, then any language), icon and product code shown in the library.
    func info(_ url: URL) -> LibraryGameInfo {
        do {
            let cartridge = try CartridgeReader.read(url: url)
            let titles = cartridge.icon?.titles ?? []
            let title = (titles.count > 11 && !titles[11].short.isEmpty ? titles[11].short :
                         titles.count > 1 && !titles[1].short.isEmpty ? titles[1].short :
                         titles.first(where: { !$0.short.isEmpty })?.short) ?? ""
            return LibraryGameInfo(title: title, icon: cartridge.icon.flatMap { Self.icon($0.pixels) }, detail: cartridge.productCode)
        } catch {
            return LibraryGameInfo(title: "", icon: nil, detail: error.localizedDescription)
        }
    }

    private static func icon(_ pixels: [UInt16]) -> UIImage? {
        var rgba = [UInt8]()
        rgba.reserveCapacity(pixels.count * 4)
        for pixel in pixels {
            let r = UInt8((pixel >> 11) & 31), g = UInt8((pixel >> 5) & 63), b = UInt8(pixel & 31)
            rgba.append(contentsOf: [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255])
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 48, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image).withRenderingMode(.alwaysOriginal)
    }

    private enum ImportError: LocalizedError {
        case unsupported(String), exists(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "\(name) is not a .3ds, .cxi, or .cci game."
            case .exists(let name): return "\(name) is already in the library."
            }
        }
    }
}
