// ServiceConfiguration.swift
// SwiftHTTPService
//
// What a server is told, validated before it starts.

import Foundation

/// A configuration value that was refused. It names the field and the kind of fault, and never the
/// value: a path or a host can be a secret, and an error is something people log.
public struct ConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The kind of fault.
    public enum Reason: String, Sendable, Equatable {
        /// A required text value is empty or blank.
        case empty
        /// A number or duration is outside the range the field allows.
        case outOfRange
        /// A text value holds a character it cannot.
        case malformed
    }

    /// The field, as a dotted path (`limits.idleTimeout`).
    public let field: String
    /// The kind of fault.
    public let reason: Reason

    /// Creates an error.
    public init(field: String, reason: Reason) {
        self.field = field
        self.reason = reason
    }

    /// `field: reason`, with no value in it.
    public var description: String { "configuration \(field) is \(reason.rawValue)" }
}

/// The files a server's TLS identity is read from. Paths only: the server reads the files when it
/// starts, and a configuration never holds a key.
public struct TLSFiles: Sendable, Equatable {
    /// The PEM certificate chain, leaf first.
    public let certificateChainPath: String
    /// The PEM private key.
    public let privateKeyPath: String

    /// Creates the pair. Whether the files exist and match is checked when the server starts.
    public init(certificateChainPath: String, privateKeyPath: String) {
        self.certificateChainPath = certificateChainPath
        self.privateKeyPath = privateKeyPath
    }
}

/// The bounds a server enforces. The defaults are conservative for a small JSON API; each value is
/// range-checked by ``ServiceConfiguration``, and none is clamped.
public struct Limits: Sendable, Equatable {
    /// The largest request line plus headers, in bytes. 1 KiB to 1 MiB. Default 16 KiB.
    public var maximumHeaderBytes: Int
    /// The most header fields. 1 to 1000. Default 100.
    public var maximumHeaderCount: Int
    /// The largest request body, in bytes. 0 (no bodies) to 64 MiB. Default 1 MiB.
    public var maximumBodyBytes: Int
    /// How long a request's header may take to arrive once its first byte has. Above zero, at most an
    /// hour. Default 10 s.
    public var headerReadTimeout: Duration
    /// How long a request's body may take to arrive once its header has. Above zero, at most an hour.
    /// Default 30 s.
    public var bodyReadTimeout: Duration
    /// How long a keep-alive connection may wait for its next request. Above zero, at most an hour.
    /// Default 60 s.
    public var idleTimeout: Duration
    /// The most connections served at once. 1 to 100,000. Default 256.
    public var maximumConnections: Int
    /// How long a graceful shutdown lets in-flight requests finish. Zero to ten minutes. Default 10 s.
    public var shutdownGrace: Duration

    /// Creates limits; anything not given is the default.
    public init(
        maximumHeaderBytes: Int = 16 * 1024,
        maximumHeaderCount: Int = 100,
        maximumBodyBytes: Int = 1024 * 1024,
        headerReadTimeout: Duration = .seconds(10),
        bodyReadTimeout: Duration = .seconds(30),
        idleTimeout: Duration = .seconds(60),
        maximumConnections: Int = 256,
        shutdownGrace: Duration = .seconds(10)
    ) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumHeaderCount = maximumHeaderCount
        self.maximumBodyBytes = maximumBodyBytes
        self.headerReadTimeout = headerReadTimeout
        self.bodyReadTimeout = bodyReadTimeout
        self.idleTimeout = idleTimeout
        self.maximumConnections = maximumConnections
        self.shutdownGrace = shutdownGrace
    }
}

/// Everything a server needs to know before it starts.
///
/// Built through a throwing initialiser, so an instance is always valid. The host defaults to the
/// loopback address: serving every interface (`0.0.0.0`) is a choice made by name.
///
/// No two values are checked against each other: each range is justified on its own, and a rule such as
/// "the idle timeout must exceed the header timeout" would reject configurations that work (the idle
/// timer runs between requests, the header timer within one).
public struct ServiceConfiguration: Sendable, Equatable {
    /// The address to bind: a host name or an IP literal.
    public let host: String
    /// The port to bind. Zero asks the system for a free one.
    public let port: UInt16
    /// The TLS identity, or nil to serve plain HTTP.
    public let tls: TLSFiles?
    /// The bounds.
    public let limits: Limits

    /// Creates a configuration.
    ///
    /// - Throws: ``ConfigurationError`` naming the first field that is refused.
    public init(host: String = "127.0.0.1", port: UInt16 = 8080, tls: TLSFiles? = nil, limits: Limits = Limits()) throws(ConfigurationError) {
        try Self.validate(host: host)
        if let tls {
            try Self.validate(path: tls.certificateChainPath, field: "tls.certificateChainPath")
            try Self.validate(path: tls.privateKeyPath, field: "tls.privateKeyPath")
        }
        try Self.validate(limits)
        self.host = host
        self.port = port
        self.tls = tls
        self.limits = limits
    }

    // MARK: Validation

    private static let hour = Duration.seconds(3600)

    private static func validate(host: String) throws(ConfigurationError) {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError(field: "host", reason: .empty)
        }
        let forbidden = host.unicodeScalars.contains { scalar in
            scalar.properties.isWhitespace || CharacterSet.controlCharacters.contains(scalar) || scalar == "/"
        }
        guard !forbidden else { throw ConfigurationError(field: "host", reason: .malformed) }
    }

    private static func validate(path: String, field: String) throws(ConfigurationError) {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError(field: field, reason: .empty)
        }
        guard !path.unicodeScalars.contains("\u{0}") else {
            throw ConfigurationError(field: field, reason: .malformed)
        }
    }

    private static func validate(_ limits: Limits) throws(ConfigurationError) {
        try require((1024...1_048_576).contains(limits.maximumHeaderBytes), "limits.maximumHeaderBytes")
        try require((1...1000).contains(limits.maximumHeaderCount), "limits.maximumHeaderCount")
        try require((0...64 * 1024 * 1024).contains(limits.maximumBodyBytes), "limits.maximumBodyBytes")
        try require(limits.headerReadTimeout > .zero && limits.headerReadTimeout <= hour, "limits.headerReadTimeout")
        try require(limits.bodyReadTimeout > .zero && limits.bodyReadTimeout <= hour, "limits.bodyReadTimeout")
        try require(limits.idleTimeout > .zero && limits.idleTimeout <= hour, "limits.idleTimeout")
        try require((1...100_000).contains(limits.maximumConnections), "limits.maximumConnections")
        try require(limits.shutdownGrace >= .zero && limits.shutdownGrace <= .seconds(600), "limits.shutdownGrace")
    }

    private static func require(_ condition: Bool, _ field: String) throws(ConfigurationError) {
        guard condition else { throw ConfigurationError(field: field, reason: .outOfRange) }
    }
}
