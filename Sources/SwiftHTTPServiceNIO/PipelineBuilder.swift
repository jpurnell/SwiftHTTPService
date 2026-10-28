// PipelineBuilder.swift
// SwiftHTTPServiceNIO
//
// The handlers of one connection, in order.

import NIOCore
import NIOHPACK
import NIOHTTP1
import NIOHTTP2
import NIOTLS
import SwiftTLSKit

/// Builds the pipeline every connection gets. Plaintext is HTTP/1.1. With TLS, the handshake's ALPN result
/// picks HTTP/1.1 or HTTP/2, and only what the configuration offered can be picked. Tests install the same
/// pipeline on a testing channel, so what they exercise is what the server runs.
enum PipelineBuilder {

    /// Adds the handlers to `channel`.
    static func installFuture(on channel: any Channel, context: ServerContext, tls: ReloadableServerTLS?) -> EventLoopFuture<Void> {
        // The handlers are made inside the loop's own closure, so no handler crosses a thread.
        channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            guard let tls else {
                try addHTTP1(to: operations, context: context)
                return
            }
            // The identity current at this moment, so a connection after a reload gets the renewed one.
            try tls.addHandler(to: operations)
            // Until the handshake is done there is no request to time, so the idle timeout bounds it: a peer
            // that opens a connection and says nothing does not hold a slot for ever.
            try operations.addHandler(HandshakeDeadline(timeout: context.configuration.limits.idleTimeout.timeAmount))
            try operations.addHandler(ApplicationProtocolNegotiationHandler { result, channel in
                let negotiated: String?
                switch result {
                case .negotiated(let name): negotiated = name
                case .fallback: negotiated = nil
                }
                return channel.eventLoop.makeCompletedFuture {
                    switch ProtocolNegotiation.select(negotiated: negotiated, configured: context.configuration.protocols) {
                    case .http1: try addHTTP1(to: channel.pipeline.syncOperations, context: context)
                    case .http2: try addHTTP2(to: channel.pipeline.syncOperations, context: context)
                    case nil: channel.close(promise: nil)
                    }
                }
            })
        }
    }

    /// The same, awaited.
    static func install(on channel: any Channel, context: ServerContext, tls: ReloadableServerTLS?) async throws {
        try await installFuture(on: channel, context: context, tls: tls).get()
    }

    private static func addHTTP1(to operations: ChannelPipeline.SynchronousOperations, context: ServerContext) throws {
        let limits = context.configuration.limits
        // NIO's parser bounds the number of header fields. The size of the request line and headers is
        // bounded earlier and more tightly by HeadGuard, which sees the bytes before the parser does.
        var decoderLimits = NIOHTTPDecoderLimitConfiguration()
        decoderLimits.maxHeaderFieldCount = limits.maximumHeaderCount
        try operations.addHandler(HeadGuard(limits: limits))
        try operations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(limitConfiguration: decoderLimits)))
        try operations.addHandler(HTTPResponseEncoder())
        try operations.addHandler(ConnectionHandler(server: context))
    }

    private static func addHTTP2(to operations: ChannelPipeline.SynchronousOperations, context: ServerContext) throws {
        let limits = context.configuration.limits
        var connection = NIOHTTP2Handler.ConnectionConfiguration()
        connection.initialSettings = [
            HTTP2Setting(parameter: .maxConcurrentStreams, value: limits.maximumConcurrentStreams),
            HTTP2Setting(parameter: .maxHeaderListSize, value: limits.maximumHeaderBytes),
            HTTP2Setting(parameter: .initialWindowSize, value: 65535),
        ]
        // Idle connections, and the GOAWAY of a graceful shutdown, are the library's own connection management.
        // It is given no grace time: the server's own deadline (HTTPServer.performShutdown) closes whatever is
        // left when the configured grace ends, for both versions of HTTP, and a second timer would only repeat it.
        let management = NIOHTTP2ServerConnectionManagementHandler(
            eventLoop: operations.eventLoop,
            configuration: .init(maxIdleTime: limits.idleTimeout.timeAmount, maxAge: nil, maxGraceTime: nil, keepalive: nil))
        _ = try operations.configureHTTP2Pipeline(
            mode: .server, connectionConfiguration: connection, streamConfiguration: .init(),
            streamDelegate: management.http2StreamDelegate,
            inboundStreamInitializer: { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandler(StreamHandler(server: context))
                }
            })
        try operations.addHandler(management)
    }
}

/// Closes a connection whose TLS handshake has not finished in time, and takes itself out once it has.
// Justification: a channel handler is confined to its event loop; the scheduled task is touched only there.
final class HandshakeDeadline: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let timeout: TimeAmount
    private var deadline: Scheduled<Void>?

    init(timeout: TimeAmount) { self.timeout = timeout }

    func handlerAdded(context: ChannelHandlerContext) {
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: timeout) { loopContext.value.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        deadline?.cancel()
        deadline = nil
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            deadline?.cancel()
            deadline = nil
        }
        context.fireUserInboundEventTriggered(event)
    }
}
