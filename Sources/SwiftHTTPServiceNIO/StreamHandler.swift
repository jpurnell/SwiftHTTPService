// StreamHandler.swift
// SwiftHTTPServiceNIO
//
// One HTTP/2 stream: read a request, run the handler, write the response.

import Foundation
import HTTPTypes
import NIOCore
import NIOHPACK
import NIOHTTP2
import SwiftHTTPService

/// Serves the one request of an HTTP/2 stream.
///
/// The rules that do not depend on the version of HTTP are ``RequestRules`` and ``ResponseRules``, shared
/// with ``ConnectionHandler``. What is specific to HTTP/2 is here: the request comes as pseudo-headers
/// (`:method`, `:path`, `:authority`) and a stream may carry only one header block from a client, so a
/// second one (trailers) is refused. A stream is one request, so there is no keep-alive and no pipelining
/// to guard.
// Justification: a channel handler is confined to its event loop and `@unchecked Sendable` only lets NIOLoopBound hold it.
final class StreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private struct Receiving {
        var method: HTTPRequest.Method
        var target: String
        var fields: HTTPFields
        var isHead: Bool
        var body: ByteBuffer
    }

    private enum State {
        case idle
        case receiving(Receiving)
        case responding
        case done
    }

    private let server: ServerContext
    private var state: State = .idle
    private var inFlight: Task<Response, any Error>?

    init(server: ServerContext) {
        self.server = server
    }

    deinit {
        // A handler that goes away with a request still running must not leave its task behind.
        inFlight?.cancel()
    }

    // MARK: Inbound frames

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch (unwrapInboundIn(data), state) {
        case (.headers(let block), .idle):
            begin(block, context: context)
        case (.headers, .receiving):
            // A second header block from a client is trailers. They are refused until a consumer needs them.
            reset(.protocolError, context: context)
        case (.data(let frame), .receiving(var receiving)):
            guard case .byteBuffer(var chunk) = frame.data else { return }
            let limit = server.configuration.limits.maximumBodyBytes
            guard RequestRules.bodyFits(received: receiving.body.readableBytes, incoming: chunk.readableBytes, limit: limit) else {
                refuse(.bodyTooLarge, requestEnded: false, context: context)
                return
            }
            receiving.body.writeBuffer(&chunk)
            if frame.endStream {
                dispatch(receiving, context: context)
            } else {
                state = .receiving(receiving)
            }
        default:
            break
        }
    }

    // MARK: Head validation

    private func begin(_ block: HTTP2Frame.FramePayload.Headers, context: ChannelHandlerContext) {
        var method: String?
        var path: String?
        var authority: String?
        var fields = HTTPFields()
        var lengths: [String] = []
        for (name, value, _) in block.headers {
            switch name {
            case ":method": method = value
            case ":path": path = value
            case ":authority": authority = value
            case ":scheme": break
            default:
                guard !name.hasPrefix(":"), let fieldName = HTTPField.Name(name), RequestRules.isCleanFieldValue(value) else {
                    refuse(.badRequest, requestEnded: block.endStream, context: context)
                    return
                }
                if name == "content-length" { lengths.append(value) }
                fields.append(HTTPField(name: fieldName, value: value))
            }
        }
        guard let method, let verb = HTTPRequest.Method(method), let path else {
            refuse(.badRequest, requestEnded: block.endStream, context: context)
            return
        }
        // A handler reads the host from `Host`, whichever version carried the request. If both are given they
        // must agree (RFC 9113 section 8.3.1).
        if let authority, let hostName = HTTPField.Name("Host") {
            if let given = fields[hostName] {
                guard given == authority else {
                    refuse(.badRequest, requestEnded: block.endStream, context: context)
                    return
                }
            } else {
                fields.append(HTTPField(name: hostName, value: authority))
            }
        }
        var declaredLength: Int?
        if !lengths.isEmpty {
            guard lengths.count == 1, let length = RequestRules.parseLength(lengths[0]) else {
                refuse(.badRequest, requestEnded: block.endStream, context: context)
                return
            }
            declaredLength = length
        }
        // The target is checked now, before any body is read, so a refused target costs nothing.
        guard RequestRules.isAcceptableTarget(method: verb, target: path, fields: fields) else {
            refuse(.malformedTarget, requestEnded: block.endStream, context: context)
            return
        }
        if let declaredLength, !RequestRules.declaredLengthFits(declaredLength, limit: server.configuration.limits.maximumBodyBytes) {
            refuse(.bodyTooLarge, requestEnded: block.endStream, context: context)
            return
        }
        let receiving = Receiving(
            method: verb, target: path, fields: fields, isHead: verb == .head, body: context.channel.allocator.buffer(capacity: 0))
        if block.endStream {
            dispatch(receiving, context: context)
        } else {
            state = .receiving(receiving)
        }
    }

    // MARK: Running the handler

    private func dispatch(_ receiving: Receiving, context: ChannelHandlerContext) {
        let built = Result {
            try Request(
                method: receiving.method, target: receiving.target, headers: receiving.fields,
                body: Data(receiving.body.readableBytesView), remoteAddress: context.channel.parent?.remoteAddress?.ipAddress)
        }
        guard case .success(let request) = built else {
            refuse(.malformedTarget, requestEnded: true, context: context)
            return
        }
        state = .responding
        let handler = server.handler
        let task = Task { try await handler(request) }
        inFlight = task
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loopSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let isHead = receiving.isHead
        let eventLoop = context.eventLoop
        Task {
            let result = await task.result
            // Back onto the stream's loop before touching the context or the handler.
            eventLoop.execute {
                loopSelf.value.completed(result, isHead: isHead, context: loopContext.value)
            }
        }
    }

    private func completed(_ result: Result<Response, any Error>, isHead: Bool, context: ChannelHandlerContext) {
        inFlight = nil
        guard context.channel.isActive else { return }
        switch ResponseRules.outcome(of: result) {
        case .success(let response): write(response, isHead: isHead, requestEnded: true, context: context)
        case .failure(let refusal): refuse(refusal, requestEnded: true, context: context)
        }
    }

    // MARK: Writing

    /// Answers with a refusal. If the peer is still sending, the stream is then reset with `NO_ERROR`, which
    /// is how RFC 9113 section 8.1 says to tell a peer to stop sending a body that is not wanted.
    private func refuse(_ refusal: Refusal, requestEnded: Bool, context: ChannelHandlerContext) {
        write(refusal.response, isHead: false, requestEnded: requestEnded, context: context)
    }

    private func write(_ response: Response, isHead: Bool, requestEnded: Bool, context: ChannelHandlerContext) {
        state = .done
        let prepared = ResponseRules.prepare(response)
        var block = HPACKHeaders()
        block.add(name: ":status", value: String(prepared.code))
        // Field names are lower case in HTTP/2 (RFC 9113 section 8.2.1).
        for field in prepared.fields { block.add(name: field.name.rawName.lowercased(), value: field.value) }
        block.add(name: "date", value: HTTPDate.string(for: Date()))
        if prepared.hasBody { block.add(name: "content-length", value: String(prepared.body.count)) }

        let sendsBody = prepared.hasBody && !isHead && !prepared.body.isEmpty
        context.write(wrapOutboundOut(.headers(.init(headers: block, endStream: !sendsBody))), promise: nil)
        if sendsBody {
            context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(ByteBuffer(bytes: prepared.body)), endStream: true))), promise: nil)
        }
        if !requestEnded {
            context.write(wrapOutboundOut(.rstStream(.noError)), promise: nil)
        }
        context.flush()
    }

    private func reset(_ code: NIOHTTP2.HTTP2ErrorCode, context: ChannelHandlerContext) {
        state = .done
        context.writeAndFlush(wrapOutboundOut(.rstStream(code)), promise: nil)
    }

    // MARK: Lifecycle

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // A fault on the stream: there is nobody to answer. The error's text is not sent.
        state = .done
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inFlight?.cancel()
        inFlight = nil
        state = .done
        context.fireChannelInactive()
    }
}
