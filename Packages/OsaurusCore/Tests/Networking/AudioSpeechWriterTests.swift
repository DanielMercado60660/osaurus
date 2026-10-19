import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import OsaurusCore

@Suite("Speech HTTP streaming")
struct AudioSpeechWriterTests {
    private final class Probe: ChannelInboundHandler, Sendable {
        typealias InboundIn = HTTPServerRequestPart
    }
    private func fixture() async throws -> (NIOAsyncTestingChannel, AudioSpeechWriter) {
        let channel = await NIOAsyncTestingChannel(handler: Probe())
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        let writer = try await channel.eventLoop.submit {
            let context = try channel.pipeline.syncOperations.context(handlerType: Probe.self)
            return AudioSpeechWriter(
                context: NIOLoopBound(context, eventLoop: context.eventLoop), loop: context.eventLoop,
                version: .http1_1, cors: [])
        }.get()
        return (channel, writer)
    }
    @Test func firstFramePrecedesCompletion() async throws {
        let (channel, writer) = try await fixture()
        try await writer.write([0, 0.5], format: .wav)
        let head = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .head(let response) = head {
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "Transfer-Encoding") == "chunked")
            #expect(response.headers.first(name: "Content-Type") == "audio/wav")
        } else { Issue.record("Missing response head") }
        let first = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .body(.byteBuffer(let buffer)) = first {
            #expect(buffer.readableBytes == 48)
            #expect(Data(buffer.readableBytesView.prefix(44)) == SpeechPCM.wavHeader())
        } else { Issue.record("Missing audio body") }
        #expect(try await channel.readOutbound(as: HTTPServerResponsePart.self) == nil)
        try await writer.write([-1], format: .wav)
        let second = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .body(.byteBuffer(let buffer)) = second { #expect(buffer.readableBytes == 2) }
        else { Issue.record("WAV header repeated or missing audio") }
        try await writer.finish()
        let end = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .end = end {} else { Issue.record("Missing terminating chunk") }
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
    @Test func preAudioFailureIsJSON() async throws {
        let (channel, writer) = try await fixture()
        await writer.fail(AudioSpeechError(status: 503, code: "tts_model_not_ready", message: "Load the model."))
        let head = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .head(let response) = head {
            #expect(response.status.code == 503)
            #expect(response.headers.first(name: "Content-Type") == "application/json")
        } else { Issue.record("Missing JSON head") }
        let body = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .body(.byteBuffer(let buffer)) = body {
            #expect(String(decoding: buffer.readableBytesView, as: UTF8.self).contains("tts_model_not_ready"))
        } else { Issue.record("Missing error body") }
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
    @Test func midstreamFailureTruncatesWithoutJSONOrEnd() async throws {
        let (channel, writer) = try await fixture()
        try await writer.write([1], format: .pcm)
        _ = try await channel.readOutbound(as: HTTPServerResponsePart.self)
        let body = try #require(await channel.readOutbound(as: HTTPServerResponsePart.self))
        if case .body(.byteBuffer(let buffer)) = body { #expect(buffer.readableBytes == 2) }
        else { Issue.record("Missing PCM body") }
        await writer.fail(AudioSpeechError.invalid("failure after audio"))
        #expect(try await channel.readOutbound(as: HTTPServerResponsePart.self) == nil)
        #expect(!channel.isActive)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
    @Test func closedChannelRejectsWrites() async throws {
        let (channel, writer) = try await fixture()
        try await channel.close().get()
        await #expect(throws: (any Error).self) { try await writer.write([1], format: .pcm) }
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
    @Test func emptyStreamFailsInsteadOfSuccessfulAudio() async throws {
        let (channel, writer) = try await fixture()
        await #expect(throws: AudioSpeechError.self) { try await writer.finish() }
        _ = try await channel.finish()
    }
}
