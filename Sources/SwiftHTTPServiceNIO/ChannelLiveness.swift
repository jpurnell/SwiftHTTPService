// ChannelLiveness.swift
// SwiftHTTPServiceNIO
//
// Whether the channel a handler belongs to is still open, readable from any thread.

import NIOConcurrencyHelpers

/// Set by a handler when its channel closes, and read by the task that waits for the application's handler.
///
/// The application's handler can finish after the server has been shut down, by which time the event loop
/// has stopped, and scheduling work on a stopped loop is what NIO reports as an error (and means to make a
/// crash). A task that finds the channel already closed has nobody to answer, so it does not hop back.
final class ChannelLiveness: Sendable {
    private let open = NIOLockedValueBox(true)

    /// Whether the channel was still open when last told.
    var isOpen: Bool { open.withLockedValue { $0 } }

    /// Records that the channel has closed.
    func close() { open.withLockedValue { $0 = false } }
}
