import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// Holds handlers until the test lets them go, so "a request is in flight" is a state the test controls
/// and not a matter of timing.
actor HoldGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// The bounds on an HTTP/2 connection: how long it may idle, how long a body may take, how large and how
/// long a header may be, and how many streams may be open.
@Suite("HTTP/2 limits and timers", .serialized)
struct HTTP2LimitsTests {

    private func withServer<T>(
        limits: Limits, handler: @escaping Handler = ok(),
        _ body: (BoundAddress, TestTLS, MultiThreadedEventLoopGroup) async throws -> T
    ) async throws -> T {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(limits: limits, tls: material.files, handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do { result = try await body(running.address, material, group) } catch {
            try? await group.shutdownGracefully()
            await running.server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return result
    }

    private func connect(_ address: BoundAddress, _ material: TestTLS, _ group: MultiThreadedEventLoopGroup) async throws -> H2Client {
        try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), lenient: true)
    }

    private static let get: [(String, String)] = [(":method", "GET"), (":scheme", "https"), (":path", "/x"), (":authority", "localhost")]

    // MARK: Idle

    @Test("A connection with no open stream is closed once the idle timeout passes")
    func idleConnectionIsClosed() async throws {
        var limits = Limits()
        limits.idleTimeout = .milliseconds(200)
        try await withServer(limits: limits) { address, material, group in
            let client = try await connect(address, material, group)
            #expect(try await client.request("GET", "/x").status == 200)
            #expect(try await client.waitUntilClosed(timeout: .seconds(3)))
        }
    }

    @Test("A connection that is serving a request is not idle, however long the handler takes")
    func busyConnectionIsKept() async throws {
        var limits = Limits()
        limits.idleTimeout = .milliseconds(200)
        let gate = HoldGate()
        try await withServer(limits: limits, handler: { _ in
            await gate.wait()
            return Response(status: .ok, body: Data("late".utf8))
        }) { address, material, group in
            let client = try await connect(address, material, group)
            async let pending = client.request("GET", "/x", timeout: .seconds(5))
            try await Task.sleep(for: .milliseconds(700))      // well past the idle timeout, with the stream open
            #expect(client.channel.isActive)
            await gate.release()
            let response = try await pending
            #expect(response.text == "late")
        }
    }

    // MARK: Body

    @Test("A body that does not arrive within the body timeout is answered 408 and the stream is reset with NO_ERROR")
    func bodyTimeout() async throws {
        var limits = Limits()
        limits.bodyReadTimeout = .milliseconds(200)
        try await withServer(limits: limits) { address, material, group in
            let client = try await connect(address, material, group)
            let response = try await client.send(
                block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "5")], leaveOpen: true, awaitReset: true)
            #expect(response.status == 408)
            #expect(response.body == Refusal.requestTimeout.body)
            #expect(response.resetCode == 0)
            await client.close()
        }
    }

    @Test("A body that arrives in time is served, so the timer is cancelled and does not fire later")
    func bodyInTimeIsServed() async throws {
        var limits = Limits()
        limits.bodyReadTimeout = .milliseconds(300)
        try await withServer(limits: limits) { address, material, group in
            let client = try await connect(address, material, group)
            let response = try await client.send(
                block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "3")], body: Data("abc".utf8))
            #expect(response.status == 200)
            try await Task.sleep(for: .milliseconds(600))
            #expect(client.channel.isActive)
            await client.close()
        }
    }

    // MARK: Header size and count

    /// The size of a header list as RFC 9113 section 6.5.2 counts it: name and value octets plus 32 per field.
    private static func listSize(_ fields: [(String, String)]) -> Int {
        fields.reduce(0) { $0 + $1.0.utf8.count + $1.1.utf8.count + 32 }
    }

    @Test("A header list over the bound is refused, one at the bound is served (RFC 9113 section 6.5.2 counts 32 per field)")
    func headerListBound() async throws {
        var limits = Limits()
        limits.maximumHeaderBytes = 1024
        try await withServer(limits: limits) { address, material, group in
            // Pad one field so the whole list is exactly the bound, then one octet more.
            let base = Self.listSize(Self.get + [("x-pad", "")])
            let atBound = Self.get + [("x-pad", String(repeating: "a", count: 1024 - base))]
            let overBound = Self.get + [("x-pad", String(repeating: "a", count: 1024 - base + 1))]
            #expect(Self.listSize(atBound) == 1024)
            #expect(Self.listSize(overBound) == 1025)

            let fine = try await connect(address, material, group)
            #expect(try await fine.send(block: atBound).status == 200)
            await fine.close()

            let refused = try await connect(address, material, group)
            let response = try await refused.send(block: overBound)
            // RFC 9113 section 10.5.1: a server may answer 431 or reset the stream (or the connection).
            let answered431 = response.status == 431
            let resetCodes = [1, 7, 11]   // PROTOCOL_ERROR, REFUSED_STREAM, ENHANCE_YOUR_CALM (RFC 9113 section 7)
            let reset = response.resetCode.map { resetCodes.contains($0) } ?? false
            #expect(answered431 || reset || response.closed, "saw status \(String(describing: response.status)), reset \(String(describing: response.resetCode))")
            if answered431 { #expect(response.body == Refusal.headersTooLarge.body) }
            await refused.close()
        }
    }

    @Test("More header fields than the bound are refused with 431; exactly the bound are served")
    func headerCountBound() async throws {
        var limits = Limits()
        limits.maximumHeaderCount = 5
        try await withServer(limits: limits) { address, material, group in
            // Pseudo-header fields are not counted, as over HTTP/1.1, where there are none.
            let five = (0..<5).map { ("x-\($0)", "1") }
            let six = (0..<6).map { ("x-\($0)", "1") }

            let fine = try await connect(address, material, group)
            #expect(try await fine.send(block: Self.get + five).status == 200)
            await fine.close()

            let refused = try await connect(address, material, group)
            let response = try await refused.send(block: Self.get + six)
            #expect(response.status == 431)
            #expect(response.body == Refusal.headersTooLarge.body)
            await refused.close()
        }
    }

    // MARK: Concurrent streams

    @Test("With one stream allowed, a second request waits for the first; with 100 allowed it does not")
    func concurrentStreamsAreAdvertised() async throws {
        for (allowed, secondWaits) in [(1, true), (100, false)] {
            var limits = Limits()
            limits.maximumConcurrentStreams = allowed
            let gate = HoldGate()
            try await withServer(limits: limits, handler: { request in
                if request.path == "/slow" { await gate.wait() }
                return Response(status: .ok, body: Data(request.path.utf8))
            }) { address, material, group in
                let client = try await connect(address, material, group)
                let slow = Task { try await client.request("GET", "/slow") }
                try await Task.sleep(for: .milliseconds(300))               // let /slow reach the handler
                let fastDone = NIOLockedValueBox(false)
                let fast = Task {
                    let response = try await client.request("GET", "/fast")
                    fastDone.withLockedValue { $0 = true }
                    return response
                }
                try await Task.sleep(for: .milliseconds(500))
                // The client keeps to the SETTINGS the server sent, so a second request is held back at one.
                #expect(fastDone.withLockedValue { $0 } == !secondWaits, "allowed \(allowed)")
                await gate.release()
                #expect(try await slow.value.text == "/slow")
                #expect(try await fast.value.text == "/fast")
                await client.close()
            }
        }
    }
}
