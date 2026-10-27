// PipelineBuilder.swift
// SwiftHTTPServiceNIO
//
// The handlers of one connection, in order.

import NIOCore
import NIOHTTP1
import SwiftTLSKit

/// Builds the pipeline every connection gets: TLS (if configured), the head guard, the HTTP/1.1 decoder
/// and encoder, and the connection handler. Tests install the same pipeline on a testing channel, so what
/// they exercise is what the server runs.
enum PipelineBuilder {

    /// Adds the handlers to `channel`.
    static func installFuture(on channel: any Channel, context: ServerContext, tls: ReloadableServerTLS?) -> EventLoopFuture<Void> {
        let limits = context.configuration.limits
        // NIO's parser bounds the number of header fields. The size of the request line and headers is
        // bounded earlier and more tightly by HeadGuard, which sees the bytes before the parser does.
        var decoderLimits = NIOHTTPDecoderLimitConfiguration()
        decoderLimits.maxHeaderFieldCount = limits.maximumHeaderCount

        // The handlers are made inside the loop's own closure, so no handler crosses a thread.
        return channel.eventLoop.submit { [decoderLimits] in
            let operations = channel.pipeline.syncOperations
            // The identity current at this moment, so a connection after a reload gets the renewed one.
            if let tls { try tls.addHandler(to: operations) }
            try operations.addHandler(HeadGuard(limits: limits))
            try operations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(limitConfiguration: decoderLimits)))
            try operations.addHandler(HTTPResponseEncoder())
            try operations.addHandler(ConnectionHandler(server: context))
        }
    }

    /// The same, awaited.
    static func install(on channel: any Channel, context: ServerContext, tls: ReloadableServerTLS?) async throws {
        try await installFuture(on: channel, context: context, tls: tls).get()
    }
}
