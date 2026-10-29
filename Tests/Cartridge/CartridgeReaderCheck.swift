// input: decrypted CXI path; output: parser checks and optional 48x48 PPM icon.
// pos: standalone command-line verification for the cartridge file layer.
import Foundation

@main
struct CartridgeReaderCheck {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let cartridge = try CartridgeReader.read(url: url)
        print(String(format: "programID=%016llX product=%@ compressed=%@", cartridge.programID, cartridge.productCode, String(cartridge.codeCompressed)))
        for (name, region) in cartridge.exefs.sorted(by: { $0.key < $1.key }) {
            print("exefs=\(name) offset=\(region.offset) size=\(region.size)")
        }
        guard let icon = cartridge.icon, let code = cartridge.executable, let segments = cartridge.codeSegments else {
            fatalError("expected icon, code and code segments")
        }
        print("title[English]=\(icon.titles[1].short) title[Traditional Chinese]=\(icon.titles[11].short)")
        print(String(format: "text=%08X/%u/%u ro=%08X/%u/%u data=%08X/%u/%u", segments.text.address, segments.text.pages, segments.text.size, segments.ro.address, segments.ro.pages, segments.ro.size, segments.data.address, segments.data.pages, segments.data.size))
        print("icon=\(icon.pixels.count) codeBytes=\(try CartridgeReader.readRegion(code, from: url).count)")
        let program = try CartridgeProgramLoader.load(cartridge, from: url)
        print("decoded=\(program.text.bytes.count + program.ro.bytes.count + program.data.bytes.count) segments=\(program.text.bytes.count),\(program.ro.bytes.count),\(program.data.bytes.count) bss=\(program.bssSize) stack=\(program.stackSize)")
        if CommandLine.arguments.count > 2 {
            var data = Data("P6\n48 48\n255\n".utf8)
            for pixel in icon.pixels {
                let r = UInt8((Int(pixel >> 11) * 255) / 31)
                let g = UInt8((Int((pixel >> 5) & 63) * 255) / 63)
                let b = UInt8((Int(pixel & 31) * 255) / 31)
                data.append(contentsOf: [r, g, b])
            }
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
