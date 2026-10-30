// input: the DSP configuration block, intermediate-mix samples the game may edit, and the three source mixes of a frame.
// output: the final 160-sample stereo frame for shared memory and the host speaker, plus aux-bus samples back to the game.
// pos: final mixer of the HLE audio DSP (follows Citra/Cytrus audio_core/hle/mixers.cpp; delay and reverb effects are not run).
import AVFoundation
import CoreAudio

final class AudioMixer {
    private var volume: [Float] = [0, 0, 0], auxEnabled = [false, false], mono = false

    // `config` is the 196-byte DspConfiguration; returns true when its dirty word must be cleared.
    func parse(_ c: [UInt8]) -> Bool {
        let dirty = le32(c, 0)
        guard dirty != 0 else { return false }
        func bit(_ n: Int) -> Bool { dirty & 1 << n != 0 }
        if bit(8) { auxEnabled[0] = le16(c, 0x28) != 0 }
        if bit(9) { auxEnabled[1] = le16(c, 0x2A) != 0 }
        if bit(16) { volume[0] = Float(bitPattern: le32(c, 4)) }
        if bit(24) { volume[1] = Float(bitPattern: le32(c, 8)) }
        if bit(25) { volume[2] = Float(bitPattern: le32(c, 0xC)) }
        if bit(26) { mono = le16(c, 0x16) == 0 }
        return true
    }

    // Mixes 1 and 2 go out to the game when their aux bus is on and come back edited one frame later.
    func mix(_ mixes: [[SIMD4<Int32>]], auxIn: [UInt8], auxOut: inout [UInt8]) -> StereoFrame {
        var buses = mixes
        for bus in 0..<2 where auxEnabled[bus] {
            for i in 0..<samplesPerFrame {
                for ch in 0..<4 {
                    let o = bus * 2560 + (ch * samplesPerFrame + i) * 4, v = UInt32(bitPattern: mixes[bus + 1][i][ch])
                    for k in 0..<4 { auxOut[o + k] = UInt8(truncatingIfNeeded: v >> (k * 8)) }
                }
            }
            buses[bus + 1] = (0..<samplesPerFrame).map { i in SIMD4((0..<4).map { ch in Int32(bitPattern: le32(auxIn, bus * 2560 + (ch * samplesPerFrame + i) * 4)) }) }
        }
        func clamp(_ v: Float) -> Int32 { Int32(min(max(v, -32768), 32767)) }
        return (0..<samplesPerFrame).map { i in
            var l: Int32 = 0, r: Int32 = 0
            for m in 0..<3 {
                let s = SIMD4<Float>(buses[m][i]) * volume[m]
                if mono { let v = clamp((s[0] + s[1] + s[2] + s[3]) / 2); l += v; r += v } else { l += clamp(s[0] + s[2]); r += clamp(s[1] + s[3]) }
                l = min(max(l, -32768), 32767); r = min(max(r, -32768), 32767)
            }
            return (Int16(l), Int16(r))
        }
    }
}

// Plays DSP frames on the host through a ring of stereo frames. Playback starts (and restarts after running dry) only
// once ~100 ms is queued, so emulation jitter does not turn into gaps; when the core runs ahead the oldest audio is dropped.
final class AudioOutput {
    static let sampleRate = 32_728.498
    private static let capacity = 8_192, prebuffer = 3_200
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: capacity * 2), read = 0, count = 0, playing = false

    init() {
        #if os(iOS)
        // A game plays through the silent switch, like video; `.ambient` followed the switch and left the game mute.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self), right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            guard let self else { return noErr }
            self.lock.lock()
            if !self.playing, self.count >= Self.prebuffer { self.playing = true }
            for i in 0..<Int(frames) {
                guard self.playing, self.count > 0 else { left[i] = 0; right[i] = 0; self.playing = false; continue }
                left[i] = self.ring[self.read * 2]; right[i] = self.ring[self.read * 2 + 1]
                self.read = (self.read + 1) % Self.capacity; self.count -= 1
            }
            self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func push(_ frame: StereoFrame) {
        lock.lock()
        for sample in frame {
            if count == Self.capacity { read = (read + 1) % Self.capacity; count -= 1 }
            let write = (read + count) % Self.capacity
            ring[write * 2] = Float(sample.0) / 32768; ring[write * 2 + 1] = Float(sample.1) / 32768
            count += 1
        }
        lock.unlock()
    }

    deinit { engine.stop() }
}
