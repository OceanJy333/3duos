// input: one source's 192-byte configuration and 16 ADPCM coefficients from DSP shared memory, plus guest RAM for sample data.
// output: one 160-sample stereo frame, its gains into the three intermediate mixes, and the 12-byte status the game waits on.
// pos: one of the 24 voices of the HLE audio DSP (behaviour follows Citra/Cytrus audio_core/hle/source.cpp).
import Foundation

// The DSP keeps 32-bit values with their 16-bit halves swapped.
func dspWord(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o + 2]) | UInt32(b[o + 3]) << 8 | UInt32(b[o]) << 16 | UInt32(b[o + 1]) << 24 }
func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(le16(b, o)) | UInt32(le16(b, o + 2)) << 16 }

typealias StereoFrame = [(Int16, Int16)]
let samplesPerFrame = 160

final class AudioSource {
    enum Format: UInt16 { case pcm8 = 0, pcm16 = 1, adpcm = 2 }

    struct Buffer {
        var address: UInt32, length: UInt32, adpcmPS: UInt8, adpcmYN: (Int16, Int16), adpcmDirty: Bool
        var looping: Bool, id: UInt16, stereo: Bool, format: Format, fromQueue: Bool, playPosition: UInt32, played = false
    }

    private(set) var frame = StereoFrame(repeating: (0, 0), count: samplesPerFrame)
    private var enabled = false, syncCount: UInt16 = 0, rate: Float = 1, interpolate = true
    private var gains = [[Float]](repeating: [0, 0, 0, 0], count: 3), rampStart = [[Float]](repeating: [0, 0, 0, 0], count: 3)
    private var ramping = [false, false, false]
    private var coefficients = [Int16](repeating: 0, count: 16), yn1: Int16 = 0, yn2: Int16 = 0
    private var stereo = false, format = Format.pcm16
    private var queue: [Buffer] = []                    // played lowest buffer id first
    private var samples: [(Int16, Int16)] = [], cursor = 0
    private var currentId: UInt16 = 0, lastId: UInt16 = 0, bufferUpdate = false
    private var history: ((Int16, Int16), (Int16, Int16)) = ((0, 0), (0, 0)), fraction: UInt64 = 0
    private var filters = SourceFilters()

    func reset() {
        enabled = false; syncCount = 0; rate = 1; interpolate = true; queue = []; samples = []; cursor = 0
        gains = [[Float]](repeating: [0, 0, 0, 0], count: 3); rampStart = gains; ramping = [false, false, false]
        currentId = 0; lastId = 0; bufferUpdate = false; history = ((0, 0), (0, 0)); fraction = 0; filters = SourceFilters()
    }

    // Applies the dirty fields of `config`; returns true when the caller must clear the dirty word in shared memory.
    func parse(_ c: [UInt8], coefficients raw: [UInt8]) -> Bool {
        let dirty = le32(c, 0)
        guard dirty != 0 else { return false }
        func bit(_ n: Int) -> Bool { dirty & 1 << n != 0 }
        if bit(29) { reset() }
        if bit(4) { queue = [] }
        if bit(16) { enabled = c[0xA0] != 0 }
        if bit(28) { syncCount = le16(c, 0xA2) }
        if bit(18) { let r = Float(bitPattern: le32(c, 0x34)); rate = r > 0 ? r : 1 }
        if bit(2) { coefficients = (0..<16).map { Int16(bitPattern: le16(raw, $0 * 2)) } }
        for mix in 0..<3 where bit(25 + mix) {
            rampStart[mix] = gains[mix]; ramping[mix] = true
            gains[mix] = (0..<4).map { Float(bitPattern: le32(c, 4 + mix * 16 + $0 * 4)) }
        }
        if bit(22) { filters.enable(simple: c[0x3A] & 1 != 0, biquad: c[0x3A] & 2 != 0) }
        if bit(23) { filters.simple = (Int32(Int16(bitPattern: le16(c, 0x3C))), Int32(Int16(bitPattern: le16(c, 0x3E)))) }
        if bit(24) { filters.biquad = (0..<5).map { Int32(Int16(bitPattern: le16(c, 0x40 + $0 * 2))) } }
        if bit(17) { interpolate = c[0x38] != 2 }
        let flags1 = le16(c, 0xB4)
        if bit(0) || bit(30) { format = Format(rawValue: flags1 >> 2 & 3) ?? .pcm16 }
        if bit(1) || bit(30) { stereo = flags1 & 3 == 2 }
        let playPosition = bit(21) ? dspWord(c, 0xA4) : 0
        if bit(3), format == .pcm16, currentAddress != 0 {
            // A looping buffer was extended in place: reread it with the new length from where playback is.
            currentLength = dspWord(c, 0xB0)
            reload(from: cursor)
        }
        if bit(30), Int32(bitPattern: dspWord(c, 0xB0)) >= 0 {
            let flags2 = le16(c, 0xBC)
            enqueue(Buffer(address: dspWord(c, 0xAC), length: dspWord(c, 0xB0), adpcmPS: c[0xB6],
                           adpcmYN: (Int16(bitPattern: le16(c, 0xB8)), Int16(bitPattern: le16(c, 0xBA))), adpcmDirty: flags2 & 1 != 0,
                           looping: flags2 & 2 != 0, id: le16(c, 0xBE), stereo: stereo, format: format, fromQueue: false, playPosition: playPosition))
        }
        if bit(19) {
            let mask = le16(c, 0x4A)
            for i in 0..<4 where mask & 1 << i != 0 {
                let o = 0x4C + i * 20
                guard Int32(bitPattern: dspWord(c, o + 4)) >= 0 else { continue }
                enqueue(Buffer(address: dspWord(c, o), length: dspWord(c, o + 4), adpcmPS: c[o + 8],
                               adpcmYN: (Int16(bitPattern: le16(c, o + 0xA)), Int16(bitPattern: le16(c, o + 0xC))), adpcmDirty: c[o + 0xE] != 0,
                               looping: c[o + 0xF] != 0, id: le16(c, o + 0x10), stereo: stereo, format: format, fromQueue: true, playPosition: 0))
            }
        }
        return true
    }

    private func enqueue(_ buffer: Buffer) {
        queue.insert(buffer, at: queue.firstIndex { $0.id > buffer.id } ?? queue.count)
    }

    // Set by the game through the dirty word; a looping PCM16 buffer may also be rewritten while it plays.
    private var currentAddress: UInt32 = 0, currentLength: UInt32 = 0, currentLooping = false, currentFormat = Format.pcm16, currentStereo = false
    weak var memory: PagedMemory?

    private func reload(from start: Int) {
        let channels = currentStereo ? 2 : 1, count = Int(currentLength) - start
        guard count > 0, let memory, let bytes = try? memory.readBytes(GPUState.virtualAddress((currentAddress & ~3) + UInt32(start * channels * 2)), count: count * channels * 2) else { return }
        samples = Array(repeating: (0, 0), count: start) + Self.pcm16(bytes, stereo: currentStereo, count: count)
        cursor = start
    }

    // The game may rewrite a looping PCM16 buffer while it plays; reread just the samples this frame can consume.
    private func refresh() {
        let channels = currentStereo ? 2 : 1, count = min(samples.count - cursor, Int(Float(samplesPerFrame) * rate) + 4)
        guard let memory, let bytes = try? memory.readBytes(GPUState.virtualAddress((currentAddress & ~3) + UInt32(cursor * channels * 2)), count: count * channels * 2) else { return }
        samples.replaceSubrange(cursor..<cursor + count, with: Self.pcm16(bytes, stereo: currentStereo, count: count))
    }

    private func dequeue() -> Bool {
        guard !queue.isEmpty, let memory else { return false }
        var buffer = queue.removeFirst()
        if buffer.adpcmDirty { yn1 = buffer.adpcmYN.0; yn2 = buffer.adpcmYN.1 }
        let channels = buffer.stereo ? 2 : 1, count = Int(buffer.length)
        let size = buffer.format == .adpcm ? (count + 13) / 14 * 8 : count * channels * (buffer.format == .pcm8 ? 1 : 2)
        let bytes = (try? memory.readBytes(GPUState.virtualAddress(buffer.address & ~3), count: size)) ?? []
        switch buffer.format {
        case _ where bytes.count < size: samples = []
        case .pcm8: samples = (0..<count).map { i in (Int16(Int8(bitPattern: bytes[i * channels])) << 8, Int16(Int8(bitPattern: bytes[i * channels + channels - 1])) << 8) }
        case .pcm16: samples = Self.pcm16(bytes, stereo: buffer.stereo, count: count)
        case .adpcm: samples = decodeADPCM(bytes, count: count)
        }
        cursor = buffer.played ? 0 : min(Int(buffer.playPosition), samples.count)
        currentAddress = buffer.address; currentLength = buffer.length; currentLooping = buffer.looping
        currentFormat = buffer.format; currentStereo = buffer.stereo
        currentId = buffer.id; lastId = 0
        bufferUpdate = buffer.fromQueue && !buffer.played
        if buffer.looping { buffer.played = true; enqueue(buffer) }
        return true
    }

    private static func pcm16(_ b: [UInt8], stereo: Bool, count: Int) -> [(Int16, Int16)] {
        (0..<count).map { i in
            let l = Int16(bitPattern: le16(b, i * (stereo ? 4 : 2)))
            return (l, stereo ? Int16(bitPattern: le16(b, i * 4 + 2)) : l)
        }
    }

    // GC-ADPCM: 8-byte frames of 14 four-bit samples, with a second-order predictor in 11-bit fixed point.
    private func decodeADPCM(_ data: [UInt8], count: Int) -> [(Int16, Int16)] {
        var out: [(Int16, Int16)] = [], y1 = Int(yn1), y2 = Int(yn2)
        out.reserveCapacity(count)
        for frame in 0..<(count + 13) / 14 {
            let header = Int(data[frame * 8]), scale = 1 << (header & 0xF), index = (header >> 4) & 7
            let c1 = Int(coefficients[index * 2]), c2 = Int(coefficients[index * 2 + 1])
            for i in 0..<14 where out.count < count {
                let byte = Int(data[frame * 8 + 1 + i / 2]), nibble = i % 2 == 0 ? byte >> 4 : byte & 0xF
                let value = min(max((((nibble >= 8 ? nibble - 16 : nibble) * scale) << 11 + 0x400 + c1 * y1 + c2 * y2) >> 11, -32768), 32767)
                y2 = y1; y1 = value
                out.append((Int16(value), Int16(value)))
            }
        }
        yn1 = Int16(y1); yn2 = Int16(y2)
        return out
    }

    func tick() {
        frame = StereoFrame(repeating: (0, 0), count: samplesPerFrame)
        guard enabled else { return }
        if cursor < samples.count, currentLooping, currentFormat == .pcm16, currentAddress != 0 { refresh() }
        if cursor >= samples.count {
            if dequeue() { return }
            enabled = false; bufferUpdate = true; lastId = currentId; currentId = 0
            return
        }
        var out = 0
        while out < samplesPerFrame {
            if cursor >= samples.count, !dequeue() { break }
            resample(&out)
        }
        filters.process(&frame)
    }

    // Steps over [history, samples...] in 24-bit fixed point, as AudioInterp::Linear / None do.
    private func resample(_ out: inout Int) {
        let scale: UInt64 = 1 << 24, step = UInt64(rate * Float(scale)), available = samples.count - cursor + 2
        func input(_ i: Int) -> (Int16, Int16) { i == 0 ? history.0 : i == 1 ? history.1 : samples[cursor + i - 2] }
        var position = fraction, index = 0
        while out < samplesPerFrame {
            index = Int(position / scale)
            if index + 2 >= available { index = available - 2; break }
            let x0 = input(index), x1 = input(index + 1), f = Int64(position & (scale - 1))
            frame[out] = interpolate
                ? (Int16(truncatingIfNeeded: Int64(x0.0) + f * (Int64(x1.0) - Int64(x0.0)) / Int64(scale)),
                   Int16(truncatingIfNeeded: Int64(x0.1) + f * (Int64(x1.1) - Int64(x0.1)) / Int64(scale)))
                : x0
            out += 1
            position += step
        }
        history = (input(index), input(index + 1))
        fraction = position - UInt64(index) * scale
        cursor += index
    }

    func mix(into mixes: inout [[SIMD4<Int32>]]) {
        guard enabled else { rampStart = gains; ramping = [false, false, false]; return }
        for m in 0..<3 {
            let g = gains[m], s = rampStart[m]
            for i in 0..<samplesPerFrame {
                let p = ramping[m] ? Float(i) / Float(samplesPerFrame - 1) : 1
                let l = Float(frame[i].0), r = Float(frame[i].1)
                func gain(_ k: Int) -> Float { s[k] + (g[k] - s[k]) * p }
                mixes[m][i] &+= SIMD4(Int32(gain(0) * l), Int32(gain(1) * r), Int32(gain(2) * l), Int32(gain(3) * r))
            }
            if ramping[m] { rampStart[m] = g; ramping[m] = false }
        }
    }

    var status: [UInt8] {
        let position = UInt32(cursor)
        defer { bufferUpdate = false }
        return [enabled ? 1 : 0, bufferUpdate ? 1 : 0, UInt8(syncCount & 0xFF), UInt8(syncCount >> 8),
                UInt8(position >> 16 & 0xFF), UInt8(position >> 24), UInt8(position & 0xFF), UInt8(position >> 8 & 0xFF),
                UInt8(currentId & 0xFF), UInt8(currentId >> 8), UInt8(lastId & 0xFF), UInt8(lastId >> 8)]
    }
}

// First-order (15-bit) and biquad (14-bit) fixed-point filters per source.
struct SourceFilters {
    var simple: (b0: Int32, a1: Int32) = (1 << 15, 0)
    var biquad: [Int32] = [0, 0, 0, 0, 1 << 14]          // a2, a1, b2, b1, b0
    private var simpleOn = false, biquadOn = false
    private var sy1: (Int32, Int32) = (0, 0), bx = [[Int32]](repeating: [0, 0], count: 2), by = [[Int32]](repeating: [0, 0], count: 2)

    mutating func enable(simple s: Bool, biquad b: Bool) {
        simpleOn = s; biquadOn = b
        if !s { simple = (1 << 15, 0); sy1 = (0, 0) }
        if !b { biquad = [0, 0, 0, 0, 1 << 14]; bx = [[0, 0], [0, 0]]; by = [[0, 0], [0, 0]] }
    }

    mutating func process(_ frame: inout StereoFrame) {
        guard simpleOn || biquadOn else { return }
        func clamp(_ v: Int32) -> Int32 { min(max(v, -32768), 32767) }
        for i in frame.indices {
            var x = [Int32(frame[i].0), Int32(frame[i].1)]
            if simpleOn {
                let y = [clamp((simple.b0 * x[0] + simple.a1 * sy1.0) >> 15), clamp((simple.b0 * x[1] + simple.a1 * sy1.1) >> 15)]
                sy1 = (y[0], y[1]); x = y
            }
            if biquadOn {
                let y = (0..<2).map { c in clamp((biquad[4] * x[c] + biquad[3] * bx[0][c] + biquad[2] * bx[1][c] + biquad[1] * by[0][c] + biquad[0] * by[1][c]) >> 14) }
                bx[1] = bx[0]; bx[0] = x; by[1] = by[0]; by[0] = y; x = y
            }
            frame[i] = (Int16(x[0]), Int16(x[1]))
        }
    }
}
