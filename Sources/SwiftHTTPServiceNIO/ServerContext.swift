// ServerContext.swift
// SwiftHTTPServiceNIO
//
// What every connection of one server shares.

import NIOConcurrencyHelpers
import SwiftHTTPService

/// The configuration, the handler, and whether the server is draining. One per server, read by every
/// connection; the only mutable part is the drain flag, behind a lock.
final class ServerContext: Sendable {
    let configuration: ServiceConfiguration
    let handler: Handler
    private let draining = NIOLockedValueBox(false)

    init(configuration: ServiceConfiguration, handler: @escaping Handler) {
        self.configuration = configuration
        self.handler = handler
    }

    /// Whether the server has begun to shut down: connections finish what they are doing and then close.
    var isDraining: Bool { draining.withLockedValue { $0 } }

    /// Marks the server as draining. Idempotent.
    func beginDraining() {
        draining.withLockedValue { $0 = true }
    }
}
