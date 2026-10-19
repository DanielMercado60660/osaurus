import Foundation
import Accelerate

/// pipecat smart-turn @4786657e / WhisperFeatureExtractor(chunk_length=8).
/// Mono float PCM at 16 kHz; last 8 seconds, LEFT zero padding, normalize the
/// entire padded window with variance + 1e-7, centered reflect STFT, drop frame
/// 800. Output is mel-major [80, 800]. No app or model dependencies.
enum SmartTurnFeatures {
    static let sampleRate = 16_000
    static let sampleCount = 128_000
    static let frames = 800
    static let mels = 80
    static let fftSize = 400
    static let hop = 160
    private static let bins = 201
    static func padded(_ samples: [Float]) -> [Float] {
        let tail = samples.suffix(sampleCount)
        return [Float](repeating: 0, count: sampleCount - tail.count) + tail
    }
    private static let window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / 400)) }
    // A batched DFT via Accelerate BLAS supports the exact 400-point transform
    // without rounding to a power of two. Tables are [sample, frequency].
    private static let realBasis = (0..<fftSize).flatMap { n in
        (0..<bins).map { k in Float(cos(2 * .pi * Double(n * k) / 400)) }
    }
    private static let imaginaryBasis = (0..<fftSize).flatMap { n in
        (0..<bins).map { k in Float(-sin(2 * .pi * Double(n * k) / 400)) }
    }
    static func hzToMel(_ hz: Double) -> Double {
        hz < 1000 ? 3 * hz / 200 : 15 + log(hz / 1000) * 27 / log(6.4)
    }
    static func melToHz(_ mel: Double) -> Double {
        mel < 15 ? 200 * mel / 3 : 1000 * exp((mel - 15) * log(6.4) / 27)
    }
    private static let filters: [Float] = {
        let points = (0..<82).map { melToHz(hzToMel(8000) * Double($0) / 81) }
        return (0..<mels).flatMap { m in
            (0..<bins).map { k in
                let hz = Double(k) * 40
                let down = (hz - points[m]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - hz) / (points[m + 2] - points[m + 1])
                return Float(max(0, min(down, up)) * 2 / (points[m + 2] - points[m]))
            }
        }
    }()
    static func extract(_ samples: [Float]) -> [Float] {
        var audio = padded(samples)
        let mean = audio.reduce(0.0) { $0 + Double($1) } / Double(sampleCount)
        let variance = audio.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(sampleCount)
        let scale = 1 / sqrt(variance + 1e-7)
        for i in audio.indices { audio[i] = Float((Double(audio[i]) - mean) * scale) }
        var framed = [Float](repeating: 0, count: frames * fftSize)
        for frame in 0..<frames {
            for n in 0..<fftSize {
                var i = frame * hop - fftSize / 2 + n
                if i < 0 { i = -i }
                if i >= sampleCount { i = 2 * (sampleCount - 1) - i }
                framed[frame * fftSize + n] = audio[i] * window[n]
            }
        }
        var real = [Float](repeating: 0, count: frames * bins)
        var imaginary = real
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(bins), Int32(fftSize),
                    1, framed, Int32(fftSize), realBasis, Int32(bins), 0, &real, Int32(bins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(bins), Int32(fftSize),
                    1, framed, Int32(fftSize), imaginaryBasis, Int32(bins), 0, &imaginary, Int32(bins))
        for i in real.indices { real[i] = real[i] * real[i] + imaginary[i] * imaginary[i] }
        var mel = [Float](repeating: 0, count: mels * frames)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(mels), Int32(frames), Int32(bins),
                    1, filters, Int32(bins), real, Int32(bins), 0, &mel, Int32(frames))
        for i in mel.indices { mel[i] = log10(max(mel[i], 1e-10)) }
        let floor = (mel.max() ?? -10) - 8
        for i in mel.indices { mel[i] = (max(mel[i], floor) + 4) / 4 }
        return mel
    }
}
