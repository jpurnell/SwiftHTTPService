// ServerContext.swift
// SwiftHTTPServiceNIO
//
// What every connection of one server shares.

import HTTPTypes
import SwiftHTTPService

/// The configuration and the handler. One per server, read by every connection, never changed.
///
/// There is no "draining" flag: shutdown is NIOExtras' `ServerQuiescingHelper`, which tells every open
/// connection (`ChannelShouldQuiesceEvent`) and closes any that arrives afterwards.
final class ServerContext: Sendable {
    let configuration: ServiceConfiguration
    let handler: Handler
    let refusals: RefusalHooks
    /// Asked after a request's head, before its body: the bound for this method and target, if its route has one.
    let routeBodyLimit: (@Sendable (HTTPRequest.Method, String) -> Int?)?

    init(
        configuration: ServiceConfiguration, handler: @escaping Handler, refusals: RefusalHooks = RefusalHooks(),
        routeBodyLimit: (@Sendable (HTTPRequest.Method, String) -> Int?)? = nil
    ) {
        self.configuration = configuration
        self.handler = handler
        self.refusals = refusals
        self.routeBodyLimit = routeBodyLimit
    }

    /// The body bound for a request: its route's, or the server's. Both are validated at their source, and the
    /// route's may be lower or higher than the server's.
    func bodyLimit(method: HTTPRequest.Method, target: String) -> Int {
        routeBodyLimit?(method, target) ?? configuration.limits.maximumBodyBytes
    }

    /// The response for a refusal: the server's body if its hook gives one, the fixed default if not. The hook is
    /// told first. The status is always the refusal's own, whatever the hook's response says.
    func response(for refusal: Refusal, about request: RefusalContext = RefusalContext()) -> Response {
        let kind = TransportRefusal(refusal)
        refusals.observe?(kind)
        refusals.record?(RefusalRecord(
            kind: kind, peerAddress: request.peer, remoteAddress: request.remote, method: request.method, target: request.target,
            httpVersion: request.version))
        guard var custom = refusals.respond?(kind) else { return refusal.response }
        custom.status = HTTPResponse.Status(code: refusal.statusCode)
        return custom
    }
}

/// What a handler knows about the request a refusal is about, already made safe (see ``RefusalRecord``).
struct RefusalContext {
    var peer: String?
    var remote: String?
    var method: String?
    var target: String?
    var version: HTTPProtocolVersion?
}
