import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix
import NIOTLS
import SwiftTLSKit
@testable import SwiftHTTPServiceNIO

/// What came back on one stream.
struct H2Response: Sendable {
    var status: Int?
    var headers: [(name: String, value: String)] = []
    var body = Data()
    var ended = false
    var resetCode: Int?
    /// The stream's channel went inactive without an end or a reset: the connection was closed under it.
    var closed = false
    /// Trailers the server sent after the body, if any.
    var trailers: [(name: String, value: String)] = []

    func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
    var text: String { String(decoding: body, as: UTF8.self) }
}

/// Collects the frames of one stream.
// Justification: all state is in a NIOLockedValueBox, so the event loop writes and the test reads are serialised.
final class StreamCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    let state = NIOLockedValueBox(H2Response())

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        state.withLockedValue { response in
            switch payload {
            case .headers(let block) where response.status != nil:
                for (name, value, _) in block.headers { response.trailers.append((name, value)) }
                if block.endStream { response.ended = true }
            case .headers(let block):
                for (name, value, _) in block.headers {
                    if name == ":status" { response.status = Int(value) } else { response.headers.append((name, value)) }
                }
                if block.endStream { response.ended = true }
            case .data(let frame):
                if case .byteBuffer(let buffer) = frame.data { response.body.append(contentsOf: buffer.readableBytesView) }
                if frame.endStream { response.ended = true }
            case .rstStream(let code):
                response.resetCode = code.networkCode
            default:
                break
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLockedValue { response in
            if !response.ended && response.resetCode == nil { response.closed = true }
        }
        context.fireChannelInactive()
    }
}

/// Remembers the protocol TLS negotiated and passes everything on.
// Justification: the negotiated protocol is held in a NIOLockedValueBox.
final class NegotiationRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    let negotiated = NIOLockedValueBox<String?>(nil)
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let protocolName) = event {
            negotiated.withLockedValue { $0 = protocolName }
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// An HTTP/2 client for tests, over TLS, speaking frames.
struct H2Client: Sendable {
    let channel: any Channel
    let multiplexer: NIOHTTP2Handler.StreamMultiplexer
    let recorder: NegotiationRecorder

    var negotiatedProtocol: String? { recorder.negotiated.withLockedValue { $0 } }

    /// - Parameter lenient: Turns off this client's own HTTP/2 validation, so it can send what a conforming
    ///   client never would: that is how the server's refusals are tested.
    static func connect(
        to address: BoundAddress, group: MultiThreadedEventLoopGroup, tls: ClientTLSContext, lenient: Bool = false,
        prelude: [UInt8]? = nil
    ) async throws -> H2Client {
        let recorder = NegotiationRecorder()
        let box = NIOLockedValueBox<NIOHTTP2Handler.StreamMultiplexer?>(nil)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let operations = channel.pipeline.syncOperations
                    try tls.addHandlers(to: operations, serverHostname: "localhost")
                    // Written ahead of the TLS handshake, which adds its handlers at the front: so this goes in after it.
                    if let prelude { try operations.addHandler(PreludeWriter(bytes: prelude), position: .first) }
                    try operations.addHandler(recorder)
                    var configuration = NIOHTTP2Handler.ConnectionConfiguration()
                    if lenient {
                        configuration.headerBlockValidation = .disabled
                        configuration.contentLengthValidation = .disabled
                    }
                    let multiplexer = try operations.configureHTTP2Pipeline(
                        mode: .client, connectionConfiguration: configuration, streamConfiguration: .init(),
                        inboundStreamInitializer: { $0.eventLoop.makeSucceededVoidFuture() })
                    box.withLockedValue { $0 = multiplexer }
                }
            }
            .connect(host: address.host, port: address.port)
            .get()
        guard let multiplexer = box.withLockedValue({ $0 }) else { throw ChannelError.ioOnClosedChannel }
        return H2Client(channel: channel, multiplexer: multiplexer, recorder: recorder)
    }

    /// Sends one request on a new stream and waits for the response to end, a reset, or the timeout.
    func request(
        _ method: String, _ path: String, authority: String = "localhost", headers: [(String, String)] = [],
        body: Data? = nil, timeout: Duration = .seconds(5)
    ) async throws -> H2Response {
        let collector = StreamCollector()
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: promise) { stream in
            stream.pipeline.addHandler(collector)
        }
        let stream = try await promise.futureResult.get()
        var block = HPACKHeaders()
        block.add(name: ":method", value: method)
        block.add(name: ":scheme", value: "https")
        block.add(name: ":path", value: path)
        block.add(name: ":authority", value: authority)
        for (name, value) in headers { block.add(name: name, value: value) }
        let hasBody = body != nil
        try await stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: block, endStream: !hasBody))).get()
        if let body {
            try await stream.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: body)), endStream: true))).get()
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = collector.state.withLockedValue { $0 }
            if current.ended || current.resetCode != nil || current.closed { return current }
            try await Task.sleep(for: .milliseconds(5))
        }
        return collector.state.withLockedValue { $0 }
    }

    /// Sends exactly this header block, in this order, then the body and the trailers if given.
    func send(
        block fields: [(String, String)], body: Data? = nil, trailers: [(String, String)]? = nil,
        leaveOpen: Bool = false, timeout: Duration = .seconds(5)
    ) async throws -> H2Response {
        let collector = StreamCollector()
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: promise) { stream in
            stream.pipeline.addHandler(collector)
        }
        let stream = try await promise.futureResult.get()
        var block = HPACKHeaders()
        for (name, value) in fields { block.add(name: name, value: value) }
        let endsWithHeaders = body == nil && trailers == nil && !leaveOpen
        // The server may answer, or reset the stream, before everything has been sent. A write that then
        // finds the stream closed is not a failure of the test: the answer is whatever the collector holds.
        var writeFailure: (any Error)?
        do {
            try await stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: block, endStream: endsWithHeaders))).get()
            if let body {
                try await stream.writeAndFlush(
                    HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: body)), endStream: trailers == nil))).get()
            }
            if let trailers {
                var trailerBlock = HPACKHeaders()
                for (name, value) in trailers { trailerBlock.add(name: name, value: value) }
                try await stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: trailerBlock, endStream: true))).get()
            }
        } catch {
            writeFailure = error
        }
        if let writeFailure {
            try await Task.sleep(for: .milliseconds(50))   // let a reset or an answer that caused it arrive
            let current = collector.state.withLockedValue { $0 }
            guard current.ended || current.resetCode != nil || current.closed else { throw writeFailure }
            return current
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = collector.state.withLockedValue { $0 }
            if current.ended || current.resetCode != nil || current.closed { return current }
            try await Task.sleep(for: .milliseconds(5))
        }
        return collector.state.withLockedValue { $0 }
    }

    /// A stream the test watches as it arrives, rather than waiting for it to end.
    struct Watched: Sendable {
        let channel: any Channel
        let collector: StreamCollector

        /// What has arrived so far.
        var response: H2Response { collector.state.withLockedValue { $0 } }

        /// Waits until `condition` holds of what has arrived, or the timeout.
        func wait(timeout: Duration = .seconds(5), until condition: (H2Response) -> Bool) async throws -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition(response) { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return condition(response)
        }

        /// Resets the stream, as a client that has lost interest does.
        func reset() async {
            await withCheckedContinuation { continuation in
                channel.close().whenComplete { _ in continuation.resume() }
            }
        }
    }

    /// Sends a request and returns at once with a handle on its stream.
    ///
    /// - Parameter paused: The test does not read the stream's data, so its flow-control window is never given back.
    func open(
        _ method: String, _ path: String, headers: [(String, String)] = [], paused: Bool = false
    ) async throws -> Watched {
        let collector = StreamCollector()
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: promise) { stream in
            stream.pipeline.addHandler(collector).flatMap {
                paused ? stream.setOption(ChannelOptions.autoRead, value: false) : stream.eventLoop.makeSucceededVoidFuture()
            }
        }
        let stream = try await promise.futureResult.get()
        var block = HPACKHeaders()
        block.add(name: ":method", value: method)
        block.add(name: ":scheme", value: "https")
        block.add(name: ":path", value: path)
        block.add(name: ":authority", value: "localhost")
        for (name, value) in headers { block.add(name: name, value: value) }
        try await stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: block, endStream: true))).get()
        return Watched(channel: stream, collector: collector)
    }

    /// Waits for the connection to be closed by the server.
    func waitUntilClosed(timeout: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !channel.isActive { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return !channel.isActive
    }

    func close() async {
        await withCheckedContinuation { continuation in
            channel.close().whenComplete { _ in continuation.resume() }
        }
    }
}
