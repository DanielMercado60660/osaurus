import Foundation
import NIOCore
import NIOHTTP1

/// Serial response writer. Await every flush to avoid an unbounded HTTP write
/// queue. A synthesis failure before the first frame is still a JSON response;
/// after headers it closes without the final chunk, signalling truncation.
actor AudioSpeechWriter {
    private let context: NIOLoopBound<ChannelHandlerContext>
    private let loop: EventLoop
    private let version: HTTPVersion
    private let cors: [(String, String)]
    private var started = false

    init(context: ChannelHandlerContext, version: HTTPVersion, cors: [(String, String)]) {
        self.loop = context.eventLoop
        self.context = NIOLoopBound(context, eventLoop: context.eventLoop)
        self.version = version
        self.cors = cors
    }

    func write(_ samples: [Float], format: AudioSpeechRequest.Format) async throws {
        guard !samples.isEmpty else { return }
        try Task.checkCancellation()
        let first = !started
        started = true
        var data = first && format == .wav ? SpeechPCM.wavHeader() : Data()
        data.append(SpeechPCM.encode(samples))
        let bytes = data, ctx = context, version = version, cors = cors
        try await loop.flatSubmit { () -> EventLoopFuture<Void> in
            let c = ctx.value
            guard c.channel.isActive else { return c.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            if first {
                var headers = HTTPHeaders(cors)
                headers.add(name: "Content-Type", value: format == .wav ? "audio/wav" : "audio/pcm")
                headers.add(name: "Transfer-Encoding", value: "chunked")
                headers.add(name: "Cache-Control", value: "no-store")
                headers.add(name: "Connection", value: "close")
                c.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: version, status: .ok, headers: headers))), promise: nil)
            }
            var buffer = c.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            return c.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))))
        }.get()
    }

    func finish() async throws {
        guard started else { throw AudioSpeechError(status: 502, code: "no_audio", message: "TTS returned no audio.") }
        let ctx = context
        try await loop.flatSubmit { ctx.value.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))) }.get()
        await close()
    }

    func fail(_ error: Error) async {
        if !started && !(error is CancellationError) {
            let failure = error as? AudioSpeechError ?? AudioSpeechError(status: 502, code: "synthesis_failed", message: error.localizedDescription)
            let ctx = context, version = version, cors = cors
            try? await loop.flatSubmit {
                let c = ctx.value
                var buffer = c.channel.allocator.buffer(capacity: failure.json.utf8.count)
                buffer.writeString(failure.json)
                var headers = HTTPHeaders(cors)
                headers.add(name: "Content-Type", value: "application/json")
                headers.add(name: "Content-Length", value: String(buffer.readableBytes))
                headers.add(name: "Connection", value: "close")
                c.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: failure.status), headers: headers))), promise: nil)
                c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                return c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
            }.get()
        }
        await close()
    }

    private func close() async {
        let ctx = context
        try? await loop.flatSubmit { ctx.value.close() }.get()
    }
}
