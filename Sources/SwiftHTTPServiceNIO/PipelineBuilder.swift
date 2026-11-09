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
            let identity = ConnectionIdentity()
            guard let tls else {
                try addHTTP1(to: operations, context: context, identity: identity)
                try addProxyProtocolHandler(to: operations, context: context, identity: identity)
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
                    case .http1: try addHTTP1(to: channel.pipeline.syncOperations, context: context, identity: identity)
                    case .http2: try addHTTP2(to: channel.pipeline.syncOperations, context: context, identity: identity)
                    case nil: channel.close(promise: nil)
                    }
                }
            })
            try addProxyProtocolHandler(to: operations, context: context, identity: identity)
        }
    }

    /// The pipeline of a connection past the cap: the 503, and nothing else.
    ///
    /// Plaintext is answered at once without reading. Over TLS the handshake is done first (a peer cannot be given an
    /// answer before it), and then the version it negotiated decides the answer: HTTP/1.1 gets the same bytes as a
    /// plaintext connection, h2 gets a connection that answers its first stream and ends (``BusyStreamHandler``). The
    /// handshake is bounded by the same deadline as the answer, and the number of such connections by
    /// ``ConnectionRegistry/defaultTLSRefusalSlots``.
    static func installBusyFuture(on channel: any Channel, context: ServerContext, tls: ReloadableServerTLS?) -> EventLoopFuture<Void> {
        channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            guard let tls else {
                try operations.addHandler(BusyRefusalHandler(server: context))
                return
            }
            try tls.addHandler(to: operations)
            try operations.addHandler(HandshakeDeadline(timeout: BusyRefusalHandler.deadline))
            try operations.addHandler(ApplicationProtocolNegotiationHandler { result, channel in
                let negotiated: String?
                switch result {
                case .negotiated(let name): negotiated = name
                case .fallback: negotiated = nil
                }
                return channel.eventLoop.makeCompletedFuture {
                    let operations = channel.pipeline.syncOperations
                    switch ProtocolNegotiation.select(negotiated: negotiated, configured: context.configuration.protocols) {
                    case .http1: try operations.addHandler(BusyRefusalHandler(server: context))
                    case .http2: try addBusyHTTP2(to: operations, context: context)
                    case nil: channel.close(promise: nil)
                    }
                }
            })
        }
    }

    /// An HTTP/2 connection that answers its first stream with the busy refusal and closes.
    private static func addBusyHTTP2(to operations: ChannelPipeline.SynchronousOperations, context: ServerContext) throws {
        try operations.addHandler(RefusalDeadline(timeout: BusyRefusalHandler.deadline))
        var connection = NIOHTTP2Handler.ConnectionConfiguration()
        // One stream is all that is answered, and the answer is small.
        connection.initialSettings = [HTTP2Setting(parameter: .maxConcurrentStreams, value: 1)]
        _ = try operations.configureHTTP2Pipeline(
            mode: .server, connectionConfiguration: connection, streamConfiguration: .init(),
            inboundStreamInitializer: { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandler(BusyStreamHandler(server: context))
                }
            })
    }

    /// The same, awaited.
    static func install(on channel: any Channel, context: ServerContext, tls: ReloadableServerTLS?) async throws {
        try await installFuture(on: channel, context: context, tls: tls).get()
    }

    /// When the server reads the PROXY protocol, the handler for it goes at the very front of the pipeline: a load
    /// balancer sends its header before anything else on the connection, the TLS handshake included, and TLS adds
    /// its own handler at the front, so this has to be added after it to be ahead of it.
    private static func addProxyProtocolHandler(
        to operations: ChannelPipeline.SynchronousOperations, context: ServerContext, identity: ConnectionIdentity
    ) throws {
        guard context.configuration.forwarding == .proxyProtocol else { return }
        try operations.addHandler(ProxyProtocolHandler(configuration: context.configuration, identity: identity), position: .first)
    }

    private static func addHTTP1(to operations: ChannelPipeline.SynchronousOperations, context: ServerContext, identity: ConnectionIdentity) throws {
        let limits = context.configuration.limits
        // NIO's parser bounds the number of header fields. The size of the request line and headers is
        // bounded earlier and more tightly by HeadGuard, which sees the bytes before the parser does.
        var decoderLimits = NIOHTTPDecoderLimitConfiguration()
        decoderLimits.maxHeaderFieldCount = limits.maximumHeaderCount
        try operations.addHandler(HeadGuard(limits: limits))
        try operations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(limitConfiguration: decoderLimits)))
        try operations.addHandler(HTTPResponseEncoder())
        try operations.addHandler(ConnectionHandler(server: context, identity: identity))
    }

    private static func addHTTP2(to operations: ChannelPipeline.SynchronousOperations, context: ServerContext, identity: ConnectionIdentity) throws {
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
                    try stream.pipeline.syncOperations.addHandler(StreamHandler(server: context, identity: identity))
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

/// Closes a connection once its time is up, whatever it is doing.
// Justification: the deadline task of a busy-refused h2 connection is set in handlerAdded and cancelled in handlerRemoved, both on the channel's loop.
final class RefusalDeadline: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
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
}
