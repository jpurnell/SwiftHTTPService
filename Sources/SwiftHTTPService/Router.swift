// Router.swift
// SwiftHTTPService
//
// Method and path to handler.

import Foundation
import HTTPTypes

/// Why a route could not be registered. Both are mistakes in the program, found when it starts, never when
/// a request arrives.
public enum RouterError: Error, Equatable, Sendable {
    /// The pattern is not well formed.
    case invalidPattern(String)
    /// The method and shape are already registered (parameter names do not make a shape different).
    case duplicate(method: String, pattern: String)
    /// The route's body bound is outside 0 to 64 MiB. Names the pattern and never the number.
    case invalidBodyLimit(String)
}

/// Maps a method and a path to a handler.
///
/// A pattern is `/` followed by segments separated by `/`. A segment is a literal or `{name}`, which matches
/// exactly one non-empty segment and captures its decoded value. There are no wildcards, no regular
/// expressions and no optional segments. A trailing slash is a different path.
///
/// When more than one pattern fits a path, the most specific wins by a fixed rule: moving left to right, a
/// literal segment beats a parameter. Registration order never changes the outcome. If the winning path has
/// no handler for the method, the next most specific path that has one is used; if none has, the answer is
/// `405` with an `Allow` header listing every method any matching path has (and `HEAD` wherever `GET` is).
/// `HEAD` is served by the `GET` handler unless a `HEAD` handler is registered; the response keeps its body
/// for the transport to drop.
public struct Router: Sendable {

    /// Answers a path nothing matches. Replaceable, so a server can make its refusals indistinguishable.
    public var notFound: Handler

    /// Answers a path that exists under other methods, told which are allowed.
    public var methodNotAllowed: @Sendable (Request, [HTTPRequest.Method]) async throws -> Response

    private var root = Node()

    /// Creates a router. The defaults answer `404` and `405` as problem details.
    public init(
        notFound: @escaping Handler = { _ in try .problem(Problem(status: .notFound, code: "not_found")) },
        methodNotAllowed: @escaping @Sendable (Request, [HTTPRequest.Method]) async throws -> Response = { _, allowed in
            try Response.problem(Problem(status: .methodNotAllowed, code: "method_not_allowed"))
                .setting(.allow, to: allowed.map(\.rawValue).joined(separator: ", "))
        }
    ) {
        self.notFound = notFound
        self.methodNotAllowed = methodNotAllowed
    }

    // MARK: Registering

    /// Registers a handler.
    ///
    /// - Parameters:
    ///   - method: The method.
    ///   - pattern: The path pattern.
    ///   - maximumBodyBytes: A body bound for this route alone, in bytes, 0 to 64 MiB, replacing the server's
    ///     global bound whether it is lower or higher. The transport asks for it (``maximumBodyBytes(for:target:)``)
    ///     after the head and before it reads any body, so a body past it is refused unread. Nil means the global
    ///     bound. A route that does not exist, or lacks the method, has no override.
    ///   - middleware: Layers for this route only, the first outermost, inside any layers wrapped around the whole
    ///     router. A login route takes a tighter `rateLimit` than the rest this way.
    ///   - handler: The handler.
    /// - Throws: ``RouterError``. A refused registration changes nothing.
    public mutating func add(
        _ method: HTTPRequest.Method, _ pattern: String, maximumBodyBytes: Int? = nil, middleware: [Middleware] = [],
        _ handler: @escaping Handler
    ) throws(RouterError) {
        let segments = try Self.parse(pattern)
        if let maximumBodyBytes, !(0...67_108_864).contains(maximumBodyBytes) { throw .invalidBodyLimit(pattern) }
        let names = segments.compactMap { segment -> String? in
            if case .parameter(let name) = segment { return name }
            return nil
        }
        let route = Route(handler: wrap(handler, with: middleware), names: names, maximumBodyBytes: maximumBodyBytes)
        guard root.insert(segments[...], method: method, route: route) else {
            throw .duplicate(method: method.rawValue, pattern: pattern)
        }
    }

    /// Registers a `GET` handler.
    public mutating func get(
        _ pattern: String, maximumBodyBytes: Int? = nil, middleware: [Middleware] = [], _ handler: @escaping Handler
    ) throws(RouterError) { try add(.get, pattern, maximumBodyBytes: maximumBodyBytes, middleware: middleware, handler) }
    /// Registers a `POST` handler.
    public mutating func post(
        _ pattern: String, maximumBodyBytes: Int? = nil, middleware: [Middleware] = [], _ handler: @escaping Handler
    ) throws(RouterError) { try add(.post, pattern, maximumBodyBytes: maximumBodyBytes, middleware: middleware, handler) }
    /// Registers a `PUT` handler.
    public mutating func put(
        _ pattern: String, maximumBodyBytes: Int? = nil, middleware: [Middleware] = [], _ handler: @escaping Handler
    ) throws(RouterError) { try add(.put, pattern, maximumBodyBytes: maximumBodyBytes, middleware: middleware, handler) }
    /// Registers a `PATCH` handler.
    public mutating func patch(
        _ pattern: String, maximumBodyBytes: Int? = nil, middleware: [Middleware] = [], _ handler: @escaping Handler
    ) throws(RouterError) { try add(.patch, pattern, maximumBodyBytes: maximumBodyBytes, middleware: middleware, handler) }
    /// Registers a `DELETE` handler.
    public mutating func delete(
        _ pattern: String, maximumBodyBytes: Int? = nil, middleware: [Middleware] = [], _ handler: @escaping Handler
    ) throws(RouterError) { try add(.delete, pattern, maximumBodyBytes: maximumBodyBytes, middleware: middleware, handler) }

    // MARK: Serving

    /// This router as a handler, to be wrapped in middleware and given to a transport.
    public var handler: Handler {
        let router = self
        return { request in try await router.route(request) }
    }

    /// The route that serves a method among the paths that fit, most specific first: the method's own handler, or
    /// for `HEAD` the `GET` handler. The one rule, used both to serve and to look up a limit.
    private static func winning(
        among matches: [(routes: [HTTPRequest.Method: Route], captured: [String])], for method: HTTPRequest.Method
    ) -> (route: Route, captured: [String])? {
        for match in matches {
            if let route = match.routes[method] ?? (method == .head ? match.routes[.get] : nil) {
                return (route, match.captured)
            }
        }
        return nil
    }

    /// The body bound registered for the route that would serve `method` and `target`, or nil if there is none
    /// (no such route, no override on it, or a target that does not parse).
    ///
    /// Asked by the transport after the head and before any body is read, so a route can take a bound different
    /// from the server's. It follows the same rule as serving, so it can never name a different route.
    public func maximumBodyBytes(for method: HTTPRequest.Method, target: String) -> Int? {
        let built = Result { try Request(method: method, target: target, headers: HTTPFields(), body: Data()) }
        guard case .success(let probe) = built else { return nil }
        var matches: [(routes: [HTTPRequest.Method: Route], captured: [String])] = []
        root.collect(probe.pathSegments[...], captured: [], into: &matches)
        return Self.winning(among: matches, for: method)?.route.maximumBodyBytes
    }

    /// Finds the handler for a request and runs it.
    public func route(_ request: Request) async throws -> Response {
        var matches: [(routes: [HTTPRequest.Method: Route], captured: [String])] = []
        root.collect(request.pathSegments[...], captured: [], into: &matches)
        guard !matches.isEmpty else { return try await notFound(request) }

        if let found = Self.winning(among: matches, for: request.method) {
            var routed = request
            routed.pathParameters = Dictionary(uniqueKeysWithValues: zip(found.route.names, found.captured))
            return try await found.route.handler(routed)
        }

        var allowed = Set(matches.flatMap { $0.routes.keys.map(\.rawValue) })
        if allowed.contains(HTTPRequest.Method.get.rawValue) { allowed.insert(HTTPRequest.Method.head.rawValue) }
        let methods = allowed.sorted().compactMap { HTTPRequest.Method($0) }
        return try await methodNotAllowed(request, methods)
    }

    // MARK: The tree

    private enum Segment: Equatable {
        case literal(String)
        case parameter(String)
    }

    private struct Route: Sendable {
        let handler: Handler
        let names: [String]
        let maximumBodyBytes: Int?
    }

    /// One position in a path. Literals are looked up by name; a parameter, if any, is the single other child.
    private struct Node: Sendable {
        var literals: [String: Node] = [:]
        var parameter: [Node] = []   // zero or one; an array only because a struct cannot contain itself
        var routes: [HTTPRequest.Method: Route] = [:]

        /// Returns false if the method is already registered at this shape.
        mutating func insert(_ segments: ArraySlice<Segment>, method: HTTPRequest.Method, route: Route) -> Bool {
            guard let first = segments.first else {
                guard routes[method] == nil else { return false }
                routes[method] = route
                return true
            }
            switch first {
            case .literal(let text):
                var child = literals[text] ?? Node()
                let inserted = child.insert(segments.dropFirst(), method: method, route: route)
                literals[text] = child
                return inserted
            case .parameter:
                var child = parameter.first ?? Node()
                let inserted = child.insert(segments.dropFirst(), method: method, route: route)
                parameter = [child]
                return inserted
            }
        }

        /// Every path that fits, most specific first: a literal child is tried before the parameter child at
        /// each position, which is the leftmost-literal rule.
        func collect(
            _ segments: ArraySlice<String>, captured: [String],
            into matches: inout [(routes: [HTTPRequest.Method: Route], captured: [String])]
        ) {
            guard let first = segments.first else {
                if !routes.isEmpty { matches.append((routes, captured)) }
                return
            }
            literals[first]?.collect(segments.dropFirst(), captured: captured, into: &matches)
            if !first.isEmpty, let child = parameter.first {
                child.collect(segments.dropFirst(), captured: captured + [first], into: &matches)
            }
        }
    }

    private static func parse(_ pattern: String) throws(RouterError) -> [Segment] {
        guard pattern.hasPrefix("/") else { throw .invalidPattern(pattern) }
        guard pattern != "/" else { return [] }
        let pieces = pattern.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        var seen = Set<String>()
        var segments: [Segment] = []
        for piece in pieces {
            guard !piece.isEmpty else { throw .invalidPattern(pattern) }
            if piece.hasPrefix("{") {
                guard piece.hasSuffix("}") else { throw .invalidPattern(pattern) }
                let name = String(piece.dropFirst().dropLast())
                guard isName(name), seen.insert(name).inserted else { throw .invalidPattern(pattern) }
                segments.append(.parameter(name))
            } else {
                guard piece.allSatisfy(isLiteralCharacter) else { throw .invalidPattern(pattern) }
                segments.append(.literal(String(piece)))
            }
        }
        return segments
    }

    private static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first == "_" || first.properties.isAlphabetic, first.isASCII else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0)) }
    }

    /// Printable ASCII, except the characters a request target gives another meaning.
    private static func isLiteralCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return false }
        return scalar.value > 0x20 && scalar.value < 0x7F && !"{}%?#".unicodeScalars.contains(scalar)
    }
}
