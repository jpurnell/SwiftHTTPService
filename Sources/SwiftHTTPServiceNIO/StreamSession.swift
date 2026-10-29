// StreamSession.swift
// SwiftHTTPServiceNIO
//
// One streaming response: its byte count, the reason it ended, and the writes a producer makes.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import SwiftHTTPService

/// The state of one streaming response, shared between the connection's event loop (which writes the head, ends the
/// stream, and closes the connection) and the task running the producer (which writes the body).
///
/// A write completes when the transport has handed the bytes to the connection, which is what slows a producer to
/// the pace of its reader. Each is bounded: by the byte limit, and by the write timeout, which ends the stream
/// (closing the connection or resetting the HTTP/2 stream) when the peer will not read.
final class StreamSession: Sendable {
    private struct State {
        var ended: StreamError?
        var written = 0
    }

    private let channel: any Channel
    private let maximumBytes: Int
    private let writeTimeout: TimeAmount
    private let send: @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    private let state = NIOLockedValueBox(State())

    /// - Parameters:
    ///   - channel: The channel the stream is written to; closed when the stream must be cut off.
    ///   - limits: Where the byte limit and write timeout come from.
    ///   - send: Writes and flushes one piece of body in the form this transport frames it, completing when the
    ///     bytes have been accepted by the connection.
    init(channel: any Channel, limits: Limits, send: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>) {
        self.channel = channel
        self.maximumBytes = limits.maximumStreamBytes
        self.writeTimeout = limits.streamWriteTimeout.timeAmount
        self.send = send
    }

    /// Why the stream ended, or nil while it is still open.
    var reason: StreamError? { state.withLockedValue { $0.ended } }

    /// Ends the stream for `reason`, if it has not ended already; the first reason stays. Returns whether this call
    /// was the one that ended it.
    @discardableResult
    func end(_ reason: StreamError) -> Bool {
        state.withLockedValue { state in
            guard state.ended == nil else { return false }
            state.ended = reason
            return true
        }
    }

    /// The write a producer's ``ResponseWriter`` makes.
    func write(_ data: Data) async throws {
        try admit(data.count)
        let timer = channel.eventLoop.scheduleTask(in: writeTimeout) { [self] in
            // The peer has not read what was sent: end the stream and the connection. The write then fails.
            end(.writeTimeout)
            channel.close(promise: nil)
        }
        do {
            try await send(ByteBuffer(bytes: data)).get()
            timer.cancel()
        } catch {
            timer.cancel()
            throw reason ?? .closed           // a write that failed with no earlier reason: the connection went away
        }
    }

    /// Whether `count` more bytes may be written; if not, the stream ends and the connection is closed.
    private func admit(_ count: Int) throws {
        let outcome: StreamError? = state.withLockedValue { state in
            if let ended = state.ended { return ended }
            if count > maximumBytes - state.written {
                state.ended = .byteLimit
                return .byteLimit
            }
            state.written += count
            return nil
        }
        if let outcome {
            if outcome == .byteLimit { channel.close(promise: nil) }
            throw outcome
        }
    }
}
