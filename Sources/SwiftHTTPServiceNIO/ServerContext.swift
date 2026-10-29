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

    init(configuration: ServiceConfiguration, handler: @escaping Handler, refusals: RefusalHooks = RefusalHooks()) {
        self.configuration = configuration
        self.handler = handler
        self.refusals = refusals
    }

    /// The response for a refusal: the server's body if its hook gives one, the fixed default if not. The hook is
    /// told first. The status is always the refusal's own, whatever the hook's response says.
    func response(for refusal: Refusal) -> Response {
        let kind = TransportRefusal(refusal)
        refusals.observe?(kind)
        guard var custom = refusals.respond?(kind) else { return refusal.response }
        custom.status = HTTPResponse.Status(code: refusal.statusCode)
        return custom
    }
}
