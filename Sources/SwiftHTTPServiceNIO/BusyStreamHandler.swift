// BusyStreamHandler.swift
// SwiftHTTPServiceNIO
//
// The h2 half of the busy refusal over TLS: one answer on the first stream, then the connection ends.

import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import SwiftHTTPService

/// Answers the first stream of an HTTP/2 connection past the cap with the `503` and closes the connection.
///
/// The connection itself (preface, SETTINGS, flow control) is the library's, so what this is, is a stream handler:
/// it reads nothing but the arrival of the request's head, whose contents are never looked at, and the request's
/// body is dropped. The whole connection is bounded by ``RefusalDeadline``, so a peer that never opens a stream
/// holds a slot for at most that long, and the slots themselves are few (``ConnectionRegistry/defaultTLSRefusalSlots``).
// Justification: a channel handler is confined to its event loop; `answered` is touched only there.
final class BusyStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let server: ServerContext
    private var answered = false

    init(server: ServerContext) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .headers = unwrapInboundIn(data), !answered else { return }
        answered = true
        let peer = context.channel.parent?.remoteAddress?.ipAddress
        let response = server.response(for: .serviceUnavailable, about: RefusalContext(peer: peer, remote: peer, version: .http2))
        let prepared = ResponseRules.prepare(response)
        var block = HPACKHeaders()
        block.add(name: ":status", value: String(prepared.code))
        for field in prepared.fields { block.add(name: field.name.rawName.lowercased(), value: field.value) }
        block.add(name: "date", value: HTTPDate.string(for: Date()))
        if prepared.hasBody { block.add(name: "content-length", value: String(prepared.body.count)) }

        let written = context.eventLoop.makePromise(of: Void.self)
        let parent = context.channel.parent
        written.futureResult.whenComplete { _ in
            // The answer is on the connection: say goodbye, then close. The close follows the GOAWAY, so the peer reads both.
            parent?.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)))
                .whenComplete { _ in parent?.close(promise: nil) }
        }
        if prepared.hasBody && !prepared.body.isEmpty {
            context.write(wrapOutboundOut(.headers(.init(headers: block, endStream: false))), promise: nil)
            context.writeAndFlush(
                wrapOutboundOut(.data(.init(data: .byteBuffer(ByteBuffer(bytes: prepared.body)), endStream: true))), promise: written)
        } else {
            context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: block, endStream: true))), promise: written)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.channel.parent?.close(promise: nil)
    }
}
