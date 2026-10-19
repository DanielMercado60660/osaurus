import Foundation
import Testing
@testable import OsaurusCore

@Suite("Speech API transport")
struct AudioSpeechTests {
    private func parse(_ json: String) throws -> AudioSpeechRequest {
        try AudioSpeechRequest.parse(Data(json.utf8))
    }
    @Test func defaults() throws {
        let request = try parse(#"{"model":"configured","voice":"configured","input":"Hello"}"#)
        #expect(request.format == .wav)
        #expect(request.speed == nil)
    }
    @Test func explicitFormatAndSpeed() throws {
        let request = try parse(#"{"model":"pocket-tts","voice":"alba","input":"Hi","response_format":"pcm","speed":1}"#)
        #expect(request.format == .pcm)
        #expect(request.speed == 1)
    }
    @Test(arguments: ["{}", "null", "[]", "broken",
        #"{"model":"x","voice":"v","input":" "}"#,
        #"{"model":"","voice":"v","input":"Hi"}"#,
        #"{"model":"x","voice":" ","input":"Hi"}"#,
        #"{"model":"x","voice":"v","input":"Hi","response_format":"mp3"}"#,
        #"{"model":"x","voice":"v","input":"Hi","speed":0}"#,
        #"{"model":"x","voice":"v","input":"Hi","speed":4.1}"#,
        #"{"model":"x","voice":"v","input":"Hi","speed":"1"}"#])
    func rejectsInvalid(json: String) {
        #expect(throws: AudioSpeechError.self) { try parse(json) }
    }
    @Test func bounds() throws {
        func data(_ count: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["model":"configured", "voice":"configured", "input":String(repeating:"🦖", count:count)])
        }
        #expect(try AudioSpeechRequest.parse(data(4096)).input.count == 4096)
        #expect(throws: AudioSpeechError.self) { try AudioSpeechRequest.parse(data(4097)) }
        #expect(throws: AudioSpeechError.self) { try AudioSpeechRequest.parse(Data(repeating:32,count:32769)) }
    }
    @Test func streamingWavHeader() {
        let bytes = [UInt8](SpeechPCM.wavHeader())
        #expect(bytes.count == 44)
        #expect(String(decoding:bytes[0..<4],as:UTF8.self) == "RIFF")
        #expect(Array(bytes[4..<8]) == [255,255,255,255])
        #expect(String(decoding:bytes[8..<16],as:UTF8.self) == "WAVEfmt ")
        #expect(Array(bytes[16..<24]) == [16,0,0,0,1,0,1,0])
        #expect(Array(bytes[24..<36]) == [192,93,0,0,128,187,0,0,2,0,16,0])
        #expect(String(decoding:bytes[36..<40],as:UTF8.self) == "data")
        #expect(Array(bytes[40..<44]) == [255,255,255,255])
    }
    @Test func pcmClipsAndHandlesNonfinite() {
        #expect([UInt8](SpeechPCM.encode([-2,-1,0,0.5,1,2,.nan,.infinity])) ==
            [0,128,0,128,0,0,0,64,255,127,255,127,0,0,0,0])
    }
    @Test func jsonErrorEscapesDetails() throws {
        let error = AudioSpeechError.invalid("quoted \"voice\"\ninvalid")
        let decoded = try JSONSerialization.jsonObject(with: Data(error.json.utf8)) as? [String:[String:String]]
        #expect(decoded?["error"]?["message"] == error.message)
        #expect(error.status == 400)
    }
}
