// Request.swift
// SwiftHTTPService
//
// A parsed request, as a router and a handler see it.

import Foundation
import HTTPTypes

/// Why a request could not be built.
public enum RequestError: Error, Equatable, Sendable {
    /// The request target is not a well-formed, unambiguous origin-form target. The transport answers `400`.
    case malformedTarget
}

/// One `name=value` pair of a query string, decoded. `value` is nil for a bare `name`.
public struct QueryItem: Sendable, Hashable {
    /// The decoded name.
    public let name: String
    /// The decoded value, or nil when the pair had no `=`.
    public let value: String?

    /// Creates a query item.
    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// The version of HTTP that carried a request.
///
/// A handler should not need it: the same handler serves every version. It is here for what does, such as a
/// log line, a metric, or a refusal that only makes sense for one.
public enum HTTPProtocolVersion: Sendable, Hashable, CustomStringConvertible {
    /// HTTP/1.0.
    case http1_0
    /// HTTP/1.1.
    case http1_1
    /// HTTP/2.
    case http2

    /// The version as the protocol writes it.
    public var description: String {
        switch self {
        case .http1_0: "HTTP/1.0"
        case .http1_1: "HTTP/1.1"
        case .http2: "HTTP/2"
        }
    }
}

/// An HTTP request after its target has been parsed, strictly and once.
///
/// The target must be origin-form (`/path?query`) and unambiguous. A path is split into segments
/// *before* percent-decoding, so an encoded slash stays inside its segment and can never change which
/// route matches. Dot segments, empty segments (other than a trailing one), a fragment, a raw space or
/// control character, a bad escape and a decoded NUL are all refused rather than normalised: a router
/// that never sees an ambiguous path cannot be tricked by one.
public struct Request: Sendable {
    /// The method.
    public let method: HTTPRequest.Method
    /// The request target exactly as sent, path and query.
    public let target: String
    /// The path part of the target, still percent-encoded.
    public let path: String
    /// The path split on `/` and then percent-decoded. `/` is `[]`; `/a/` is `["a", ""]`.
    public let pathSegments: [String]
    /// The query as decoded pairs, in the order sent, duplicates kept.
    public let query: [QueryItem]
    /// The header fields.
    public let headers: HTTPFields
    /// The body, already within the transport's limit.
    public let body: Data
    /// The client's address, if the transport knows it. Behind a trusted proxy this is the client the proxy
    /// reported (see ``ServiceConfiguration/Forwarding``); otherwise it is the socket's peer. Rate limits and
    /// access logs key on this.
    public let remoteAddress: String?
    /// The address of the socket's peer, whatever a proxy said. The same as ``remoteAddress`` unless the request
    /// came through a trusted proxy.
    public let peerAddress: String?
    /// The version of HTTP that carried the request. HTTP/1.1 for a request built without one.
    public let httpVersion: HTTPProtocolVersion
    /// Values the router captured from `{name}` segments.
    public internal(set) var pathParameters: [String: String]
    /// Values middleware have attached.
    public var context: Context

    /// Parses `target` and builds a request.
    ///
    /// - Throws: ``RequestError/malformedTarget``.
    public init(
        method: HTTPRequest.Method, target: String, headers: HTTPFields, body: Data, remoteAddress: String? = nil,
        httpVersion: HTTPProtocolVersion = .http1_1, peerAddress: String? = nil
    ) throws(RequestError) {
        let parts = try Self.parse(target)
        self.method = method
        self.target = target
        self.path = parts.path
        self.pathSegments = parts.segments
        self.query = parts.query
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
        self.peerAddress = peerAddress ?? remoteAddress
        self.httpVersion = httpVersion
        self.pathParameters = [:]
        self.context = Context()
    }

    /// The first value for `name` in the query, or nil when absent or when the pair had no value.
    public func firstQueryValue(named name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    // MARK: Parsing

    private struct Parts {
        let path: String
        let segments: [String]
        let query: [QueryItem]
    }

    private static func parse(_ target: String) throws(RequestError) -> Parts {
        let bytes = Array(target.utf8)
        guard bytes.first == UInt8(ascii: "/") else { throw .malformedTarget }
        // Printable ASCII only, and no fragment: anything else must arrive percent-encoded.
        guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "#") }) else {
            throw .malformedTarget
        }
        let split = bytes.firstIndex(of: UInt8(ascii: "?"))
        let pathBytes = bytes[..<(split ?? bytes.endIndex)]
        let queryBytes = split.map { bytes[bytes.index(after: $0)...] } ?? []

        let body = pathBytes.dropFirst()
        var segments: [String] = []
        if !body.isEmpty {
            let pieces = body.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                let isLast = index == pieces.count - 1
                if piece.isEmpty {
                    guard isLast else { throw .malformedTarget }
                    segments.append("")
                    continue
                }
                let decoded = try decode(piece)
                guard decoded != ".", decoded != ".." else { throw .malformedTarget }
                segments.append(decoded)
            }
        }

        var items: [QueryItem] = []
        for piece in queryBytes.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: true) {
            if let equals = piece.firstIndex(of: UInt8(ascii: "=")) {
                items.append(QueryItem(
                    name: try decode(piece[..<equals]), value: try decode(piece[piece.index(after: equals)...])))
            } else {
                items.append(QueryItem(name: try decode(piece), value: nil))
            }
        }
        return Parts(path: String(decoding: pathBytes, as: UTF8.self), segments: segments, query: items)
    }

    /// Percent-decodes bytes that are already known to be printable ASCII. A plus is a plus.
    private static func decode(_ bytes: ArraySlice<UInt8>) throws(RequestError) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                let high = bytes.index(after: index)
                guard high < bytes.endIndex else { throw .malformedTarget }
                let low = bytes.index(after: high)
                guard low < bytes.endIndex, let h = hexValue(bytes[high]), let l = hexValue(bytes[low]) else {
                    throw .malformedTarget
                }
                out.append(h << 4 | l)
                index = bytes.index(after: low)
            } else {
                out.append(byte)
                index = bytes.index(after: index)
            }
        }
        // A NUL has no business in a name, and invalid UTF-8 would make two spellings of one string.
        guard !out.contains(0), let text = String(bytes: out, encoding: .utf8) else {
            throw .malformedTarget
        }
        return text
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
