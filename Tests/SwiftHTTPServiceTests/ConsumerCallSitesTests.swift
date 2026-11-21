import Testing
@testable import SwiftHTTPService

/// The argument lists the kit's consumers build a `ServiceConfiguration` with. The initialiser that takes a header policy
/// is an overload beside the original, so each of these must still resolve to the original, without ambiguity, and get
/// the default policy. If an overload change ever makes one ambiguous, this stops compiling, which is the point.
@Suite("Consumers' ServiceConfiguration call sites")
struct ConsumerCallSitesTests {

    @Test("The argument lists SwiftPushHub, SwiftDiagnosticsHub, ijs-dashboard-server and a bare call use still compile and get the secure policy")
    func consumerShapes() throws {
        let tls: TLSFiles? = nil
        let limits = Limits()
        // SwiftPushHub: HubHTTPServer.swift
        let pushHub = try ServiceConfiguration(host: "0.0.0.0", port: 9095, tls: tls, limits: limits, protocols: .http1, connectionReuse: .closeAfterResponse)
        // SwiftDiagnosticsHub: HubServerConfiguration.swift
        let diagnostics = try ServiceConfiguration(
            host: "0.0.0.0", port: 9110, tls: tls, limits: limits, protocols: .http1, connectionReuse: .closeAfterResponse,
            trustedProxies: [], forwarding: .none)
        // ijs-dashboard-server: ServerSettings.swift
        let ijs = try ServiceConfiguration(host: "0.0.0.0", port: 9140, tls: tls, limits: limits, protocols: .http1AndHTTP2)
        // A bare call, and the port-only form tests use.
        let bare = try ServiceConfiguration()
        let portOnly = try ServiceConfiguration(port: 0)

        for configuration in [pushHub, diagnostics, ijs, bare, portOnly] {
            #expect(configuration.responseHeaders == .secure)
        }
    }
}
