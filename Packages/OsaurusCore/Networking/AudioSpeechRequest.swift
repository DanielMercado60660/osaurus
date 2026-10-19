import Foundation

/// Transport-only contract. No model, player, singleton, or keychain access.
struct AudioSpeechRequest: Decodable, Sendable {
    static let maximumBodyBytes = 32_768
    enum Format: String, Decodable, Sendable { case wav, pcm }
    let model: String
    let input: String
    let voice: String
    let response_format: Format?
    let speed: Double?
    var format: Format { response_format ?? .wav }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBodyBytes else { throw AudioSpeechError.invalid("Speech request exceeds 32 KiB.") }
        let request: Self
        do { request = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw AudioSpeechError.invalid("Expected model, input and voice strings, wav or pcm response_format, and optional numeric speed.") }
        guard !request.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.input.count <= 4096 else {
            throw AudioSpeechError.invalid("input must contain 1–4096 characters.")
        }
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.model.count <= 256,
              !request.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.voice.count <= 256 else {
            throw AudioSpeechError.invalid("model and voice must contain 1–256 characters; use configured for the Mac's current selection.")
        }
        if let speed = request.speed, !speed.isFinite || !(0.25...4).contains(speed) {
            throw AudioSpeechError.invalid("speed must be between 0.25 and 4.")
        }
        return request
    }
}

struct AudioSpeechError: LocalizedError, Sendable {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
    static func invalid(_ message: String) -> Self { Self(status: 400, code: "invalid_request_error", message: message) }
    var json: String {
        let data = try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
        return String(decoding: data, as: UTF8.self)
    }
}

enum SpeechPCM {
    /// RIFF streaming convention: unknown RIFF/data lengths are 0xffffffff.
    /// Consumers must read to HTTP EOF, rather than allocate from these lengths.
    static func wavHeader() -> Data {
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
        tag("RIFF"); u32(.max); tag("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        tag("data"); u32(.max)
        return data
    }
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = sample.isFinite ? min(1, max(-1, sample)) : 0
            let bits = UInt16(bitPattern: Int16(max(-32768, min(32767, (value * 32768).rounded()))))
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        return data
    }
}
