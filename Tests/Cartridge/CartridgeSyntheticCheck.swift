// input: synthetic valid and corrupted NCCH/NCSD/BLZ bytes; output: parser assertions.
// pos: standalone tests for cartridge boundaries and icon decoding.
import Foundation

@main
struct CartridgeSyntheticCheck {
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func put(_ value: UInt64, _ offset: Int, _ count: Int, _ bytes: inout Data) {
            for i in 0..<count { bytes[offset + i] = UInt8((value >> (8 * i)) & 255) }
        }
        func label(_ text: String, _ offset: Int, _ bytes: inout Data) {
            bytes.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8)
        }
        var image = Data(repeating: 0, count: 0x4000)
        label("NCCH", 0x100, &image); put(0x20, 0x104, 4, &image); put(0x04, 0x18F, 1, &image)
        put(0x40, 0x180, 4, &image); put(2, 0x1A0, 4, &image); put(0x1E, 0x1A4, 4, &image)
        label(".code", 0x400, &image); put(4, 0x40C, 4, &image)
        label("icon", 0x410, &image); put(0x200, 0x418, 4, &image); put(0x36C0, 0x41C, 4, &image)
        label("SMDH", 0x800, &image)
        put(0x0054, 0x808, 2, &image); put(0x0045, 0x80A, 2, &image); put(0x0053, 0x80C, 2, &image); put(0x0054, 0x80E, 2, &image)
        for y in 0..<48 { for x in 0..<48 {
            let xx = x % 8, yy = y % 8
            let within = (xx & 1) | ((yy & 1) << 1) | ((xx & 2) << 1) | ((yy & 2) << 2) | ((xx & 4) << 2) | ((yy & 4) << 3)
            put(UInt64(y * 48 + x), 0x800 + 0x24C0 + ((y / 8 * 6 + x / 8) * 64 + within) * 2, 2, &image)
        }}
        func read(_ data: Data, _ name: String) throws -> Cartridge {
            let url = temp.appendingPathComponent(name)
            try data.write(to: url)
            return try CartridgeReader.read(url: url)
        }
        let cartridge = try read(image, "valid.cxi")
        precondition(cartridge.icon?.titles[0].short == "TEST")
        precondition(cartridge.icon?.pixels == (0..<2304).map(UInt16.init))
        var ncsd = Data(repeating: 0, count: 0x4200)
        label("NCSD", 0x100, &ncsd); put(0x21, 0x104, 4, &ncsd)
        put(1, 0x120, 4, &ncsd); put(0x20, 0x124, 4, &ncsd)
        ncsd.replaceSubrange(0x200..<0x4200, with: image)
        let ncsdCartridge = try read(ncsd, "valid.3ds")
        precondition(ncsdCartridge.icon?.titles[0].short == "TEST")
        var failures = 0
        func rejects(_ data: Data, _ name: String) throws {
            do { _ = try read(data, name); fatalError("accepted \(name)") }
            catch is CartridgeError { failures += 1 }
        }
        var bad = image; put(0, 0x18F, 1, &bad); try rejects(bad, "encrypted.cxi")
        bad = image; put(0xFFFFFFFF, 0x1A0, 4, &bad); try rejects(bad, "exefs-range.cxi")
        bad = image; put(0, 0x418, 4, &bad); try rejects(bad, "exefs-overlap.cxi")
        bad = ncsd; put(0x22, 0x124, 4, &bad); try rejects(bad, "ncsd-range.3ds")
        bad = ncsd; put(1, 0x128, 4, &bad); put(1, 0x12C, 4, &bad); try rejects(bad, "ncsd-overlap.3ds")
        let blz = Data([0, 0xF0, 65, 66, 67, 0x10, 14, 0, 0, 8, 7, 0, 0, 0])
        let decoded = try CartridgeProgramLoader.decompress(blz)
        precondition(decoded == Data(String(repeating: "ABC", count: 7).utf8))
        do { _ = try CartridgeProgramLoader.decompress(Data([0, 0])); fatalError("accepted bad BLZ") }
        catch is CartridgeError { failures += 1 }
        print("PASS: NCCH, NCSD, 2304 icon pixels, BLZ, \(failures) invalid cases")
    }
}
