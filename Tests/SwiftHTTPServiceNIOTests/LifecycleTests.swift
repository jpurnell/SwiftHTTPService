import Foundation
import NIOCore
import NIOPosix
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// The server on real loopback sockets: starting, serving, shutting down, the connection cap, and TLS.
/// Every test shuts down the server it starts, and every wait is bounded.
@Suite("Server lifecycle", .serialized)
struct LifecycleTests {

    @discardableResult
    private func withGroup<T>(_ body: (MultiThreadedEventLoopGroup) async throws -> T) async throws -> T {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        return try await body(group)
    }

    // MARK: Starting

    @Test("The server binds the loopback address by default, on the port the system chose, and serves a real client")
    func servesARealClient() async throws {
        let running = try await startServer(handler: ok("from the server"))
        #expect(running.address.host == "127.0.0.1")
        #expect(running.address.port > 0)
        let url = try #require(URL(string: "http://127.0.0.1:\(running.address.port)/v1/x"))
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "from the server")
        await running.server.shutdown()
    }

    @Test("A server can be started once")
    func startTwice() async throws {
        let running = try await startServer()
        await #expect(throws: HTTPServerError.alreadyStarted) { try await running.server.start() }
        await running.server.shutdown()
    }

    @Test("A port that is already in use is a bind failure, and says nothing else")
    func portInUse() async throws {
        let first = try await startServer()
        let second = HTTPServer(configuration: try ServiceConfiguration(port: UInt16(first.address.port)), handler: ok())
        await #expect(throws: HTTPServerError.bindFailed) { try await second.start() }
        await first.server.shutdown()
    }

    // MARK: Shutting down

    @Test("Shutdown is safe before start, twice, and from several tasks at once")
    func shutdownIsIdempotent() async throws {
        let never = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: ok())
        await never.shutdown()

        let running = try await startServer()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { await running.server.shutdown() } }
        }
        await running.server.shutdown()
        #expect(never.reloadTLS() == nil)
        #expect(running.server.reloadTLS() == nil)
        await #expect(throws: HTTPServerError.alreadyStarted) { try await running.server.start() }
    }

    @Test("After shutdown the port is closed: a new connection is refused")
    func refusesAfterShutdown() async throws {
        let running = try await startServer()
        await running.server.shutdown()
        try await withGroup { group in
            await #expect(throws: (any Error).self) { try await RawClient.connect(to: running.address, group: group) }
        }
    }

    @Test("A request in flight finishes during shutdown, is answered with Connection: close, and shutdown waits for it")
    func drainsInFlight() async throws {
        let gate = Gate()
        let running = try await startServer(limits: Limits(shutdownGrace: .seconds(30))) { _ in
            await gate.wait()
            return Response(status: .ok, body: Data("late".utf8))
        }
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            try await Task.sleep(for: .milliseconds(100))   // let the request reach the handler

            let finished = FlagBox()
            let shutdown = Task {
                await running.server.shutdown()
                finished.set()
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!finished.value, "shutdown returned while a request was in flight")
            await #expect(throws: (any Error).self) { try await RawClient.connect(to: running.address, group: group) }

            await gate.open()
            let response = try #require(try await client.response())
            #expect(response.text == "late")
            #expect(response.header("Connection") == "close")
            #expect(try await client.waitUntilClosed())
            await shutdown.value
            #expect(finished.value)
        }
    }

    @Test("A connection with nothing in progress is closed at once by shutdown, not at the end of the grace period")
    func closesIdleConnectionsAtOnce() async throws {
        let running = try await startServer(limits: Limits(shutdownGrace: .seconds(30)))
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            // A 30 s grace period: if shutdown waited for it, this test would not finish.
            await running.server.shutdown()
            #expect(try await client.waitUntilClosed())
        }
    }

    @Test("During the grace period a request that never finishes is left alone; when it ends, it is cut off")
    func graceExpires() async throws {
        let gate = Gate()   // never opened
        let running = try await startServer(limits: Limits(shutdownGrace: .seconds(2))) { _ in
            await gate.wait()
            return Response(status: .ok)
        }
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            try await Task.sleep(for: .milliseconds(100))
            let finished = FlagBox()
            let shutdown = Task {
                await running.server.shutdown()
                finished.set()
            }
            try await Task.sleep(for: .milliseconds(300))
            // Well inside the two-second grace period: the request is still being waited for.
            #expect(!finished.value, "shutdown gave up before the grace period ended")
            #expect(!client.isClosed)
            // Then the grace period ends and the connection is cut, so shutdown returns without the gate opening.
            await shutdown.value
            #expect(finished.value)
            #expect(try await client.waitUntilClosed())
        }
        await gate.open()
    }

    // MARK: The cap

    @Test("Connections over the cap are closed at once with nothing written, and the cap frees when one closes")
    func connectionCap() async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 2))
        try await withGroup { group in
            let first = try await RawClient.connect(to: running.address, group: group)
            let second = try await RawClient.connect(to: running.address, group: group)
            try await first.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await first.response()?.status == 200)
            try await second.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await second.response()?.status == 200)

            let third = try await RawClient.connect(to: running.address, group: group)
            #expect(try await third.waitUntilClosed(), "a connection over the cap was kept")
            #expect(third.received.isEmpty, "a connection over the cap was written to")
            #expect(!first.isClosed && !second.isClosed)

            await first.close()
            try await Task.sleep(for: .milliseconds(200))
            let fourth = try await RawClient.connect(to: running.address, group: group)
            try await fourth.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await fourth.response()?.status == 200)
            await second.close()
            await fourth.close()
        }
        await running.server.shutdown()
    }

    // MARK: Time, for real

    @Test("An idle connection is closed by the server at the idle timeout, with nothing written")
    func realIdleTimeout() async throws {
        let running = try await startServer(limits: Limits(idleTimeout: .milliseconds(300)))
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
            #expect(client.received.isEmpty)
        }
        await running.server.shutdown()
    }

    @Test("A header that is never finished is answered with 408 on a real socket")
    func realHeaderTimeout() async throws {
        let running = try await startServer(limits: Limits(headerReadTimeout: .milliseconds(300), idleTimeout: .seconds(30)))
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n")
            #expect(try await client.response()?.status == 408)
            #expect(try await client.waitUntilClosed())
        }
        await running.server.shutdown()
    }

    // MARK: TLS

    @Test("With TLS configured, a client that trusts the authority gets its response, and HTTP/1.1 is what was negotiated")
    func tlsServes() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: ok("secure"))
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
            try await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let response = try #require(try await client.response())
            #expect(response.text == "secure")
            #expect(client.negotiatedProtocol == "http/1.1")
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("A client that trusts a different authority is refused at the handshake")
    func tlsUntrustedClient() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let stranger = try TestAuthority(commonName: "Stranger", generator: SeededGenerator(seed: 99))
        let running = try await startServer(tls: material.files)
        try await withGroup { group in
            let client = try await RawClient.connect(
                to: running.address, group: group, tls: try stranger.clientContext(applicationProtocols: ["http/1.1"]))
            try? await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await client.waitUntilClosed())
            #expect(!client.handshakeCompleted)
            #expect(client.received.isEmpty)
        }
        await running.server.shutdown()
    }

    @Test("Plain HTTP sent to a TLS port is dropped without a response")
    func plainToTLS() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files)
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await client.waitUntilClosed())
            #expect(!String(decoding: client.received, as: UTF8.self).contains("HTTP/1.1"))
        }
        await running.server.shutdown()
    }

    // MARK: A bad identity stops start() with SwiftTLSKit's typed error

    private func startError(_ files: TLSFiles) async throws -> HTTPServerError? {
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: files), handler: ok())
        do {
            _ = try await server.start()
            await server.shutdown()
            return nil
        } catch let error as HTTPServerError {
            return error
        }
    }

    @Test("A missing certificate file is the unreadable error, naming the path")
    func missingCertificate() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let missing = material.directory.appendingPathComponent("absent.pem").path
        let error = try await startError(TLSFiles(certificateChainPath: missing, privateKeyPath: material.keyPath))
        guard case .tlsIdentity(.unreadable(let path, _)) = try #require(error) else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(path == missing)
    }

    @Test("A private key that others can read is refused, with its mode")
    func openKey() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        try material.write(try material.authority.issueLeaf(dnsNames: ["localhost"]), keyMode: 0o644)
        let error = try await startError(material.files)
        guard case .tlsIdentity(.privateKeyPermissionsTooOpen(let path, let mode)) = try #require(error) else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(path == material.keyPath)
        #expect(mode & 0o777 == 0o644)
    }

    @Test("A key that does not belong to the certificate is refused")
    func mismatchedKey() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let other = try material.authority.issueLeaf(dnsNames: ["localhost"])
        try FileManager.default.removeItem(atPath: material.keyPath)
        FileManager.default.createFile(
            atPath: material.keyPath, contents: Data(other.privateKeyPEM.utf8), attributes: [.posixPermissions: 0o600])
        let error = try await startError(material.files)
        guard case .tlsIdentity(.privateKeyDoesNotMatchCertificate) = try #require(error) else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
    }

    @Test("A certificate file that holds no certificate is refused")
    func notACertificate() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        try Data("this is not a certificate\n".utf8).write(to: URL(fileURLWithPath: material.chainPath))
        let error = try await startError(material.files)
        switch try #require(error) {
        case .tlsIdentity(.emptyCertificateChain), .tlsIdentity(.invalidCertificateChain): break
        default: Issue.record("wrong error: \(String(describing: error))")
        }
    }

    @Test("An expired certificate is refused")
    func expired() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        try material.write(try material.authority.issueLeaf(dnsNames: ["localhost"], notValidAfter: TestInstant.shortLivedEnd))
        let error = try await startError(material.files)
        guard case .tlsIdentity(.expired(let path, _)) = try #require(error) else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(path == material.chainPath)
    }

    @Test("A start that failed for a bad identity can be tried again once the files are fixed")
    func retryAfterFixing() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: material.chainPath))
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files), handler: ok())
        await #expect(throws: HTTPServerError.self) { try await server.start() }
        try material.write(try material.authority.issueLeaf(dnsNames: ["localhost"]))
        let address = try await server.start()
        #expect(address.port > 0)
        await server.shutdown()
    }

    // MARK: Plaintext on an exposed address

    @Test("Plaintext on a host that is not loopback is refused, and the error names the host")
    func exposedPlaintext() async throws {
        let server = HTTPServer(configuration: try ServiceConfiguration(host: "0.0.0.0", port: 0), handler: ok())
        await #expect(throws: HTTPServerError.exposedPlaintext(host: "0.0.0.0")) { try await server.start() }
    }

    @Test("A non-loopback name is exposed too, because names are not resolved")
    func exposedName() async throws {
        let server = HTTPServer(configuration: try ServiceConfiguration(host: "example.org", port: 0), handler: ok())
        await #expect(throws: HTTPServerError.exposedPlaintext(host: "example.org")) { try await server.start() }
    }

    // MARK: Reload

    @Test("After a renewal and a reload, new connections get the new certificate and open ones are untouched")
    func reloadServesTheRenewal() async throws {
        let material = try TestTLS(seed: 1, commonName: "First Authority")
        defer { material.cleanUp() }
        let before = try material.clientContext()
        let running = try await startServer(tls: material.files, handler: ok("served"))
        try await withGroup { group in
            let open = try await RawClient.connect(to: running.address, group: group, tls: before)
            try await open.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await open.response()?.status == 200)

            try material.renew(seed: 2)
            let outcome = try #require(running.server.reloadTLS())
            guard case .reloaded = outcome else {
                Issue.record("not reloaded: \(outcome)")
                return
            }

            // A client that trusts only the first authority no longer completes a handshake with new connections.
            let stale = try await RawClient.connect(to: running.address, group: group, tls: before)
            try? await stale.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await stale.waitUntilClosed())
            #expect(!stale.handshakeCompleted)

            // One that trusts the renewal does.
            let fresh = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
            try await fresh.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await fresh.response()?.text == "served")

            // The connection opened before the reload keeps working.
            try await open.send("GET /y HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await open.response()?.status == 200)
            await open.close()
            await fresh.close()
        }
        await running.server.shutdown()
    }

    @Test("A reload with unfit files fails, says what it is still serving, and changes nothing")
    func reloadFailureKeepsServing() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: ok("still here"))
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: material.chainPath))
        let outcome = try #require(running.server.reloadTLS())
        guard case .failed = outcome else {
            Issue.record("did not fail: \(outcome)")
            return
        }
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
            try await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await client.response()?.text == "still here")
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("Reloading when nothing has changed, in the if-changed mode, says so")
    func reloadUnchanged() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files)
        guard case .unchanged = try #require(running.server.reloadTLS(.ifChanged)) else {
            Issue.record("expected unchanged")
            return
        }
        // With no mode given, a reload happens whether or not the files changed: somebody asked for it.
        guard case .reloaded = try #require(running.server.reloadTLS()) else {
            Issue.record("the default mode did not reload")
            return
        }
        await running.server.shutdown()
    }

    @Test("There is nothing to reload on a server without TLS, or one that is not running")
    func reloadWithoutTLS() async throws {
        let idle = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: ok())
        #expect(idle.reloadTLS() == nil)
        let running = try await startServer()
        #expect(running.server.reloadTLS() == nil)
        await running.server.shutdown()
        #expect(running.server.reloadTLS() == nil)
    }
}

/// A flag a test can read while a task sets it.
// Justification: the only mutable state is one Bool, and every read and write of it holds the same lock.
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
