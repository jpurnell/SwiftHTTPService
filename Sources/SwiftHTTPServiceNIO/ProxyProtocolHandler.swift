// ProxyProtocolHandler.swift
// SwiftHTTPServiceNIO
//
// Reading the PROXY protocol header, before TLS, and only from a peer that may send one.

import NIOConcurrencyHelpers
import NIOCore
import SwiftHTTPService

/// Who a connection's client is, as far as the connection can tell: set once, by the PROXY protocol handler, and
/// read by the handlers that build requests.
final class ConnectionIdentity: Sendable {
    private let named = NIOLockedValueBox<String?>(nil)

    /// The client a PROXY protocol header named, if one was read.
    var client: String? { named.withLockedValue { $0 } }

    func name(_ client: String?) { named.withLockedValue { $0 = client } }
}

extension ProxyHeader {
    /// Whether `bytes` begin with a whole header signature: the version 1 keyword or the version 2 marker.
    static func beginsWithSignature(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: v1Prefix) || bytes.starts(with: v2Signature)
    }
}

/// The first handler of a connection when the server is configured for the PROXY protocol.
///
/// A load balancer sends its header before anything else, so this runs ahead of TLS. What it does depends on who
/// is connected, because a header is only worth anything from a peer that is trusted to tell the truth:
///
/// - **A trusted peer must send one.** Bytes that are not a header, a malformed header, or one that does not
///   finish within the header timeout close the connection with nothing written.
/// - **Any other peer must not.** One that begins with a header is pretending to be a proxy, and is closed. One that
///   begins with anything else (HTTP, a TLS hello) is served as itself, its bytes passed on untouched.
///
/// Once decided the handler removes itself and passes on whatever followed the header in the same read.
// Justification: a channel handler is confined to its event loop; its state is touched only there.
final class ProxyProtocolHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let configuration: ServiceConfiguration
    private let identity: ConnectionIdentity
    private var received: [UInt8] = []
    private var leftover: [UInt8] = []
    private var deadline: Scheduled<Void>?
    private var decided = false

    init(configuration: ServiceConfiguration, identity: ConnectionIdentity) {
        self.configuration = configuration
        self.identity = identity
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Every peer has this long to show what it is: a trusted one to finish its header, any other to send enough
        // for the handler to see it is not pretending to be a proxy. Idle and handshake timers run too, but this one
        // is the header's own, and the handler is gone once it has decided.
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: configuration.limits.headerReadTimeout.timeAmount) {
            loopContext.value.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        deadline?.cancel()
        deadline = nil
        // Whatever followed the header (or, for a peer with none, everything) goes on to the next handler.
        if !leftover.isEmpty {
            let bytes = leftover
            leftover = []
            context.fireChannelRead(wrapInboundOut(ByteBuffer(bytes: bytes)))
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !decided else {
            context.fireChannelRead(data)
            return
        }
        var buffer = unwrapInboundIn(data)
        received.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        if isTrusted(context) { readHeader(context: context) } else { checkForPretender(context: context) }
    }

    private func isTrusted(_ context: ChannelHandlerContext) -> Bool {
        // A peer with no address is in no block (the empty text is in none), so it is not trusted.
        let peer = context.remoteAddress?.ipAddress ?? ""
        return configuration.trustedProxies.contains { $0.contains(peer) }
    }

    private func readHeader(context: ChannelHandlerContext) {
        switch ProxyHeader.parse(received) {
        case .needMore:
            break                      // a header is at most 107 bytes (version 1) or 16 plus a bounded body (version 2)
        case .invalid:
            context.close(promise: nil)
        case .header(let client, let consumed):
            identity.name(client)
            finish(context: context, leftover: Array(received[consumed...]))
        }
    }

    private func checkForPretender(context: ChannelHandlerContext) {
        if ProxyHeader.beginsWithSignature(received) {
            context.close(promise: nil)                                   // not trusted, and claiming to be a proxy
        } else if !ProxyHeader.couldBeginAHeader(received) {
            finish(context: context, leftover: received)                  // plain HTTP or TLS: serve it as itself
        }
        // Otherwise the bytes so far could still become a header: wait for the one that tells.
    }

    private func finish(context: ChannelHandlerContext, leftover bytes: [UInt8]) {
        decided = true
        leftover = bytes
        received = []
        // Taking itself out hands on the leftover bytes (see handlerRemoved).
        _ = context.pipeline.syncOperations.removeHandler(context: context)    // on the loop, so it completes at once
    }
}
