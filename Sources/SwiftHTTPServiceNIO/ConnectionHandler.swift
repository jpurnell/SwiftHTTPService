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
final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    // Justification: a channel handler is confined to its channel's event loop; every method and every
    // callback it schedules runs there. `@unchecked Sendable` only lets `NIOLoopBound` hold it.
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct Receiving {
        var method: HTTPRequest.Method
        var target: String
        var fields: HTTPFields
        var keepAlive: Bool
        var isHead: Bool
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
    private var bodyTimer: Scheduled<Void>?
    private var inFlight: Task<Response, any Error>?

    init(server: ServerContext) {
        self.server = server
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
            let limit = server.configuration.limits.maximumBodyBytes
            guard receiving.body.readableBytes + chunk.readableBytes <= limit else {
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
        do {
            _ = try Request(method: validated.method, target: head.uri, headers: validated.fields, body: Data())
        } catch {
            refuse(.malformedTarget, context: context)
            return
        }
        let limit = server.configuration.limits.maximumBodyBytes
        if let length = validated.declaredLength, length > limit {
            refuse(.bodyTooLarge, context: context)
            return
        }
        if validated.expectsContinue, validated.expectsBody {
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .continue))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
        state = .receiving(Receiving(
            method: validated.method, target: head.uri, fields: validated.fields, keepAlive: head.isKeepAlive,
            isHead: head.method == .HEAD, body: context.channel.allocator.buffer(capacity: 0),
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
                  !value.utf8.contains(where: { $0 == 0 || $0 == 0x0A || $0 == 0x0D })
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
            guard lengths.count == 1, let length = Self.parseLength(lengths[0]) else { return .failure(.badRequest) }
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

    /// A Content-Length is ASCII digits and nothing else (surrounding whitespace aside): no sign, no
    /// hexadecimal, no list, and small enough to be a real length.
    static func parseLength(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 18, trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return Int(trimmed)
    }

    // MARK: Running the handler

    private func dispatch(_ receiving: Receiving, context: ChannelHandlerContext) {
        let request: Request
        do {
            request = try Request(
                method: receiving.method, target: receiving.target, headers: receiving.fields,
                body: Data(receiving.body.readableBytesView), remoteAddress: context.remoteAddress?.ipAddress)
        } catch {
            refuse(.malformedTarget, context: context)
            return
        }
        state = .responding
        if !receiving.keepAlive { closeAfterResponse = true }
        let handler = server.handler
        let task = Task { try await handler(request) }
        inFlight = task
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loopSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let isHead = receiving.isHead
        let eventLoop = context.eventLoop
        Task {
            let result = await task.result
            // Back onto the connection's loop before touching the context or the handler.
            eventLoop.execute {
                loopSelf.value.completed(result, isHead: isHead, context: loopContext.value)
            }
        }
    }

    private func completed(_ result: Result<Response, any Error>, isHead: Bool, context: ChannelHandlerContext) {
        inFlight = nil
        guard case .responding = state, context.channel.isActive else { return }
        switch result {
        case .success(let response) where (200...599).contains(response.status.code):
            write(response, isHead: isHead, close: closeAfterResponse || server.isDraining, context: context)
        case .success, .failure:
            // A thrown error, or a status that is not a final one. The text of an error is never sent.
            refuse(.internalError, context: context)
        }
    }

    // MARK: Writing

    private func refuse(_ refusal: Refusal, context: ChannelHandlerContext) {
        cancelBodyTimer()
        context.triggerUserOutboundEvent(GuardSignal.discard, promise: nil)
        var fields = HTTPFields()
        fields[.contentType] = "application/problem+json"
        write(Response(status: HTTPResponse.Status(code: refusal.statusCode), headers: fields, body: refusal.body),
              isHead: false, close: true, context: context)
    }

    private func write(_ response: Response, isHead: Bool, close: Bool, context: ChannelHandlerContext) {
        state = close ? .closing : .idle
        var headers = HTTPHeaders()
        for field in response.headers {
            switch field.name.rawName.lowercased() {
            case "content-length", "connection", "date", "transfer-encoding", "keep-alive": continue
            default: headers.add(name: field.name.rawName, value: field.value)
            }
        }
        headers.add(name: "Date", value: HTTPDate.string(for: Date()))
        headers.add(name: "Connection", value: close ? "close" : "keep-alive")
        let code = response.status.code
        let hasBody = !(code < 200 || code == 204 || code == 304)
        if hasBody { headers.add(name: "Content-Length", value: String(response.body.count)) }

        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: code), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if hasBody, !isHead, !response.body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: response.body)))), promise: nil)
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
        cancelBodyTimer()
        inFlight?.cancel()
        inFlight = nil
        state = .closing
        context.fireChannelInactive()
    }
}
