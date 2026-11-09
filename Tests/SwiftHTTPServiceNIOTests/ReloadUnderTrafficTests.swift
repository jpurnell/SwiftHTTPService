import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// A certificate reload while streams are open: nothing in flight is dropped, new connections see the new certificate,
/// and an unfit replacement changes nothing and says so.
///
/// "Sees the new certificate" is proved on the wire, not read from the server's report: the clients here PIN the leaf's
/// SHA-256 (`ClientTrust.pinned`), so a handshake completes only if the server presented exactly that certificate. The
/// expected digests come from the test support's own computation over the generated certificate, not from the server.
@Suite("TLS reload under traffic", .serialized)
struct ReloadUnderTrafficTests {

    static let ticks = 30
    /// What every `/stream` response carries: `tick-0\n` to `tick-29\n`, one write each, 30 ms apart.
    static let expectedBody = (0..<ticks).map { "tick-\($0)\n" }.joined()

    /// The server, its two identities, and the files that hold the current one.
    struct Rig {
        let material: TestTLS
        let leafA: TestLeaf
        let authorityA: TestAuthority
        let authorityB: TestAuthority
        let leafB: TestLeaf
        let running: Running
        let group: MultiThreadedEventLoopGroup
    }

    private func pinned(_ leaf: TestLeaf, _ authority: TestAuthority, alpn: [String]) throws -> ClientTLSContext {
        try ClientTLSContext(
            trust: .pinned([try .certificate(sha256: leaf.certificateSHA256)], additionalRoots: [authority.asRoot]),
            applicationProtocols: alpn)
    }

    private func withRig<T>(_ body: (Rig) async throws -> T) async throws -> T {
        let material = try TestTLS(seed: 1, commonName: "Authority A")
        defer { material.cleanUp() }
        let authorityA = material.authority
        let leafA = try authorityA.issueLeaf(dnsNames: ["localhost"], ipv4Addresses: [[127, 0, 0, 1]])
        try material.write(leafA)
        let authorityB = try TestAuthority(commonName: "Authority B", generator: SeededGenerator(seed: 2))
        let leafB = try authorityB.issueLeaf(dnsNames: ["localhost"], ipv4Addresses: [[127, 0, 0, 1]])
        let running = try await startServer(tls: material.files, handler: { request in
            if request.path == "/stream" {
                return .streaming(status: .ok) { writer in
                    for tick in 0..<Self.ticks {
                        try await writer.write(Data("tick-\(tick)\n".utf8))
                        try await Task.sleep(for: .milliseconds(30))
                    }
                }
            }
            return Response(status: .ok, body: Data("ok".utf8))
        })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let rig = Rig(material: material, leafA: leafA, authorityA: authorityA, authorityB: authorityB, leafB: leafB, running: running, group: group)
        let result: T
        do { result = try await body(rig) } catch {
            try? await group.shutdownGracefully()
            await running.server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return result
    }

    /// Opens `http1` HTTP/1.1 streams (each its own connection) and `http2` HTTP/2 streams (one connection),
    /// and returns once every one of them has delivered its first tick.
    private struct Open {
        var h1: [RawClient] = []
        var h2Connection: H2Client?
        var h2: [H2Client.Watched] = []
    }

    private func openStreams(_ rig: Rig, http1: Int, http2: Int, serving: Bool = false) async throws -> Open {
        // Pinned to the certificate the server presents now: A at the start, B once `serving` says a reload has installed it.
        let leaf = serving ? rig.leafB : rig.leafA
        let authority = serving ? rig.authorityB : rig.authorityA
        var open = Open()
        for _ in 0..<http1 {
            let client = try await RawClient.connect(
                to: rig.running.address, group: rig.group, tls: try pinned(leaf, authority, alpn: ["http/1.1"]))
            try await client.send("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
            open.h1.append(client)
        }
        if http2 > 0 {
            let connection = try await H2Client.connect(
                to: rig.running.address, group: rig.group, tls: try pinned(leaf, authority, alpn: ["h2"]))
            for _ in 0..<http2 { open.h2.append(try await connection.open("GET", "/stream")) }
            open.h2Connection = connection
        }
        for client in open.h1 { #expect(try await client.wait { !($0.splitResponse?.body.isEmpty ?? true) }, "an HTTP/1.1 stream never started") }
        for stream in open.h2 { #expect(try await stream.wait { !$0.body.isEmpty }, "an HTTP/2 stream never started") }
        return open
    }

    /// Every opened stream finishes with the whole body and no reset.
    private func expectAllComplete(_ open: Open, _ note: String) async throws {
        for (index, client) in open.h1.enumerated() {
            let done = try await client.wait(timeout: .seconds(10)) { ChunkedBody($0.splitResponse?.body ?? Data()).complete }
            #expect(done, "\(note): HTTP/1.1 stream \(index) was cut off (\(client.splitResponse?.body.count ?? 0) bytes, closed: \(client.isClosed))")
            let body = ChunkedBody(client.splitResponse?.body ?? Data())
            #expect(String(decoding: body.chunks.reduce(Data(), +), as: UTF8.self) == Self.expectedBody, "\(note): HTTP/1.1 stream \(index) body")
        }
        for (index, stream) in open.h2.enumerated() {
            let done = try await stream.wait(timeout: .seconds(10)) { $0.ended || $0.resetCode != nil || $0.closed }
            let response = stream.response
            #expect(done && response.ended, "\(note): HTTP/2 stream \(index) did not end (reset: \(String(describing: response.resetCode)), closed: \(response.closed))")
            #expect(response.resetCode == nil && !response.closed, "\(note): HTTP/2 stream \(index) was dropped")
            #expect(response.text == Self.expectedBody, "\(note): HTTP/2 stream \(index) body")
        }
    }

    private func closeAll(_ open: Open) async {
        for client in open.h1 { await client.close() }
        await open.h2Connection?.close()
    }

    /// Whether a new HTTP/1.1 connection pinned to `leaf` completes the handshake and is served.
    private func connects(_ rig: Rig, pinnedTo leaf: TestLeaf, _ authority: TestAuthority) async throws -> Bool {
        let client = try await RawClient.connect(to: rig.running.address, group: rig.group, tls: try pinned(leaf, authority, alpn: ["http/1.1"]))
        try? await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
        _ = try await client.wait(timeout: .seconds(3)) { $0.isClosed || $0.received.count > 0 }
        let served = try await client.response(timeout: .milliseconds(50))?.status == 200
        let completed = client.handshakeCompleted
        await client.close()
        return served && completed
    }

    private func connectsH2(_ rig: Rig, pinnedTo leaf: TestLeaf, _ authority: TestAuthority) async throws -> Bool {
        guard let client = try? await H2Client.connect(
            to: rig.running.address, group: rig.group, tls: try pinned(leaf, authority, alpn: ["h2"])) else { return false }
        // A handshake that fails closes the channel under the request; that is "does not connect", not an error of the test.
        let response = try? await client.request("GET", "/x", timeout: .seconds(3))
        await client.close()
        return response?.status == 200
    }

    // MARK: A valid renewal

    @Test("A renewal and a reload under eight HTTP/1.1 and eight HTTP/2 open streams: none is dropped, new connections (both versions) present the new certificate, and the old one is no longer presented")
    func renewalUnderTraffic() async throws {
        try await withRig { rig in
            // Before: the server presents A, and B is not what it presents.
            #expect(try await connects(rig, pinnedTo: rig.leafA, rig.authorityA), "control: the server should present certificate A")
            #expect(try await !connects(rig, pinnedTo: rig.leafB, rig.authorityB), "control: a client pinned to B must not complete a handshake before the reload")

            let open = try await openStreams(rig, http1: 8, http2: 8)

            // The renewal: new files on disk, then the reload, with sixteen streams open.
            try rig.material.write(rig.leafB)
            let outcome = try #require(rig.running.server.reloadTLS())
            guard case .reloaded(let serving, let replacing) = outcome else {
                Issue.record("not reloaded: \(outcome)")
                await closeAll(open)
                return
            }
            #expect(serving.certificateSHA256 == rig.leafB.certificateSHA256)
            #expect(replacing.certificateSHA256 == rig.leafA.certificateSHA256)

            // New connections present B, over HTTP/1.1 and over HTTP/2, and no longer A.
            #expect(try await connects(rig, pinnedTo: rig.leafB, rig.authorityB), "a new HTTP/1.1 connection should present B")
            #expect(try await connectsH2(rig, pinnedTo: rig.leafB, rig.authorityB), "a new HTTP/2 connection should present B")
            #expect(try await !connects(rig, pinnedTo: rig.leafA, rig.authorityA), "a new connection must not present A after the reload")
            #expect(try await !connectsH2(rig, pinnedTo: rig.leafA, rig.authorityA), "a new HTTP/2 connection must not present A after the reload")

            // And nothing in flight was dropped.
            try await expectAllComplete(open, "after a reload")
            await closeAll(open)
        }
    }

    // MARK: An unfit replacement

    struct Unfit: Sendable, CustomTestStringConvertible {
        let name: String
        var testDescription: String { name }
    }

    static let unfit: [Unfit] = [
        Unfit(name: "a key that does not belong to the certificate"),
        Unfit(name: "a certificate file that holds no certificate"),
        Unfit(name: "a private key that others can read"),
        Unfit(name: "an expired certificate"),
    ]

    private func installUnfit(_ unfit: Unfit, _ rig: Rig) throws {
        switch unfit.name {
        case "a key that does not belong to the certificate":
            let other = try rig.authorityB.issueLeaf(dnsNames: ["localhost"], ipv4Addresses: [[127, 0, 0, 1]])
            try Data(other.chainPEM.utf8).write(to: URL(fileURLWithPath: rig.material.chainPath))        // another leaf's certificate, this leaf's key
        case "a certificate file that holds no certificate":
            try Data("this is not a certificate\n".utf8).write(to: URL(fileURLWithPath: rig.material.chainPath))
        case "a private key that others can read":
            try rig.material.write(rig.leafB, keyMode: 0o644)
        default:
            try rig.material.write(try rig.authorityB.issueLeaf(dnsNames: ["localhost"], notValidAfter: TestInstant.shortLivedEnd))
        }
    }

    private func kind(_ error: ServerIdentityError) -> String {
        switch error {
        case .privateKeyDoesNotMatchCertificate: "key mismatch"
        case .emptyCertificateChain, .invalidCertificateChain: "no certificate"
        case .privateKeyPermissionsTooOpen: "key permissions"
        case .expired: "expired"
        default: "other: \(error)"
        }
    }

    @Test("An unfit replacement under traffic is reported as a failed reload that is still serving the old certificate; no stream is dropped and new connections still see the old certificate", arguments: unfit)
    func unfitReplacement(_ unfit: Unfit) async throws {
        let expected: [String: String] = [
            "a key that does not belong to the certificate": "key mismatch",
            "a certificate file that holds no certificate": "no certificate",
            "a private key that others can read": "key permissions",
            "an expired certificate": "expired",
        ]
        try await withRig { rig in
            // Start from B, so the "old" certificate that must keep being served is not the one the server began with.
            try rig.material.write(rig.leafB)
            guard case .reloaded = try #require(rig.running.server.reloadTLS()) else {
                Issue.record("could not install B")
                return
            }
            let open = try await openStreams(rig, http1: 4, http2: 4, serving: true)
            try installUnfit(unfit, rig)
            let outcome = try #require(rig.running.server.reloadTLS())
            guard case .failed(let error, let stillServing) = outcome else {
                Issue.record("\(unfit.name): expected a failed reload, got \(outcome)")
                await closeAll(open)
                return
            }
            #expect(kind(error) == expected[unfit.name], "\(unfit.name): \(error)")
            #expect(stillServing.certificateSHA256 == rig.leafB.certificateSHA256, "the failed reload must say it is still serving B")
            #expect(outcome.suggestedLogLevel == .warning)
            #expect(try await connects(rig, pinnedTo: rig.leafB, rig.authorityB), "new connections must still present B")
            #expect(try await connectsH2(rig, pinnedTo: rig.leafB, rig.authorityB), "new HTTP/2 connections must still present B")
            try await expectAllComplete(open, unfit.name)
            await closeAll(open)
        }
    }

    // MARK: The trigger path

    private final class Outcomes: Sendable {
        private let all = NIOLockedValueBox<[ReloadOutcome]>([])
        func add(_ outcome: ReloadOutcome) { all.withLockedValue { $0.append(outcome) } }
        var value: [ReloadOutcome] { all.withLockedValue { $0 } }
        func wait(for count: Int) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if value.count >= count { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return value.count >= count
        }
    }

    @Test("Driven by a trigger stream, the loop reports a failed reload for a bad file and a reloaded one for the good file, under open streams, and the streams finish")
    func triggerLoopUnderTraffic() async throws {
        try await withRig { rig in
            let (triggers, source) = AsyncStream<Void>.makeStream()
            let outcomes = Outcomes()
            let loop = Task { await rig.running.server.reloadTLS(onEach: triggers, mode: .always, report: { outcomes.add($0) }) }
            let open = try await openStreams(rig, http1: 4, http2: 4)

            try Data("garbage\n".utf8).write(to: URL(fileURLWithPath: rig.material.chainPath))
            source.yield()
            #expect(try await outcomes.wait(for: 1))
            try rig.material.write(rig.leafB)
            source.yield()
            #expect(try await outcomes.wait(for: 2))
            source.finish()
            await loop.value

            let reported = outcomes.value
            guard reported.count == 2, case .failed(_, let stillServing) = reported[0], case .reloaded(let serving, _) = reported[1] else {
                Issue.record("expected [failed, reloaded], got \(reported)")
                await closeAll(open)
                return
            }
            #expect(stillServing.certificateSHA256 == rig.leafA.certificateSHA256)
            #expect(serving.certificateSHA256 == rig.leafB.certificateSHA256)
            #expect(try await connects(rig, pinnedTo: rig.leafB, rig.authorityB))
            try await expectAllComplete(open, "trigger loop")
            await closeAll(open)
        }
    }
}
