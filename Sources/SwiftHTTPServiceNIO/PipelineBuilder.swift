// PipelineBuilder.swift
// SwiftHTTPServiceNIO
//
// The handlers of one connection, in order.

import NIOCore
import NIOHTTP1
import NIOSSL

/// Builds the pipeline every connection gets: TLS (if configured), the head guard, the HTTP/1.1 decoder
/// and encoder, and the connection handler. Tests install the same pipeline on a testing channel, so what
/// they exercise is what the server runs.
enum PipelineBuilder {

    /// Adds the handlers to `channel`.
    static func installFuture(on channel: any Channel, context: ServerContext, tls: NIOSSLContext?) -> EventLoopFuture<Void> {
        let limits = context.configuration.limits
        var decoderLimits = NIOHTTPDecoderLimitConfiguration()
        decoderLimits.maxHeaderFieldSize = limits.maximumHeaderBytes
        decoderLimits.maxHeaderListSize = limits.maximumHeaderBytes
        decoderLimits.maxHeaderFieldCount = limits.maximumHeaderCount

        // The handlers are made inside the loop's own closure, so no handler crosses a thread.
        return channel.eventLoop.submit { [decoderLimits] in
            let operations = channel.pipeline.syncOperations
            if let tls { try operations.addHandler(NIOSSLServerHandler(context: tls)) }
            try operations.addHandler(HeadGuard(limits: limits))
            try operations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(
                leftOverBytesStrategy: .dropBytes, informationalResponseStrategy: .drop, limitConfiguration: decoderLimits)))
            try operations.addHandler(HTTPResponseEncoder())
            try operations.addHandler(ConnectionHandler(server: context))
        }
    }

    /// The same, awaited.
    static func install(on channel: any Channel, context: ServerContext, tls: NIOSSLContext?) async throws {
        try await installFuture(on: channel, context: context, tls: tls).get()
    }
}
