// Middleware.swift
// SwiftHTTPService
//
// Handlers, and what wraps them.

/// Turns a request into a response. An error that escapes is the transport's to turn into a `500`.
public typealias Handler = @Sendable (Request) async throws -> Response

/// Runs around a handler: it may refuse the request, change it for what follows, call `next`, and change
/// the response on the way out.
public typealias Middleware = @Sendable (Request, Handler) async throws -> Response

/// Wraps `handler` in `middleware`, the first being outermost: it sees a request first and a response last.
public func wrap(_ handler: @escaping Handler, with middleware: [Middleware]) -> Handler {
    middleware.reversed().reduce(handler) { inner, layer in
        { request in try await layer(request, inner) }
    }
}
