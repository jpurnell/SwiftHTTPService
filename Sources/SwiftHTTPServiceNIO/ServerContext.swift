// ServerContext.swift
// SwiftHTTPServiceNIO
//
// What every connection of one server shares.

import SwiftHTTPService

/// The configuration and the handler. One per server, read by every connection, never changed.
///
/// There is no "draining" flag: shutdown is NIOExtras' `ServerQuiescingHelper`, which tells every open
/// connection (`ChannelShouldQuiesceEvent`) and closes any that arrives afterwards.
final class ServerContext: Sendable {
    let configuration: ServiceConfiguration
    let handler: Handler

    init(configuration: ServiceConfiguration, handler: @escaping Handler) {
        self.configuration = configuration
        self.handler = handler
    }
}
