import AVFoundation
import Foundation

/// Synthesized whip crack: a rising whoosh, then a sharp supersonic snap.
/// Placeholder until real recorded samples land in the bundle.
final class WhipSound {
    private var players: [AVAudioPlayer] = []
    private let variants: [Data]

    init() {
        variants = (0..<4).map { WhipSound.makeCrack(seed: UInt64($0 + 1)) }
    }

    /// `force` 0...1 sets the volume.
    func play(force: Double) {
        players.removeAll { !$0.isPlaying }
        guard let data = variants.randomElement(), let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = Float(0.55 + 0.45 * min(max(force, 0), 1))
        player.play()
        players.append(player)
    }

    private static func makeCrack(seed: UInt64) -> Data {
        let rate = 44_100.0
        let whooshLen = 0.18 + Double(seed % 3) * 0.02
        let crackLen = 0.35
        let total = Int((whooshLen + crackLen) * rate)
        var rng = seed &* 0x9E37_79B9_7F4A_7C15
        func noise() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(rng % 20_000) / 10_000 - 1
        }

        var samples = [Double](repeating: 0, count: total)
        var low = 0.0, band = 0.0
        let crackStart = Int(whooshLen * rate)

        for i in 0..<total {
            let t = Double(i) / rate
            var s = 0.0
            if i < crackStart {
                // Whoosh: band-passed noise whose center frequency rises as the whip speeds up.
                let p = t / whooshLen
                let f = 300 + 2_500 * p * p
                let q = 2 * sin(Double.pi * f / rate)
                low += q * band
                let high = noise() - low - 0.5 * band
                band += q * high
                s = band * 0.35 * p * p
            } else {
                let ct = t - whooshLen
                // Snap: a few ms of broadband click, then a fast decaying crackle and a short echo.
                let click = ct < 0.004 ? (1 - ct / 0.004) * (ct < 0.0006 ? 1 : noise()) : 0
                let crackle = noise() * exp(-ct / 0.025)
                let echo = ct > 0.06 ? noise() * 0.18 * exp(-(ct - 0.06) / 0.05) : 0
                s = click * 1.0 + crackle * 0.75 + echo
            }
            samples[i] = s
        }
        // Simple high-pass so the snap stays bright, then normalize.
        var prevIn = 0.0, prevOut = 0.0
        for i in 0..<total {
            let out = 0.97 * (prevOut + samples[i] - prevIn)
            prevIn = samples[i]; prevOut = out
            samples[i] = out
        }
        let peak = samples.map(abs).max() ?? 1
        let pcm = samples.map { Int16(max(-1, min(1, $0 / peak * 0.95)) * Double(Int16.max)) }
        return wav(pcm, rate: Int(rate))
    }

    private static func wav(_ pcm: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
