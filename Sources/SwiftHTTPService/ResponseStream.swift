// ResponseStream.swift
// SwiftHTTPService
//
// A response whose body is produced while it is sent.

import Foundation
import HTTPTypes

/// Why a stream ended before its producer finished.
public enum StreamError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The connection or the stream is closed: the peer went away, the server is shutting down, or the transport
    /// ended it. Further writes cannot succeed.
    case closed
    /// The stream wrote more than ``Limits/maximumStreamBytes``.
    case byteLimit
    /// A single write did not complete within ``Limits/streamWriteTimeout``: the peer stopped reading.
    case writeTimeout
    /// The stream ran longer than ``Limits/maximumStreamDuration``.
    case durationLimit

    /// What happened, in words.
    public var description: String {
        switch self {
        case .closed: "the connection is closed"
        case .byteLimit: "the stream wrote more bytes than it is allowed"
        case .writeTimeout: "the peer did not read in time"
        case .durationLimit: "the stream ran longer than it is allowed"
        }
    }
}

/// Where a producer writes the body of a streaming response.
///
/// A write returns when the transport has handed the bytes to the connection, so a slow reader slows its producer
/// and the bytes waiting never grow past one write: that is the backpressure. A write throws a ``StreamError`` when
/// the stream has ended (the peer left, a limit was reached), and the producer should stop.
public struct ResponseWriter: Sendable {
    private let sink: @Sendable (Data) async throws -> Void

    /// Creates a writer over `sink`. Transports make these; a test makes one to collect what a producer writes.
    public init(_ sink: @escaping @Sendable (Data) async throws -> Void) {
        self.sink = sink
    }

    /// Sends `data` as part of the body. An empty `data` is dropped: an empty chunk would end a chunked body.
    ///
    /// - Throws: ``StreamError``, or what the transport's connection throws.
    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await sink(data)
    }
}

/// The body of a streaming response: a closure that writes it.
///
/// Two streams are equal only if they are the same stream, so a ``Response`` compares by identity.
public struct ResponseStream: Sendable, Equatable {
    private let identity = UUID()
    /// Writes the body to `writer`, then returns. Throwing ends the response abruptly.
    public let produce: @Sendable (ResponseWriter) async throws -> Void

    init(_ produce: @escaping @Sendable (ResponseWriter) async throws -> Void) {
        self.produce = produce
    }

    /// Whether two values are the same stream: equal only if one was made from the other by copying.
    public static func == (lhs: ResponseStream, rhs: ResponseStream) -> Bool { lhs.identity == rhs.identity }

    /// A stream that does what this one does and tells `finished` how many bytes it wrote and how it ended: nil for
    /// a normal end, the error otherwise. For a layer that wants to know what was sent after the handler returned,
    /// such as an access log. It is a different stream from this one.
    public func observing(_ finished: @escaping @Sendable (Int, (any Error)?) -> Void) -> ResponseStream {
        let original = produce
        return ResponseStream { writer in
            let counter = ByteCounter()
            let counting = ResponseWriter { data in
                counter.add(data.count)
                try await writer.write(data)
            }
            do {
                try await original(counting)
            } catch {
                finished(counter.total, error)
                throw error
            }
            finished(counter.total, nil)
        }
    }
}

/// A byte count that producers on any task may add to.
// Justification: the only mutable state is `bytes`, and every read and write of it happens inside the lock.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    var total: Int { lock.withLock { bytes } }
    func add(_ count: Int) { lock.withLock { bytes += count } }
}

extension Response {
    /// A response whose body is written while it is sent, in pieces, as the producer has them.
    ///
    /// The status and headers are fixed now; the body is whatever `produce` writes. Use it for what has no length
    /// known in advance or is long-lived, such as a server-sent event stream. Over HTTP/1.1 the transport frames the
    /// body in chunks; over HTTP/2, in `DATA` frames; to an HTTP/1.0 client, and in answer to `HEAD`, it sends the
    /// head and nothing else, closing after. `Content-Length` is the transport's and is not sent.
    ///
    /// The transport bounds a stream: ``Limits/maximumStreamDuration``, ``Limits/maximumStreamBytes``, and
    /// ``Limits/streamWriteTimeout``. A producer that throws ends the response abruptly (the connection is closed,
    /// or the HTTP/2 stream reset), because nothing can be changed once the head has been sent. A producer is
    /// cancelled when the peer goes away and at the end of a shutdown's grace period.
    ///
    /// - Parameters:
    ///   - status: A final status.
    ///   - headers: The header fields.
    ///   - produce: Writes the body.
    public static func streaming(
        status: HTTPResponse.Status, headers: HTTPFields = HTTPFields(),
        produce: @escaping @Sendable (ResponseWriter) async throws -> Void
    ) -> Response {
        Response(status: status, headers: headers, body: Data(), stream: ResponseStream(produce))
    }
}
