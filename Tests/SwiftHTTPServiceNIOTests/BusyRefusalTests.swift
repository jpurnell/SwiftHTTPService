import Foundation
import HTTPTypes
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// A connection past `Limits.maximumConnections` is told the server is busy (503 with `Retry-After`) and closed,
/// and the telling is itself bounded so it cannot be used to exhaust the server.
@Suite("Busy refusal", .serialized)
struct BusyRefusalTests {

    private static let get = "GET /x HTTP/1.1\r\nHost: h\r\n\r\n"

    // MARK: The registry's decision

    @Test("The registry admits up to the cap, then offers refusal slots, then drops")
    func admission() {
        let registry = ConnectionRegistry(maximum: 2, refusalSlots: 3)
        let channels = (0..<8).map { _ in EmbeddedChannel() }
        var outcomes: [ConnectionRegistry.Admission] = []
        for channel in channels.prefix(6) { outcomes.append(registry.admit(channel)) }
        #expect(outcomes == [.admitted, .admitted, .refuse, .refuse, .refuse, .drop])
        #expect(registry.count == 2)
        #expect(registry.refusing == 3)
        // A finished refusal frees a refusal slot and nothing else.
        registry.endRefusal()
        #expect(registry.refusing == 2)
        #expect(registry.admit(channels[6]) == .refuse)
        #expect(registry.admit(channels[7]) == .drop)
        // A closed connection frees room for an admission, not a refusal slot.
        registry.remove(channels[0])
        #expect(registry.admit(EmbeddedChannel()) == .admitted)
        #expect(registry.count == 2)
    }

    @Test("A refusal slot count that is not positive never refuses, only drops")
    func noSlots() {
        let registry = ConnectionRegistry(maximum: 1, refusalSlots: 0)
        #expect(registry.admit(EmbeddedChannel()) == .admitted)
        #expect(registry.admit(EmbeddedChannel()) == .drop)
    }

    // MARK: Over the wire, plaintext

    @Test("A connection over the cap is answered 503 problem+json with Retry-After and closed; the held ones are untouched; the cap frees")
    func answered() async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 2))
        try await withClientGroup { group in
            let first = try await RawClient.connect(to: running.address, group: group)
            let second = try await RawClient.connect(to: running.address, group: group)
            try await first.send(Self.get)
            #expect(try await first.response()?.status == 200)
            try await second.send(Self.get)
            #expect(try await second.response()?.status == 200)

            let third = try await RawClient.connect(to: running.address, group: group)
            let refusal = try #require(try await third.response())
            #expect(refusal.status == 503)
            #expect(refusal.header("Content-Type") == "application/problem+json")
            #expect(refusal.header("Retry-After") == "1")
            #expect(refusal.header("Connection") == "close")
            #expect(refusal.header("Content-Length") == String(Refusal.serviceUnavailable.body.count))
            #expect(refusal.header("Date")?.hasSuffix(" GMT") == true)       // an HTTP-date, as every other response has
            #expect(refusal.body == Refusal.serviceUnavailable.body)
            #expect(try await third.waitUntilClosed(), "a refused connection was kept")
            #expect(!first.isClosed && !second.isClosed)

            await first.close()
            try await Task.sleep(for: .milliseconds(200))
            let fourth = try await RawClient.connect(to: running.address, group: group)
            try await fourth.send(Self.get)
            #expect(try await fourth.response()?.status == 200)
            await second.close()
            await fourth.close()
            await third.close()
        }
        await running.server.shutdown()
    }

    @Test("The body is the kit's fixed problem: code service_unavailable, status 503")
    func body() {
        #expect(Refusal.serviceUnavailable.statusCode == 503)
        #expect(Refusal.serviceUnavailable.code == "service_unavailable")
        #expect(String(decoding: Refusal.serviceUnavailable.body, as: UTF8.self)
            == #"{"code":"service_unavailable","status":503,"title":"Service Unavailable","type":"about:blank"}"#)
    }

    struct RetryCase: Sendable, CustomTestStringConvertible {
        let duration: Duration
        let header: String
        var testDescription: String { "\(duration)" }
    }

    // ceil(x) in seconds, worked out by hand.
    static let retryCases: [RetryCase] = [
        RetryCase(duration: .milliseconds(100), header: "1"),
        RetryCase(duration: .milliseconds(1500), header: "2"),
        RetryCase(duration: .seconds(3), header: "3"),
    ]

    @Test("Retry-After is the configured duration rounded up to whole seconds", arguments: retryCases)
    func retryAfter(_ c: RetryCase) async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 1, busyRetryAfter: c.duration))
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: running.address, group: group)
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)
            let refused = try await RawClient.connect(to: running.address, group: group)
            #expect(try await refused.response()?.header("Retry-After") == c.header)
            await refused.close()
            await held.close()
        }
        await running.server.shutdown()
    }

    // MARK: The hooks

    @Test("The hooks see a busy refusal: observed once, recorded without a request line, body shaped, status and Retry-After kept")
    func hooks() async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let records = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, limits: Limits(maximumConnections: 1, busyRetryAfter: .seconds(7))), handler: ok(),
            refusals: RefusalHooks(
                respond: { refusal in
                    var headers = HTTPFields()
                    headers[.contentType] = "application/json"
                    headers[.retryAfter] = "999"                                   // the transport's number stays
                    return Response(status: .ok, headers: headers, body: Data(#"{"busy":"\#(refusal.code)"}"#.utf8))
                },
                observe: { kind in seen.withLockedValue { $0.append(kind) } },
                record: { record in records.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: address, group: group)
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)
            let refused = try await RawClient.connect(to: address, group: group)
            let response = try #require(try await refused.response())
            #expect(response.status == 503)                                          // not the 200 the hook asked for
            #expect(response.text == #"{"busy":"service_unavailable"}"#)
            #expect(response.header("Content-Type") == "application/json")
            #expect(response.values("Retry-After") == ["7"])
            #expect(response.header("Connection") == "close")
            await refused.close()
            await held.close()
        }
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.busy])
        let recorded = records.withLockedValue { $0 }
        #expect(recorded.count == 1)
        let record = try #require(recorded.first)
        #expect(record.kind == .busy)
        #expect(record.peerAddress == "127.0.0.1")
        #expect(record.remoteAddress == "127.0.0.1")
        #expect(record.method == nil)
        #expect(record.target == nil)
        #expect(record.httpVersion == nil)
    }

    @Test("The busy kind has the status and code of the fixed refusal")
    func kind() {
        #expect(TransportRefusal.busy.statusCode == 503)
        #expect(TransportRefusal.busy.code == "service_unavailable")
    }

    // MARK: The refusal is bounded

    @Test("Refusals are capped: past the slots a connection is dropped with nothing written, and every slot is freed by the deadline")
    func bounded() async throws {
        let slots = ConnectionRegistry.defaultRefusalSlots
        let running = try await startServer(limits: Limits(maximumConnections: 1))
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: running.address, group: group)
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)
            // None of these reads or closes: they hold a refusal slot until the server lets go.
            var clients: [RawClient] = []
            for _ in 0..<(slots + 8) { clients.append(try await RawClient.connect(to: running.address, group: group, keepOpenAfterFIN: true)) }
            try await Task.sleep(for: .milliseconds(500))
            let answered = clients.filter { !$0.received.isEmpty }
            let dropped = clients.filter { $0.received.isEmpty }
            #expect(answered.count == slots)
            #expect(dropped.count == 8)
            for client in dropped { #expect(try await client.waitUntilClosed(timeout: .seconds(2))) }

            // The server has ended every answered connection (its FIN), but the peers have not left, so the slots are
            // held until the deadline: a refusal in the meantime is dropped, not answered.
            for client in answered { #expect(try await client.waitUntilClosed(timeout: .seconds(1))) }
            let early = try await RawClient.connect(to: running.address, group: group)
            #expect(try await early.waitUntilClosed(timeout: .seconds(1)))
            #expect(early.received.isEmpty, "a refusal was written past the slots")
            // By the deadline the server has closed them all, and the slots are free again.
            try await Task.sleep(for: .nanoseconds(BusyRefusalHandler.deadline.nanoseconds) + .milliseconds(300))
            let again = try await RawClient.connect(to: running.address, group: group)
            #expect(try await again.response()?.status == 503)
            await again.close()
            await held.close()
        }
        await running.server.shutdown()
    }

    @Test("A refused client that reads and leaves frees its slot at once, so more refusals than slots can be served one after another")
    func slotsAreReleased() async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 1))
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: running.address, group: group)
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)
            for round in 0..<(ConnectionRegistry.defaultRefusalSlots * 2) {
                let refused = try await RawClient.connect(to: running.address, group: group)
                let status = try await refused.response()?.status
                #expect(status == 503, "refusal \(round)")
                await refused.close()
                try await Task.sleep(for: .milliseconds(5))
            }
            await held.close()
        }
        await running.server.shutdown()
    }

    @Test("A refused client that sends a request is not read: the refusal is the same and the connection still closes")
    func requestIsIgnored() async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 1))
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: running.address, group: group)
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)
            // The refusal is written, and the output side closed, as soon as the connection opens: a client that closed
            // on that FIN could lose the race with its own request. This one stays open until the server's deadline closes it.
            let refused = try await RawClient.connect(to: running.address, group: group, keepOpenAfterFIN: true)
            try await refused.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")
            #expect(try await refused.response()?.status == 503)
            #expect(try await refused.waitUntilClosed())
            await held.close()
        }
        await running.server.shutdown()
    }

    @Test("Shutdown does not wait on a refusal that is still open")
    func shutdownWithRefusalOpen() async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 1, shutdownGrace: .seconds(1)))
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: running.address, group: group)
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)
            let refused = try await RawClient.connect(to: running.address, group: group)
            #expect(try await refused.response()?.status == 503)
            let started = ContinuousClock.now
            await running.server.shutdown()
            #expect(ContinuousClock.now - started < .seconds(1.8), "shutdown waited for a refusal's deadline")
            #expect(try await refused.waitUntilClosed())
        }
    }

    // MARK: Over TLS

    @Test("Over TLS a connection past the cap completes the handshake and is answered 503 with Retry-After, in HTTP/1.1 and in h2, and the hook is told once each")
    func tlsIsAnswered() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: Limits(maximumConnections: 1)), handler: ok(),
            refusals: RefusalHooks(observe: { kind in seen.withLockedValue { $0.append(kind) } }))
        let address = try await server.start()
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: address, group: group, tls: try material.clientContext())
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)

            let refused = try await RawClient.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["http/1.1"]))
            let answer = try #require(try await refused.response())
            #expect(answer.status == 503)
            #expect(answer.header("Retry-After") == "1")
            #expect(answer.header("Content-Type") == "application/problem+json")
            #expect(answer.body == Refusal.serviceUnavailable.body)
            #expect(try await refused.waitUntilClosed(), "a refused connection was kept")
            #expect(refused.negotiatedProtocol == "http/1.1")

            let h2 = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2", "http/1.1"]))
            let response = try await h2.request("GET", "/x")
            #expect(h2.negotiatedProtocol == "h2")
            #expect(response.status == 503)
            #expect(response.header("retry-after") == "1")
            #expect(response.ended, "the h2 answer was cut off")
            #expect(!held.isClosed)
            await h2.close()
            await held.close()
        }
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.busy, .busy])
    }

    @Test("Over TLS a refused connection that never completes the handshake is closed within the refusal deadline")
    func tlsRefusalIsBounded() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: Limits(maximumConnections: 1)), handler: ok())
        let address = try await server.start()
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: address, group: group, tls: try material.clientContext())
            try await held.send(Self.get)
            #expect(try await held.response()?.status == 200)

            // A plain TCP connection that says nothing: it is past the cap, and a TLS handshake never starts.
            let silent = try await RawClient.connect(to: address, group: group)
            let began = ContinuousClock.now
            #expect(try await silent.waitUntilClosed(timeout: .seconds(6)))
            // TIMING: the refusal's whole life is bounded by BusyRefusalHandler.deadline (2 s) plus scheduling slack.
            #expect(ContinuousClock.now - began < .seconds(4), "a stalled TLS refusal outlived its deadline")
            await held.close()
        }
        await server.shutdown()
    }

    @Test("The TLS refusal slots are positive and fewer than the plaintext ones")
    func tlsRefusalSlots() {
        #expect(ConnectionRegistry.defaultTLSRefusalSlots > 0)
        #expect(ConnectionRegistry.defaultTLSRefusalSlots < ConnectionRegistry.defaultRefusalSlots, "a TLS refusal costs about 7.5 times a plaintext one")
    }
}
