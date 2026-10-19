// Standalone golden probe: compile with the production features/model sources.
// --features-only compiles without MLX when SMART_TURN_FEATURES_ONLY is defined.
import Foundation
import AVFoundation
#if !SMART_TURN_FEATURES_ONLY
import MLX
#endif

@main struct SmartTurnProbe {
    static func main() throws {
        #if !SMART_TURN_FEATURES_ONLY
        if ProcessInfo.processInfo.environment["SMART_TURN_PROBE_CPU"] == "1" {
            try Device.withDefaultDevice(.cpu) { try run() }
            return
        }
        #endif
        try run()
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { fatalError("Usage: probe MODEL_DIRECTORY WAV...") }
        #if !SMART_TURN_FEATURES_ONLY
        let model = try SmartTurnModel(directory: URL(fileURLWithPath: args[0]))
        #endif
        for path in args.dropFirst() {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                fatalError("Expected mono 16 kHz WAV")
            }
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let start = ProcessInfo.processInfo.systemUptime
            let features = SmartTurnFeatures.extract(samples)
            let featureMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try features.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: path + ".swift.f32")) }
            var row: [String: Any] = ["wav": path, "featureMs": featureMs]
            #if !SMART_TURN_FEATURES_ONLY
            let inferStart = ProcessInfo.processInfo.systemUptime
            let logit = model.logit(features: features)
            row["logit"] = logit
            row["probability"] = 1 / (1 + exp(-logit))
            row["inferenceMs"] = (ProcessInfo.processInfo.systemUptime - inferStart) * 1000
            #endif
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
