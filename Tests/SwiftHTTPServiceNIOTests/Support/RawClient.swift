import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOTLS
import SwiftHTTPService
import Testing
import SwiftTLSKit
import SwiftTLSKitTestSupport
@testable import SwiftHTTPServiceNIO

/// Collects what a connection delivers, whether it has closed, and what TLS negotiated.
// Justification: every piece of mutable state here is held in a NIOLockedValueBox, so reads and writes are serialised.
final class Collector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let received = NIOLockedValueBox(Data())
    let closed = NIOLockedValueBox(false)
    let negotiatedProtocol = NIOLockedValueBox<String?>(nil)
    let handshakeCompleted = NIOLockedValueBox(false)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received.withLockedValue { $0.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? []) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let negotiated) = event {
            negotiatedProtocol.withLockedValue { $0 = negotiated }
            handshakeCompleted.withLockedValue { $0 = true }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed.withLockedValue { $0 = true }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        closed.withLockedValue { $0 = true }
        context.close(promise: nil)
    }
}

/// A bare TCP (optionally TLS) client for tests: it writes the bytes it is told to and records what comes back.
struct RawClient: Sendable {
    let channel: any Channel
    let collector: Collector

    /// Connects to `address`. With `tls`, speaks TLS using that SwiftTLSKit client context, naming the server `localhost`.
    static func connect(
        to address: BoundAddress, group: MultiThreadedEventLoopGroup, tls: ClientTLSContext? = nil
    ) async throws -> RawClient {
        let collector = Collector()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try tls.addHandlers(to: channel.pipeline.syncOperations, serverHostname: "localhost") }
                    try channel.pipeline.syncOperations.addHandler(collector)
                }
            }
            .connect(host: address.host, port: address.port)
            .get()
        return RawClient(channel: channel, collector: collector)
    }

    func send(_ text: String) async throws {
        try await channel.writeAndFlush(ByteBuffer(string: text)).get()
    }

    var received: Data { collector.received.withLockedValue { $0 } }
    var isClosed: Bool { collector.closed.withLockedValue { $0 } }
    var negotiatedProtocol: String? { collector.negotiatedProtocol.withLockedValue { $0 } }
    var handshakeCompleted: Bool { collector.handshakeCompleted.withLockedValue { $0 } }

    /// Waits for a complete response, or nil on timeout.
    func response(timeout: Duration = .seconds(5)) async throws -> WireResponse? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            var data = received
            if let parsed = PipelineHarness.parse(&data) { return parsed }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// Waits for the server to close the connection.
    func waitUntilClosed(timeout: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isClosed { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return isClosed
    }

    func close() async {
        await withCheckedContinuation { continuation in
            channel.close().whenComplete { _ in continuation.resume() }
        }
    }
}

/// A generated authority and leaf, written to a temporary directory as the files a server reads.
///
/// SwiftTLSKitTestSupport makes the certificates when the test runs, so no key is checked in. The key file
/// is written with mode 0600, because SwiftTLSKit refuses a private key that others can read.
// Justification: a test owns one of these on one task; `authority` is replaced only by `renew`.
final class TestTLS: @unchecked Sendable {
    let directory: URL
    private(set) var authority: TestAuthority
    let chainPath: String
    let keyPath: String

    var files: TLSFiles { TLSFiles(certificateChainPath: chainPath, privateKeyPath: keyPath) }

    init(seed: UInt64 = 1, commonName: String = "Test Authority") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chainPath = directory.appendingPathComponent("chain.pem").path
        keyPath = directory.appendingPathComponent("key.pem").path
        authority = try TestAuthority(commonName: commonName, generator: SeededGenerator(seed: seed))
        try write(try authority.issueLeaf(dnsNames: ["localhost"], ipv4Addresses: [[127, 0, 0, 1]]))
    }

    /// Replaces the files with a leaf from another authority, as a renewal would.
    func renew(seed: UInt64, commonName: String = "Renewal Authority") throws {
        authority = try TestAuthority(commonName: commonName, generator: SeededGenerator(seed: seed))
        try write(try authority.issueLeaf(dnsNames: ["localhost"], ipv4Addresses: [[127, 0, 0, 1]]))
    }

    /// Writes any leaf over the files, with the permissions a good key has.
    func write(_ leaf: TestLeaf, keyMode: Int = 0o600) throws {
        try Data(leaf.chainPEM.utf8).write(to: URL(fileURLWithPath: chainPath))
        if FileManager.default.fileExists(atPath: keyPath) { try FileManager.default.removeItem(atPath: keyPath) }
        FileManager.default.createFile(
            atPath: keyPath, contents: Data(leaf.privateKeyPEM.utf8), attributes: [.posixPermissions: keyMode])
    }

    func clientContext(applicationProtocols: [String] = ["http/1.1"]) throws -> ClientTLSContext {
        try authority.clientContext(applicationProtocols: applicationProtocols)
    }

    /// Removes the temporary directory. A test that fails before this runs leaves it in the system temporary folder.
    func cleanUp() {
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove \(directory.path)")
            }
        }
    }
}

/// A running server on an ephemeral port, shut down by the test that made it.
struct Running: Sendable {
    let server: HTTPServer
    let address: BoundAddress
}

func startServer(
    limits: Limits = Limits(), tls: TLSFiles? = nil, handler: @escaping Handler = ok()
) async throws -> Running {
    let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: tls, limits: limits), handler: handler)
    let address = try await server.start()
    return Running(server: server, address: address)
}
