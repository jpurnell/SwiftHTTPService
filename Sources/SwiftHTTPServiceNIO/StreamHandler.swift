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
        /// This request's body bound: its route's, or the server's. Fixed when the head arrived.
        var bodyLimit: Int
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
    private var streamSession: StreamSession?
    private var streamTask: Task<Void, any Error>?
    private var streamTimer: Scheduled<Void>?
    private let liveness = ChannelLiveness()
    private var bodyTimer: Scheduled<Void>?

    private let identity: ConnectionIdentity

    init(server: ServerContext, identity: ConnectionIdentity = ConnectionIdentity()) {
        self.server = server
        self.identity = identity
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
            guard RequestRules.bodyFits(received: receiving.body.readableBytes, incoming: chunk.readableBytes, limit: receiving.bodyLimit) else {
                refuse(.bodyTooLarge, requestEnded: false, context: context)
                return
            }
            receiving.body.writeBuffer(&chunk)
            if frame.endStream {
                cancelBodyTimer()
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
        var expectations: [String] = []
        // The list is measured as RFC 9113 section 6.5.2 does: name and value octets plus 32 for each field.
        // The library advertises the bound and does not enforce it, so it is enforced here.
        let limits = server.configuration.limits
        var listSize = 0
        var regularCount = 0
        for (name, value, _) in block.headers {
            listSize += name.utf8.count + value.utf8.count + 32
            if !name.hasPrefix(":") { regularCount += 1 }
        }
        guard listSize <= limits.maximumHeaderBytes, regularCount <= limits.maximumHeaderCount else {
            refuse(.headersTooLarge, requestEnded: block.endStream, context: context)
            return
        }
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
                if name == "expect" { expectations.append(value) }
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
        // `Expect: 100-continue` needs no interim response here: the server reads the body as it arrives, and
        // a client may send it without waiting. Any other expectation cannot be met (RFC 9110 section 10.1.1).
        if !expectations.isEmpty {
            guard expectations.count == 1, expectations[0].trimmingCharacters(in: .whitespaces).lowercased() == "100-continue" else {
                refuse(.expectationFailed, requestEnded: block.endStream, context: context)
                return
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
        let bodyLimit = server.bodyLimit(method: verb, target: path)
        if let declaredLength, !RequestRules.declaredLengthFits(declaredLength, limit: bodyLimit) {
            refuse(.bodyTooLarge, requestEnded: block.endStream, context: context)
            return
        }
        let receiving = Receiving(
            method: verb, target: path, fields: fields, isHead: verb == .head, bodyLimit: bodyLimit, body: context.channel.allocator.buffer(capacity: 0))
        if block.endStream {
            dispatch(receiving, context: context)
        } else {
            state = .receiving(receiving)
            armBodyTimer(context: context)
        }
    }

    // MARK: Timers

    private func armBodyTimer(context: ChannelHandlerContext) {
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loopSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        bodyTimer = context.eventLoop.scheduleTask(in: server.configuration.limits.bodyReadTimeout.timeAmount) {
            let handler = loopSelf.value
            handler.bodyTimer = nil
            if case .receiving = handler.state { handler.refuse(.requestTimeout, requestEnded: false, context: loopContext.value) }
        }
    }

    private func cancelBodyTimer() {
        bodyTimer?.cancel()
        bodyTimer = nil
    }

    // MARK: Running the handler

    private func dispatch(_ receiving: Receiving, context: ChannelHandlerContext) {
        let peer = context.channel.parent?.remoteAddress?.ipAddress
        let built = Result {
            try Request(
                method: receiving.method, target: receiving.target, headers: receiving.fields,
                body: Data(receiving.body.readableBytesView),
                remoteAddress: ClientAddress.resolve(
                    peer: peer, proxied: identity.client, forwardedFor: receiving.fields.forwardedForValues, configuration: server.configuration),
                httpVersion: .http2, peerAddress: peer)
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
        let liveness = self.liveness
        Task {
            let result = await task.result
            // The channel may have closed, and the loop stopped with it, while the handler ran. A stream it
            // returned will never run, and whoever is waiting to hear how it ended is told.
            guard liveness.isOpen else {
                if case .success(let response) = result { response.stream?.discard() }
                return
            }
            // Back onto the stream's loop before touching the context or the handler.
            eventLoop.execute {
                loopSelf.value.completed(result, isHead: isHead, context: loopContext.value)
            }
        }
    }

    private func completed(_ result: Result<Response, any Error>, isHead: Bool, context: ChannelHandlerContext) {
        inFlight = nil
        guard context.channel.isActive else {
            if case .success(let response) = result { response.stream?.discard() }     // never sent: it will not run
            return
        }
        switch ResponseRules.outcome(of: result) {
        case .success(let response):
            if let stream = response.stream {
                writeStreaming(response, stream: stream, isHead: isHead, context: context)
            } else {
                write(response, isHead: isHead, requestEnded: true, context: context)
            }
        case .failure(let refusal):
            if case .success(let response) = result { response.stream?.discard() }     // a status that cannot be sent
            refuse(refusal, requestEnded: true, context: context)
        }
    }

    // MARK: Writing

    /// Answers with a refusal. If the peer is still sending, the stream is then reset with `NO_ERROR`, which
    /// is how RFC 9113 section 8.1 says to tell a peer to stop sending a body that is not wanted.
    private func refuse(_ refusal: Refusal, requestEnded: Bool, context: ChannelHandlerContext) {
        write(server.response(for: refusal), isHead: false, requestEnded: requestEnded, context: context)
    }

    private func write(_ response: Response, isHead: Bool, requestEnded: Bool, context: ChannelHandlerContext) {
        cancelBodyTimer()
        state = .done
        let prepared = ResponseRules.prepare(response)
        var block = HPACKHeaders()
        block.add(name: ":status", value: String(prepared.code))
        // Field names are lower case in HTTP/2 (RFC 9113 section 8.2.1).
        for field in prepared.fields { block.add(name: field.name.rawName.lowercased(), value: field.value) }
        block.add(name: "date", value: HTTPDate.string(for: Date()))
        if prepared.hasBody { block.add(name: "content-length", value: String(prepared.body.count)) }

        let sendsBody = prepared.hasBody && !isHead && !prepared.body.isEmpty
        // The last frame of the response carries the promise. If the peer is still sending a body nobody
        // wants, the stream is reset with NO_ERROR once that frame has been written (RFC 9113 section 8.1);
        // a reset queued behind the response would drop the response's own data.
        let last = context.eventLoop.makePromise(of: Void.self)
        if !requestEnded {
            let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            last.futureResult.whenSuccess {
                loopContext.value.writeAndFlush(NIOAny(HTTP2Frame.FramePayload.rstStream(.noError)), promise: nil)
            }
        }
        if sendsBody {
            context.write(wrapOutboundOut(.headers(.init(headers: block, endStream: false))), promise: nil)
            context.writeAndFlush(
                wrapOutboundOut(.data(.init(data: .byteBuffer(ByteBuffer(bytes: prepared.body)), endStream: true))), promise: last)
        } else {
            context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: block, endStream: true))), promise: last)
        }
    }

    // MARK: Streaming

    /// Sends the headers of a streaming response, then runs its producer, sending each write as `DATA`.
    ///
    /// A producer that ends cleanly ends the stream with `END_STREAM`. One that fails, or is cut off by a limit,
    /// resets the stream and leaves the connection and its other streams alone: `INTERNAL_ERROR` if the producer
    /// itself failed, `CANCEL` if a limit or the peer ended it. Flow control paces the producer: a write completes
    /// when the connection has taken the frame, which it does as the peer gives its window back.
    private func writeStreaming(_ response: Response, stream: ResponseStream, isHead: Bool, context: ChannelHandlerContext) {
        let prepared = ResponseRules.prepare(response)
        guard prepared.hasBody else {
            // A status that has no body (204, 304) has nothing to stream: it is an ordinary bodyless response.
            stream.discard()
            write(Response(status: response.status, headers: response.headers), isHead: isHead, requestEnded: true, context: context)
            return
        }
        cancelBodyTimer()
        var block = HPACKHeaders()
        block.add(name: ":status", value: String(prepared.code))
        for field in prepared.fields { block.add(name: field.name.rawName.lowercased(), value: field.value) }
        block.add(name: "date", value: HTTPDate.string(for: Date()))
        guard !isHead else {
            stream.discard()
            state = .done
            context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: block, endStream: true))), promise: nil)
            return
        }
        context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: block, endStream: false))), promise: nil)

        let channel = context.channel
        let session = StreamSession(channel: channel, limits: server.configuration.limits) { buffer in
            channel.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: false)))
        }
        streamSession = session
        let task = Task { try await stream.produce(ResponseWriter { try await session.write($0) }) }
        streamTask = task
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loopSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let liveness = self.liveness
        let eventLoop = context.eventLoop
        // The stream's whole life is bounded: past the duration it is cut off, whether the producer is writing or idle.
        streamTimer = context.eventLoop.scheduleTask(in: server.configuration.limits.maximumStreamDuration.timeAmount) {
            session.end(.durationLimit)
            task.cancel()
            loopContext.value.close(promise: nil)
        }
        Task {
            var producerFailed = false
            if case .failure(let failure) = await task.result {
                producerFailed = !(failure is StreamError) && !(failure is CancellationError)
                session.end((failure as? StreamError) ?? .closed)
            }
            // The stream may have closed, and the loop stopped with it, while the producer ran.
            guard liveness.isOpen else { return }
            let failed = producerFailed
            eventLoop.execute {
                loopSelf.value.streamEnded(clean: session.reason == nil, producerFailed: failed, context: loopContext.value)
            }
        }
    }

    /// The producer has returned. A clean end finishes the stream; anything else resets it.
    private func streamEnded(clean: Bool, producerFailed: Bool, context: ChannelHandlerContext) {
        streamTimer?.cancel()
        streamTimer = nil
        streamTask = nil
        streamSession?.end(.closed)                      // nothing more may be written to this stream
        streamSession = nil
        state = .done
        guard context.channel.isActive else { return }
        if clean {
            context.writeAndFlush(wrapOutboundOut(.data(.init(data: .byteBuffer(ByteBuffer()), endStream: true))), promise: nil)
        } else if producerFailed {
            context.writeAndFlush(wrapOutboundOut(.rstStream(.internalError)), promise: nil)
        } else {
            context.close(promise: nil)                  // a limit, or a peer that left: the stream is cancelled
        }
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
        liveness.close()
        streamTimer?.cancel()
        streamTimer = nil
        streamSession?.end(.closed)
        streamTask?.cancel()
        streamTask = nil
        streamSession = nil
        cancelBodyTimer()
        inFlight?.cancel()
        inFlight = nil
        state = .done
        context.fireChannelInactive()
    }
}
