// BusyRefusalHandler.swift
// SwiftHTTPServiceNIO
//
// What a connection past the cap is given: one fixed answer, written without reading, and a short life.

import Foundation
import HTTPTypes
import NIOCore
import SwiftHTTPService

/// Tells one connection that the server is busy, then closes it.
///
/// The answer is written as soon as the connection opens and **nothing is read from the peer**: no request line is
/// parsed, so a refused connection costs the server no parser state, no buffer and no handler task. That is also
/// why the record the hooks are given for it has a peer and no request line.
///
/// Three things keep the refusal from being a way to hurt the server:
///
/// - the number of refusals in progress is capped (``ConnectionRegistry``), and a connection past that cap is closed
///   with nothing written;
/// - the whole life of a refused connection is bounded by ``deadline``, whether or not the peer reads, so a peer
///   that never reads (and so never lets the write complete) holds a slot for that long and no longer;
/// - after the answer is written the output side is shut down and the connection is left to drain, so that the
///   peer reads the answer to the end. A close with unread request bytes still in the receive buffer sends a reset,
///   and a reset can destroy a response that has not yet been read.
// Justification: a channel handler is confined to its event loop; the scheduled task is touched only there.
final class BusyRefusalHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    /// How long a refused connection may live, from the moment it opens.
    static let deadline: TimeAmount = .seconds(2)

    private let server: ServerContext
    private var started = false
    private var timer: Scheduled<Void>?

    init(server: ServerContext) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { begin(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        begin(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Drained and dropped: the request of a refused connection is never read.
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelTimer()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelTimer()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelShouldQuiesceEvent {
            // Shutdown has begun: a refusal has nothing in progress worth finishing.
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    // MARK: The refusal

    private func begin(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: Self.deadline) { loopContext.value.close(promise: nil) }

        let peer = context.remoteAddress?.ipAddress
        // No PROXY header or X-Forwarded-For has been read, so the client is the peer.
        let response = server.response(for: .serviceUnavailable, about: RefusalContext(peer: peer, remote: peer))
        let wire = Self.bytes(of: response)
        let finished = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(NIOAny(ByteBuffer(bytes: wire)), promise: finished)
        finished.futureResult.whenComplete { _ in
            // Output closed, input left open: the peer reads the answer and then ends the connection, or the deadline does.
            loopContext.value.close(mode: .output, promise: nil)
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// The response as HTTP/1.1 bytes: status line, the handler's fields, the transport's own, the body.
    static func bytes(of response: Response) -> [UInt8] {
        let prepared = ResponseRules.prepare(response)
        var head = "HTTP/1.1 \(prepared.code) \(ResponseRules.wireStatus(code: prepared.code).reasonPhrase)\r\n"
        for field in prepared.fields { head += "\(field.name.rawName): \(field.value)\r\n" }
        head += "Date: \(HTTPDate.string(for: Date()))\r\n"
        head += "Connection: close\r\n"
        if prepared.hasBody { head += "Content-Length: \(prepared.body.count)\r\n" }
        head += "\r\n"
        var bytes = Array(head.utf8)
        if prepared.hasBody { bytes.append(contentsOf: prepared.body) }
        return bytes
    }
}
