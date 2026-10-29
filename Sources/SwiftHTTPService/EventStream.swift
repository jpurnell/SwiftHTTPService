// EventStream.swift
// SwiftHTTPService
//
// Server-sent events: a stream of text events a browser (or a client library) reads as they come.

import Foundation
import HTTPTypes

/// Why an event could not be written. It names the part and never the text.
public enum EventStreamError: Error, Equatable, Sendable {
    /// An event name, an id or a comment holds a character that would end its line (a carriage return or line
    /// feed), or an id holds a NUL, which makes a client ignore the id; or the event name is empty.
    case field
    /// The reconnection time is negative.
    case retry
}

/// Writes events to a server-sent event stream (the WHATWG HTML Standard, section 9.2).
///
/// An event is lines of `field: value` ended by a blank line, and the format has no escaping: a value with a line
/// break in it would start another field or another event. So the fields that cannot hold one (the event name, the
/// id, a comment) refuse it, and the data, which can, is split at every break into lines of its own.
public struct EventWriter: Sendable {
    private let writer: ResponseWriter

    init(_ writer: ResponseWriter) {
        self.writer = writer
    }

    /// Sends one event.
    ///
    /// - Parameters:
    ///   - data: The payload. Carriage returns, line feeds and CR LF pairs each start a new `data:` line, which the
    ///     client joins back with line feeds. Empty data is still an event.
    ///   - event: The event name the client dispatches on. Nil is the default `message`. Not empty, no line breaks.
    ///   - id: The last-event id the client sends back when it reconnects. May be empty (which clears it). No line
    ///     breaks, no NUL.
    ///   - retry: Milliseconds the client should wait before reconnecting. Not negative.
    /// - Throws: ``EventStreamError`` before anything is written, or what the stream's write throws.
    public func send(data: String, event: String? = nil, id: String? = nil, retry: Int? = nil) async throws {
        var lines: [String] = []
        if let event {
            guard !event.isEmpty, !Self.hasLineBreak(event), !event.unicodeScalars.contains("\u{0}") else { throw EventStreamError.field }
            lines.append("event: \(event)")
        }
        if let id {
            guard !Self.hasLineBreak(id), !id.unicodeScalars.contains("\u{0}") else { throw EventStreamError.field }
            lines.append("id: \(id)")
        }
        if let retry {
            guard retry >= 0 else { throw EventStreamError.retry }
            lines.append("retry: \(retry)")
        }
        for line in Self.splitLines(data) { lines.append("data: \(line)") }
        try await writer.write(Data((lines.joined(separator: "\n") + "\n\n").utf8))
    }

    /// Sends a comment, which a client ignores: the way to keep a connection from being closed as idle by whatever
    /// stands between the server and the client.
    ///
    /// - Throws: ``EventStreamError/field`` if `text` has a line break; or what the stream's write throws.
    public func sendComment(_ text: String) async throws {
        guard !Self.hasLineBreak(text) else { throw EventStreamError.field }
        try await writer.write(Data((text.isEmpty ? ":\n\n" : ": \(text)\n\n").utf8))
    }

    private static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
    }

    /// Splits at every carriage return, line feed and CR LF pair, keeping an empty last line.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasReturn {
                previousWasReturn = false          // the second half of CR LF: the break was already taken at the CR
                continue
            }
            previousWasReturn = scalar == "\r"
            if scalar == "\r" || scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }
}

extension Response {
    /// A server-sent event stream: `text/event-stream`, never cached, written event by event.
    ///
    /// ```swift
    /// import SwiftHTTPService
    ///
    /// let response = Response.eventStream { events in
    ///     try await events.send(data: "hello", event: "greeting", id: "1")
    ///     try await events.sendComment("still here")
    /// }
    /// ```
    ///
    /// The type and the caching are fixed: `headers` may add to them, not replace them. The stream is bounded like
    /// any other (see ``Response/streaming(status:headers:produce:)``), so a long-lived one ends at
    /// ``Limits/maximumStreamDuration`` and the client reconnects, as event-stream clients do.
    ///
    /// - Parameters:
    ///   - headers: Further header fields.
    ///   - produce: Writes the events.
    public static func eventStream(
        headers: HTTPFields = HTTPFields(), produce: @escaping @Sendable (EventWriter) async throws -> Void
    ) -> Response {
        var fields = headers
        fields[.contentType] = "text/event-stream"
        fields[.cacheControl] = "no-store"
        return .streaming(status: .ok, headers: fields) { writer in try await produce(EventWriter(writer)) }
    }
}
