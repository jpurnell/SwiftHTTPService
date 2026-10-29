// RequestID.swift
// SwiftHTTPService
//
// An id for every request, safe to put in a log.

import Foundation
import HTTPTypes

/// The id of the request in flight, in its ``Context``.
public enum RequestID: ContextKey {
    /// The id.
    public typealias Value = String
}

extension HTTPField.Name {
    /// `X-Request-ID`, the header a request id travels in by default.
    public static let requestID: HTTPField.Name = {
        // A constant that is a valid field name; if a change ever makes it invalid, every test fails at once.
        guard let name = HTTPField.Name("X-Request-ID") else { preconditionFailure("X-Request-ID is a valid field name") }
        return name
    }()
}

/// Gives every request an id, and puts it on the response.
///
/// An id offered by the caller in `header` is **untrusted**: it ends up in logs, so it is used only if it is 1
/// to 64 characters from `A-Z a-z 0-9 . _ -`. Anything else is replaced by a generated id, whole; it is not
/// cleaned or cut short, because a cleaned id can collide with a real one.
///
/// The id is set on the response whatever the handler put there. A handler that throws has no response to
/// carry it, so the transport's `500` has none; the id is still in the context for an access log.
///
/// - Parameters:
///   - header: The header the id travels in. `X-Request-ID` by default.
///   - generate: Makes an id when none is offered. A UUID by default; tests pass a counter.
public func requestID(
    header: HTTPField.Name = .requestID,
    generate: @escaping @Sendable () -> String = { UUID().uuidString }
) -> Middleware {
    { request, next in
        var request = request
        let offered = request.headers[header]
        let id = offered.flatMap { isSafeRequestID($0) ? $0 : nil } ?? generate()
        request.context[RequestID.self] = id
        var response = try await next(request)
        response.headers[header] = id
        return response
    }
}

private func isSafeRequestID(_ candidate: String) -> Bool {
    let bytes = candidate.utf8
    guard (1...64).contains(bytes.count) else { return false }
    return bytes.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2E || byte == 0x5F || byte == 0x2D
    }
}
