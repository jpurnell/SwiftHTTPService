import Foundation
import Testing
@testable import SwiftHTTPService

/// A configuration that contradicts itself refuses to start. There is no silent clamping, and an error
/// names the field and never repeats the value, since a path or a host can be a secret in a log.
@Suite("Service configuration")
struct ServiceConfigurationTests {

    // MARK: Defaults

    @Test("The defaults are the conservative ones the design states")
    func defaults() throws {
        let configuration = try ServiceConfiguration()
        #expect(configuration.host == "127.0.0.1")          // loopback unless the caller opts in to more
        #expect(configuration.port == 8080)
        #expect(configuration.tls == nil)
        let limits = configuration.limits
        #expect(limits.maximumHeaderBytes == 16 * 1024)
        #expect(limits.maximumHeaderCount == 100)
        #expect(limits.maximumBodyBytes == 1024 * 1024)
        #expect(limits.headerReadTimeout == .seconds(10))
        #expect(limits.bodyReadTimeout == .seconds(30))
        #expect(limits.idleTimeout == .seconds(60))
        #expect(limits.maximumConnections == 256)
        #expect(limits.shutdownGrace == .seconds(10))
        #expect(limits.maximumConcurrentStreams == 100)     // the RFC 9113 suggested minimum (design H3)
        #expect(limits.maximumStreamDuration == .seconds(3600))
        #expect(limits.maximumStreamBytes == 1 << 30)       // 1 GiB
        #expect(limits.streamWriteTimeout == .seconds(30))
        #expect(configuration.protocols == .http1AndHTTP2)  // design H2
        #expect(configuration.connections == .keepAlive)    // connections are reused unless asked otherwise
        #expect(configuration.trustedProxies.isEmpty)       // nothing is trusted unless named
        #expect(configuration.forwarding == .none)
    }

    @Test("Trusted proxies and a forwarding mode are kept as given, and the blocks are parsed")
    func proxiesSet() throws {
        let configuration = try ServiceConfiguration(trustedProxies: ["10.0.0.0/8", "::1"], forwarding: .xForwardedFor)
        #expect(configuration.forwarding == .xForwardedFor)
        #expect(configuration.trustedProxies.map(\.description) == ["10.0.0.0/8", "::1/128"])
        #expect(try ServiceConfiguration(trustedProxies: ["10.0.0.1"]).forwarding == .none)   // a list alone trusts nothing yet
    }

    @Test("Forwarding with nobody trusted is refused: it would believe no one")
    func forwardingNeedsProxies() {
        #expect(throws: ConfigurationError(field: "trustedProxies", reason: .empty)) { _ = try ServiceConfiguration(forwarding: .xForwardedFor) }
        #expect(throws: ConfigurationError(field: "trustedProxies", reason: .empty)) { _ = try ServiceConfiguration(forwarding: .proxyProtocol) }
    }

    @Test("A malformed block is refused naming the field, not the text, and so is the block of every address")
    func badProxies() {
        #expect(throws: ConfigurationError(field: "trustedProxies", reason: .malformed)) { _ = try ServiceConfiguration(trustedProxies: ["10.0.0.0/8", "nope"]) }
        #expect(throws: ConfigurationError(field: "trustedProxies", reason: .malformed)) { _ = try ServiceConfiguration(trustedProxies: ["0.0.0.0/0"], forwarding: .xForwardedFor) }
    }

    @Test("The connection mode can be set to close after each response, and nothing else is changed by it")
    func connectionsSet() throws {
        let closing = try ServiceConfiguration(connections: .closeAfterResponse)
        let defaults = try ServiceConfiguration()
        #expect(closing.connections == .closeAfterResponse)
        #expect(closing.host == defaults.host)
        #expect(closing.port == defaults.port)
        #expect(closing.limits == defaults.limits)
        #expect(closing.protocols == defaults.protocols)
        #expect(closing != defaults)                         // it is part of what a configuration is
    }

    @Test("The protocols can be narrowed to HTTP/1.1 and nothing else is changed by it")
    func protocolsNarrowed() throws {
        let narrowed = try ServiceConfiguration(protocols: .http1)
        let defaults = try ServiceConfiguration()
        #expect(narrowed.protocols == .http1)
        #expect(narrowed.host == defaults.host)
        #expect(narrowed.port == defaults.port)
        #expect(narrowed.limits == defaults.limits)
    }

    @Test("The streaming bounds accept their edges")
    func streamingEdges() throws {
        var limits = Limits()
        limits.maximumStreamDuration = .nanoseconds(1)
        limits.maximumStreamBytes = 1
        limits.streamWriteTimeout = .nanoseconds(1)
        #expect(try ServiceConfiguration(limits: limits).limits == limits)
        limits.maximumStreamDuration = .seconds(86_400)
        limits.maximumStreamBytes = 1 << 40
        limits.streamWriteTimeout = .seconds(3600)
        #expect(try ServiceConfiguration(limits: limits).limits == limits)
    }

    @Test("The stream bound accepts its edges, 1 and 1000")
    func streamBoundEdges() throws {
        var limits = Limits()
        limits.maximumConcurrentStreams = 1
        #expect(try ServiceConfiguration(limits: limits).limits.maximumConcurrentStreams == 1)
        limits.maximumConcurrentStreams = 1000
        #expect(try ServiceConfiguration(limits: limits).limits.maximumConcurrentStreams == 1000)
    }

    @Test("The default limits are themselves valid")
    func defaultLimitsAreValid() throws {
        let configuration = try ServiceConfiguration(limits: Limits())
        #expect(configuration.limits == Limits())
    }

    @Test("Port zero is allowed, for an ephemeral port")
    func ephemeralPort() throws {
        #expect(try ServiceConfiguration(port: 0).port == 0)
    }

    @Test("Binding every interface is allowed when asked for by name")
    func allInterfaces() throws {
        #expect(try ServiceConfiguration(host: "0.0.0.0").host == "0.0.0.0")
    }

    // MARK: Refusals

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let field: String
        let reason: ConfigurationError.Reason
        let build: @Sendable () throws -> ServiceConfiguration
        var testDescription: String { name }
    }

    private static func limits(_ edit: @escaping @Sendable (inout Limits) -> Void) -> @Sendable () throws -> ServiceConfiguration {
        {
            var limits = Limits()
            edit(&limits)
            return try ServiceConfiguration(limits: limits)
        }
    }

    static let refused: [Case] = [
        Case(name: "no concurrent streams", field: "limits.maximumConcurrentStreams", reason: .outOfRange, build: limits { $0.maximumConcurrentStreams = 0 }),
        Case(name: "negative concurrent streams", field: "limits.maximumConcurrentStreams", reason: .outOfRange, build: limits { $0.maximumConcurrentStreams = -1 }),
        Case(name: "too many concurrent streams", field: "limits.maximumConcurrentStreams", reason: .outOfRange, build: limits { $0.maximumConcurrentStreams = 1001 }),
        Case(name: "zero stream duration", field: "limits.maximumStreamDuration", reason: .outOfRange, build: limits { $0.maximumStreamDuration = .zero }),
        Case(name: "negative stream duration", field: "limits.maximumStreamDuration", reason: .outOfRange, build: limits { $0.maximumStreamDuration = .seconds(-1) }),
        Case(name: "stream duration over a day", field: "limits.maximumStreamDuration", reason: .outOfRange, build: limits { $0.maximumStreamDuration = .seconds(86_401) }),
        Case(name: "no stream bytes", field: "limits.maximumStreamBytes", reason: .outOfRange, build: limits { $0.maximumStreamBytes = 0 }),
        Case(name: "negative stream bytes", field: "limits.maximumStreamBytes", reason: .outOfRange, build: limits { $0.maximumStreamBytes = -1 }),
        Case(name: "stream bytes over a tebibyte", field: "limits.maximumStreamBytes", reason: .outOfRange, build: limits { $0.maximumStreamBytes = (1 << 40) + 1 }),
        Case(name: "zero stream write timeout", field: "limits.streamWriteTimeout", reason: .outOfRange, build: limits { $0.streamWriteTimeout = .zero }),
        Case(name: "stream write timeout over an hour", field: "limits.streamWriteTimeout", reason: .outOfRange, build: limits { $0.streamWriteTimeout = .seconds(3601) }),
        Case(name: "empty host", field: "host", reason: .empty, build: { try ServiceConfiguration(host: "") }),
        Case(name: "blank host", field: "host", reason: .empty, build: { try ServiceConfiguration(host: "   ") }),
        Case(name: "host with a space", field: "host", reason: .malformed, build: { try ServiceConfiguration(host: "a b") }),
        Case(name: "host with a newline", field: "host", reason: .malformed, build: { try ServiceConfiguration(host: "a\nb") }),
        Case(name: "host with a slash", field: "host", reason: .malformed, build: { try ServiceConfiguration(host: "a/b") }),

        Case(name: "header bytes below the floor", field: "limits.maximumHeaderBytes", reason: .outOfRange, build: limits { $0.maximumHeaderBytes = 1023 }),
        Case(name: "header bytes zero", field: "limits.maximumHeaderBytes", reason: .outOfRange, build: limits { $0.maximumHeaderBytes = 0 }),
        Case(name: "header bytes negative", field: "limits.maximumHeaderBytes", reason: .outOfRange, build: limits { $0.maximumHeaderBytes = -1 }),
        Case(name: "header bytes above the ceiling", field: "limits.maximumHeaderBytes", reason: .outOfRange, build: limits { $0.maximumHeaderBytes = 1_048_577 }),
        Case(name: "header count zero", field: "limits.maximumHeaderCount", reason: .outOfRange, build: limits { $0.maximumHeaderCount = 0 }),
        Case(name: "header count above the ceiling", field: "limits.maximumHeaderCount", reason: .outOfRange, build: limits { $0.maximumHeaderCount = 1001 }),
        Case(name: "body bytes negative", field: "limits.maximumBodyBytes", reason: .outOfRange, build: limits { $0.maximumBodyBytes = -1 }),
        Case(name: "body bytes above the ceiling", field: "limits.maximumBodyBytes", reason: .outOfRange, build: limits { $0.maximumBodyBytes = 64 * 1024 * 1024 + 1 }),
        Case(name: "header timeout zero", field: "limits.headerReadTimeout", reason: .outOfRange, build: limits { $0.headerReadTimeout = .zero }),
        Case(name: "header timeout negative", field: "limits.headerReadTimeout", reason: .outOfRange, build: limits { $0.headerReadTimeout = .seconds(-1) }),
        Case(name: "header timeout above the ceiling", field: "limits.headerReadTimeout", reason: .outOfRange, build: limits { $0.headerReadTimeout = .seconds(3601) }),
        Case(name: "body timeout zero", field: "limits.bodyReadTimeout", reason: .outOfRange, build: limits { $0.bodyReadTimeout = .zero }),
        Case(name: "body timeout above the ceiling", field: "limits.bodyReadTimeout", reason: .outOfRange, build: limits { $0.bodyReadTimeout = .seconds(3601) }),
        Case(name: "idle timeout zero", field: "limits.idleTimeout", reason: .outOfRange, build: limits { $0.idleTimeout = .zero }),
        Case(name: "idle timeout above the ceiling", field: "limits.idleTimeout", reason: .outOfRange, build: limits { $0.idleTimeout = .seconds(3601) }),
        Case(name: "connections zero", field: "limits.maximumConnections", reason: .outOfRange, build: limits { $0.maximumConnections = 0 }),
        Case(name: "connections above the ceiling", field: "limits.maximumConnections", reason: .outOfRange, build: limits { $0.maximumConnections = 100_001 }),
        Case(name: "grace negative", field: "limits.shutdownGrace", reason: .outOfRange, build: limits { $0.shutdownGrace = .seconds(-1) }),
        Case(name: "grace above the ceiling", field: "limits.shutdownGrace", reason: .outOfRange, build: limits { $0.shutdownGrace = .seconds(601) }),

        Case(name: "empty certificate path", field: "tls.certificateChainPath", reason: .empty, build: {
            try ServiceConfiguration(tls: TLSFiles(certificateChainPath: "", privateKeyPath: "/k.pem"))
        }),
        Case(name: "empty key path", field: "tls.privateKeyPath", reason: .empty, build: {
            try ServiceConfiguration(tls: TLSFiles(certificateChainPath: "/c.pem", privateKeyPath: " "))
        }),
        Case(name: "NUL in the certificate path", field: "tls.certificateChainPath", reason: .malformed, build: {
            try ServiceConfiguration(tls: TLSFiles(certificateChainPath: "/a\u{0}b", privateKeyPath: "/k.pem"))
        }),
        Case(name: "NUL in the key path", field: "tls.privateKeyPath", reason: .malformed, build: {
            try ServiceConfiguration(tls: TLSFiles(certificateChainPath: "/c.pem", privateKeyPath: "/a\u{0}b"))
        }),
    ]

    @Test("A bad value is refused, naming its field and the kind of fault", arguments: refused)
    func refusals(_ testCase: Case) {
        do {
            _ = try testCase.build()
            Issue.record("accepted: \(testCase.name)")
        } catch let error as ConfigurationError {
            #expect(error == ConfigurationError(field: testCase.field, reason: testCase.reason))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: The edges that are allowed

    struct EdgeCase: Sendable, CustomTestStringConvertible {
        let name: String
        let build: @Sendable () throws -> ServiceConfiguration
        var testDescription: String { name }
    }

    static let edges: [EdgeCase] = [
        EdgeCase(name: "header bytes at the floor", build: { try ServiceConfiguration(limits: Limits(maximumHeaderBytes: 1024)) }),
        EdgeCase(name: "header bytes at the ceiling", build: { try ServiceConfiguration(limits: Limits(maximumHeaderBytes: 1_048_576)) }),
        EdgeCase(name: "header count at 1", build: { try ServiceConfiguration(limits: Limits(maximumHeaderCount: 1)) }),
        EdgeCase(name: "header count at 1000", build: { try ServiceConfiguration(limits: Limits(maximumHeaderCount: 1000)) }),
        EdgeCase(name: "no bodies at all", build: { try ServiceConfiguration(limits: Limits(maximumBodyBytes: 0)) }),
        EdgeCase(name: "body at the ceiling", build: { try ServiceConfiguration(limits: Limits(maximumBodyBytes: 64 * 1024 * 1024)) }),
        EdgeCase(name: "timeouts at the ceiling", build: {
            try ServiceConfiguration(limits: Limits(headerReadTimeout: .seconds(3600), bodyReadTimeout: .seconds(3600), idleTimeout: .seconds(3600)))
        }),
        EdgeCase(name: "a sub-second timeout", build: { try ServiceConfiguration(limits: Limits(headerReadTimeout: .milliseconds(100))) }),
        EdgeCase(name: "one connection", build: { try ServiceConfiguration(limits: Limits(maximumConnections: 1)) }),
        EdgeCase(name: "connections at the ceiling", build: { try ServiceConfiguration(limits: Limits(maximumConnections: 100_000)) }),
        EdgeCase(name: "no grace period", build: { try ServiceConfiguration(limits: Limits(shutdownGrace: .zero)) }),
        EdgeCase(name: "grace at the ceiling", build: { try ServiceConfiguration(limits: Limits(shutdownGrace: .seconds(600))) }),
        EdgeCase(name: "tls with both paths", build: {
            try ServiceConfiguration(tls: TLSFiles(certificateChainPath: "/c.pem", privateKeyPath: "/k.pem"))
        }),
        EdgeCase(name: "a hostname", build: { try ServiceConfiguration(host: "localhost") }),
        EdgeCase(name: "an IPv6 literal", build: { try ServiceConfiguration(host: "::1") }),
    ]

    @Test("The edges of every range are accepted", arguments: edges)
    func edgesAccepted(_ edgeCase: EdgeCase) throws {
        let configuration = try edgeCase.build()
        #expect(!configuration.host.isEmpty)
    }

    // MARK: Errors do not leak

    @Test("An error names the field and never contains the value that caused it")
    func errorsDoNotLeak() {
        do {
            _ = try ServiceConfiguration(tls: TLSFiles(certificateChainPath: "/very/hidden/path/to/a-key.pem", privateKeyPath: ""))
            Issue.record("accepted")
        } catch {
            #expect(!"\(error)".contains("hidden"))
            #expect(!"\(error)".contains("a-key"))
        }
        do {
            _ = try ServiceConfiguration(host: "secret host name")
            Issue.record("accepted")
        } catch {
            #expect(!"\(error)".contains("secret"))
        }
    }

    @Test("The error's description names the field")
    func descriptionNamesField() {
        let error = ConfigurationError(field: "limits.idleTimeout", reason: .outOfRange)
        #expect(error.description.contains("limits.idleTimeout"))
    }
}
