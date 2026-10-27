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
    /// - Throws: ``RouterError``.
    public mutating func add(_ method: HTTPRequest.Method, _ pattern: String, _ handler: @escaping Handler) throws(RouterError) {
        let segments = try Self.parse(pattern)
        let names = segments.compactMap { segment -> String? in
            if case .parameter(let name) = segment { return name }
            return nil
        }
        guard root.insert(segments[...], method: method, route: Route(handler: handler, names: names)) else {
            throw .duplicate(method: method.rawValue, pattern: pattern)
        }
    }

    /// Registers a `GET` handler.
    public mutating func get(_ pattern: String, _ handler: @escaping Handler) throws(RouterError) { try add(.get, pattern, handler) }
    /// Registers a `POST` handler.
    public mutating func post(_ pattern: String, _ handler: @escaping Handler) throws(RouterError) { try add(.post, pattern, handler) }
    /// Registers a `PUT` handler.
    public mutating func put(_ pattern: String, _ handler: @escaping Handler) throws(RouterError) { try add(.put, pattern, handler) }
    /// Registers a `PATCH` handler.
    public mutating func patch(_ pattern: String, _ handler: @escaping Handler) throws(RouterError) { try add(.patch, pattern, handler) }
    /// Registers a `DELETE` handler.
    public mutating func delete(_ pattern: String, _ handler: @escaping Handler) throws(RouterError) { try add(.delete, pattern, handler) }

    // MARK: Serving

    /// This router as a handler, to be wrapped in middleware and given to a transport.
    public var handler: Handler {
        let router = self
        return { request in try await router.route(request) }
    }

    /// Finds the handler for a request and runs it.
    public func route(_ request: Request) async throws -> Response {
        var matches: [(routes: [HTTPRequest.Method: Route], captured: [String])] = []
        root.collect(request.pathSegments[...], captured: [], into: &matches)
        guard !matches.isEmpty else { return try await notFound(request) }

        for match in matches {
            let route = match.routes[request.method] ?? (request.method == .head ? match.routes[.get] : nil)
            guard let route else { continue }
            var routed = request
            routed.pathParameters = Dictionary(uniqueKeysWithValues: zip(route.names, match.captured))
            return try await route.handler(routed)
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
