// ConnectionHandler.swift
// SwiftHTTPServiceNIO
//
// One connection: parse a request, run the handler, write the response.

import Foundation
import HTTPTypes
import NIOCore
import NIOExtras
import NIOHTTP1
import SwiftHTTPService

/// Serves requests on one connection, one at a time.
///
/// **Pipelining is not supported.** A peer that sends a second request before the first has been answered
/// gets the first answered with `Connection: close`, and the second is never read or run; it can resend on
/// a new connection. That is allowed by HTTP, and it removes a class of response-ordering and smuggling
/// faults for a service that has no use for pipelining.
///
/// **A handler that never returns is not bounded here.** The deadlines in ``Limits`` cover reading the
/// request and waiting between requests; the time a handler takes is the handler's. A connection whose
/// handler is stuck stays open (and counts toward the connection cap) until the handler returns, the peer
/// closes it, or the grace period of a shutdown ends.
// Justification: a channel handler is confined to its event loop and `@unchecked Sendable` only lets NIOLoopBound hold it.
final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct Receiving {
        var method: HTTPRequest.Method
        var target: String
        var fields: HTTPFields
        var keepAlive: Bool
        var isHead: Bool
        var version: HTTPProtocolVersion
        /// This request's body bound: its route's, or the server's. Fixed when the head arrived.
        var bodyLimit: Int
        var body: ByteBuffer
        /// The Content-Length, or nil for a chunked body or none.
        var declaredLength: Int?
        var expectsBody: Bool
    }

    private enum State {
        case idle
        case receiving(Receiving)
        case responding
        case closing
    }

    private let server: ServerContext
    private var state: State = .idle
    private var closeAfterResponse = false
    private let liveness = ChannelLiveness()
    private var bodyTimer: Scheduled<Void>?
    private var inFlight: Task<Response, any Error>?

    private let identity: ConnectionIdentity

    init(server: ServerContext, identity: ConnectionIdentity = ConnectionIdentity()) {
        self.server = server
        self.identity = identity
    }

    deinit {
        // A handler that goes away with a request still running must not leave its task behind.
        inFlight?.cancel()
    }

    // MARK: Inbound parts

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch (unwrapInboundIn(data), state) {
        case (.head(let head), .idle):
            begin(head, context: context)
        case (.head, .responding), (.head, .receiving):
            // A second request before the first is answered: pipelining. Answer the first, close, ignore this.
            closeAfterResponse = true
            context.triggerUserOutboundEvent(GuardSignal.discard, promise: nil)
        case (.body(var chunk), .receiving(var receiving)):
            guard RequestRules.bodyFits(received: receiving.body.readableBytes, incoming: chunk.readableBytes, limit: receiving.bodyLimit) else {
                cancelBodyTimer()
                refuse(.bodyTooLarge, context: context)
                return
            }
            receiving.body.writeBuffer(&chunk)
            state = .receiving(receiving)
        case (.end, .receiving(let receiving)):
            cancelBodyTimer()
            context.triggerUserOutboundEvent(GuardSignal.requestFinished, promise: nil)
            dispatch(receiving, context: context)
        default:
            break
        }
    }

    // MARK: Head validation

    private func begin(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let validated: Validated
        switch validate(head) {
        case .success(let value): validated = value
        case .failure(let refusal):
            refuse(refusal, context: context)
            return
        }
        // The target is checked now, before any body is read, so a refused target costs nothing.
        guard RequestRules.isAcceptableTarget(method: validated.method, target: head.uri, fields: validated.fields) else {
            refuse(.malformedTarget, context: context)
            return
        }
        let limit = server.bodyLimit(method: validated.method, target: head.uri)
        if let length = validated.declaredLength, !RequestRules.declaredLengthFits(length, limit: limit) {
            refuse(.bodyTooLarge, context: context)
            return
        }
        if validated.expectsContinue, validated.expectsBody {
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .continue))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
        state = .receiving(Receiving(
            method: validated.method, target: head.uri, fields: validated.fields, keepAlive: head.isKeepAlive,
            isHead: head.method == .HEAD, version: head.version.minor == 0 ? .http1_0 : .http1_1, bodyLimit: limit, body: context.channel.allocator.buffer(capacity: 0),
            declaredLength: validated.declaredLength, expectsBody: validated.expectsBody))
        if validated.expectsBody { armBodyTimer(context: context) }
    }

    private struct Validated {
        var method: HTTPRequest.Method
        var fields: HTTPFields
        var declaredLength: Int?
        var expectsBody: Bool
        var expectsContinue: Bool
    }

    /// Everything about a head that could make it mean two things, or mean something this server will not do.
    private func validate(_ head: HTTPRequestHead) -> Result<Validated, Refusal> {
        guard let method = HTTPRequest.Method(head.method.rawValue) else { return .failure(.badRequest) }
        var fields = HTTPFields()
        var lengths: [String] = []
        var codings: [String] = []
        var hosts = 0
        var expectations: [String] = []
        for (name, value) in head.headers {
            guard let fieldName = HTTPField.Name(name),
                  RequestRules.isCleanFieldValue(value)
            else { return .failure(.badRequest) }
            switch name.lowercased() {
            case "content-length": lengths.append(value)
            case "transfer-encoding": codings.append(value)
            case "host": hosts += 1
            case "expect": expectations.append(value)
            default: break
            }
            fields.append(HTTPField(name: fieldName, value: value))
        }
        // HTTP/1.1 requires exactly one Host (RFC 9112 section 3.2); a second one is how two parties read
        // one request as addressed to two places.
        if Self.isAtLeast11(head.version), hosts != 1 { return .failure(.badRequest) }
        guard lengths.isEmpty || codings.isEmpty else { return .failure(.badRequest) }

        var declaredLength: Int?
        var chunked = false
        if !lengths.isEmpty {
            guard lengths.count == 1, let length = RequestRules.parseLength(lengths[0]) else { return .failure(.badRequest) }
            declaredLength = length
        }
        if !codings.isEmpty {
            guard codings.count == 1,
                  codings[0].trimmingCharacters(in: .whitespaces).lowercased() == "chunked",
                  Self.isAtLeast11(head.version)
            else { return .failure(.badRequest) }
            chunked = true
        }
        var expectsContinue = false
        if !expectations.isEmpty {
            guard expectations.count == 1,
                  expectations[0].trimmingCharacters(in: .whitespaces).lowercased() == "100-continue"
            else { return .failure(.expectationFailed) }
            expectsContinue = true
        }
        return .success(Validated(
            method: method, fields: fields, declaredLength: declaredLength,
            expectsBody: chunked || (declaredLength ?? 0) > 0, expectsContinue: expectsContinue))
    }

    private static func isAtLeast11(_ version: HTTPVersion) -> Bool {
        version.major > 1 || (version.major == 1 && version.minor >= 1)
    }

    // MARK: Running the handler

    private func dispatch(_ receiving: Receiving, context: ChannelHandlerContext) {
        let peer = context.remoteAddress?.ipAddress
        let built = Result {
            try Request(
                method: receiving.method, target: receiving.target, headers: receiving.fields,
                body: Data(receiving.body.readableBytesView),
                remoteAddress: ClientAddress.resolve(
                    peer: peer, proxied: identity.client, forwardedFor: receiving.fields.forwardedForValues, configuration: server.configuration),
                httpVersion: receiving.version, peerAddress: peer)
        }
        guard case .success(let request) = built else {
            refuse(.malformedTarget, context: context)
            return
        }
        state = .responding
        if !receiving.keepAlive || server.configuration.connections == .closeAfterResponse { closeAfterResponse = true }
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
            // The channel may have closed, and the loop stopped with it, while the handler ran.
            guard liveness.isOpen else { return }
            // Back onto the connection's loop before touching the context or the handler.
            eventLoop.execute {
                loopSelf.value.completed(result, isHead: isHead, context: loopContext.value)
            }
        }
    }

    private func completed(_ result: Result<Response, any Error>, isHead: Bool, context: ChannelHandlerContext) {
        inFlight = nil
        guard context.channel.isActive else { return }
        switch ResponseRules.outcome(of: result) {
        case .success(let response):
            write(response, isHead: isHead, close: closeAfterResponse, context: context)
        case .failure(let refusal):
            refuse(refusal, context: context)
        }
    }

    // MARK: Writing

    private func refuse(_ refusal: Refusal, context: ChannelHandlerContext) {
        cancelBodyTimer()
        context.triggerUserOutboundEvent(GuardSignal.discard, promise: nil)
        write(server.response(for: refusal), isHead: false, close: true, context: context)
    }

    private func write(_ response: Response, isHead: Bool, close: Bool, context: ChannelHandlerContext) {
        state = close ? .closing : .idle
        let prepared = ResponseRules.prepare(response)
        var headers = HTTPHeaders()
        for field in prepared.fields { headers.add(name: field.name.rawName, value: field.value) }
        headers.add(name: "Date", value: HTTPDate.string(for: Date()))
        headers.add(name: "Connection", value: close ? "close" : "keep-alive")
        let code = prepared.code
        let hasBody = prepared.hasBody
        if hasBody { headers.add(name: "Content-Length", value: String(prepared.body.count)) }

        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: code), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if hasBody, !isHead, !prepared.body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: prepared.body)))), promise: nil)
        }
        let finished = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: finished)
        if close {
            let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            finished.futureResult.whenComplete { _ in loopContext.value.close(promise: nil) }
        } else {
            context.triggerUserOutboundEvent(GuardSignal.responseFinished, promise: nil)
        }
    }

    // MARK: Timers

    private func armBodyTimer(context: ChannelHandlerContext) {
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loopSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        bodyTimer = context.eventLoop.scheduleTask(in: server.configuration.limits.bodyReadTimeout.timeAmount) {
            let handler = loopSelf.value
            handler.bodyTimer = nil
            if case .receiving = handler.state { handler.refuse(.requestTimeout, context: loopContext.value) }
        }
    }

    private func cancelBodyTimer() {
        bodyTimer?.cancel()
        bodyTimer = nil
    }

    // MARK: Events

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let guardEvent as GuardEvent:
            handle(guardEvent, context: context)
        case is ChannelShouldQuiesceEvent:
            // Shutdown has begun (NIOExtras' ServerQuiescingHelper): finish what is in progress, then
            // close. A connection with nothing in progress closes now.
            switch state {
            case .idle: context.close(promise: nil)
            case .receiving, .responding: closeAfterResponse = true
            case .closing: break
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func handle(_ event: GuardEvent, context: ChannelHandlerContext) {
        switch (event, state) {
        case (.idleTimeout, .idle):
            state = .closing
            context.close(promise: nil)
        case (.headerTimeout, .idle):
            refuse(.requestTimeout, context: context)
        case (.headTooLarge, .idle):
            refuse(.headersTooLarge, context: context)
        case (.headerTimeout, _), (.headTooLarge, _):
            // Bytes of a pipelined request while one is in flight: not served, and the connection ends.
            closeAfterResponse = true
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        switch state {
        case .closing:
            context.close(promise: nil)
        case .idle, .receiving:
            guard let parserError = error as? HTTPParserError else {
                // A transport fault (reset, TLS failure, closed pipe): there is nobody to answer.
                state = .closing
                context.close(promise: nil)
                return
            }
            switch parserError {
            case .headerOverflow: refuse(.headersTooLarge, context: context)
            case .invalidURL: refuse(.malformedTarget, context: context)
            default: refuse(.badRequest, context: context)
            }
        case .responding:
            closeAfterResponse = true
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        liveness.close()
        cancelBodyTimer()
        inFlight?.cancel()
        inFlight = nil
        state = .closing
        context.fireChannelInactive()
    }
}
