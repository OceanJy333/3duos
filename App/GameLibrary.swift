// Input: local game files and files selected in the document picker.
// Output: a sorted library under Documents/games.
// Pos: standalone app game library.

import Foundation

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
