// Refusal.swift
// SwiftHTTPServiceNIO
//
// The refusals the transport itself makes, each a fixed body.

import Foundation

/// A response the transport writes without asking the handler: a request it will not pass on, or a failure
/// of its own.
///
/// Every body is a constant, byte for byte what the core's `Response.problem` produces for the same status
/// and code (a test holds the two together). Nothing the peer sent, and no error text, is ever in one: a
/// refusal that echoed a target or an exception would be a way to read the server's insides.
enum Refusal: Error, Sendable, Equatable, CaseIterable {
    case badRequest
    case malformedTarget
    case requestTimeout
    case bodyTooLarge
    case expectationFailed
    case headersTooLarge
    case internalError
    /// A connection past `Limits.maximumConnections`, told so before anything is read from it.
    case serviceUnavailable
    /// A request line whose HTTP major version is not 1.
    case versionNotSupported

    var statusCode: Int {
        switch self {
        case .badRequest, .malformedTarget: 400
        case .requestTimeout: 408
        case .bodyTooLarge: 413
        case .expectationFailed: 417
        case .headersTooLarge: 431
        case .internalError: 500
        case .serviceUnavailable: 503
        case .versionNotSupported: 505
        }
    }

    var code: String {
        switch self {
        case .badRequest: "bad_request"
        case .malformedTarget: "malformed_target"
        case .requestTimeout: "request_timeout"
        case .bodyTooLarge: "body_too_large"
        case .expectationFailed: "expectation_failed"
        case .headersTooLarge: "headers_too_large"
        case .internalError: "internal_error"
        case .serviceUnavailable: "service_unavailable"
        case .versionNotSupported: "http_version_not_supported"
        }
    }

    /// The JSON body, with keys in sorted order as the core's encoder writes them.
    var body: Data {
        Data(#"{"code":"\#(code)","status":\#(statusCode),"title":"\#(title)","type":"about:blank"}"#.utf8)
    }

    private var title: String {
        switch self {
        case .badRequest, .malformedTarget: "Bad Request"
        case .requestTimeout: "Request Timeout"
        case .bodyTooLarge: "Content Too Large"
        case .expectationFailed: "Expectation Failed"
        case .headersTooLarge: "Request Header Fields Too Large"
        case .internalError: "Internal Server Error"
        case .serviceUnavailable: "Service Unavailable"
        case .versionNotSupported: "HTTP Version Not Supported"
        }
    }
}
