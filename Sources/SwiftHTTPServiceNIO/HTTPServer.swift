// HTTPServer.swift
// SwiftHTTPServiceNIO
//
// The server: start it, let it serve, shut it down gracefully.

import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOPosix
import NIOSSL
import SwiftHTTPService

/// Why a server did not start. None of these carries a path, a file's contents or a peer's bytes.
public enum HTTPServerError: Error, Equatable, Sendable {
    /// ``HTTPServer/start()`` was called on a server that has been started before.
    case alreadyStarted
    /// The certificate chain file is missing, unreadable or holds no certificate.
    case tlsCertificateUnreadable
    /// The private key file is missing, unreadable or not a PEM key.
    case tlsKeyUnreadable
    /// The certificate and key were read but cannot be used together (a key that does not belong to the certificate).
    case tlsIdentityRejected
    /// The listening socket could not be opened: the address is in use, not available, or not permitted.
    case bindFailed
}

/// The address a server is listening on.
public struct BoundAddress: Sendable, Equatable {
    /// The IP address, as text.
    public let host: String
    /// The port. With a configured port of zero, the one the system chose.
    public let port: Int

    /// Creates an address.
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// An HTTP/1.1 server over TCP, with TLS if configured.
///
/// ```swift
/// let server = HTTPServer(configuration: try ServiceConfiguration(port: 8080)) { request in
///     try .json(["hello": "world"])
/// }
/// let address = try await server.start()
/// // ... later
/// await server.shutdown()
/// ```
///
/// Every limit in ``Limits`` is enforced: the request line and headers are bounded as they arrive, a body
/// is bounded by its declared or counted size, a header, a body and a keep-alive wait each have a deadline,
/// and the number of open connections is capped. Requests that could be read two ways (a `Content-Length`
/// with a `Transfer-Encoding`, a duplicate or malformed `Content-Length`, folded or malformed headers) are
/// refused. See ``ConnectionHandler`` for what is deliberately not supported.
public final class HTTPServer: Sendable {
    private struct Running {
        let group: MultiThreadedEventLoopGroup
        let channel: any Channel
        let registry: ConnectionRegistry
        let quiescing: ServerQuiescingHelper
    }

    private enum Lifecycle {
        case new
        case starting
        case running(Running)
        case stopping(Task<Void, Never>)
        case stopped
    }

    private let context: ServerContext
    private let lifecycle = NIOLockedValueBox<Lifecycle>(.new)

    /// Creates a server. Nothing is opened until ``start()``.
    ///
    /// - Parameters:
    ///   - configuration: The validated configuration.
    ///   - handler: Called once per request, after the request has been read and validated.
    public init(configuration: ServiceConfiguration, handler: @escaping Handler) {
        self.context = ServerContext(configuration: configuration, handler: handler)
    }

    /// Opens the listening socket and starts serving.
    ///
    /// - Returns: The address actually bound (useful with port zero).
    /// - Throws: ``HTTPServerError``. A server can be started once.
    public func start() async throws -> BoundAddress {
        let mayStart = lifecycle.withLockedValue { state -> Bool in
            guard case .new = state else { return false }
            state = .starting
            return true
        }
        guard mayStart else { throw HTTPServerError.alreadyStarted }
        let configuration = context.configuration
        let tls: NIOSSLContext?
        do {
            tls = try configuration.tls.map { try TLSIdentity.makeContext($0) }
        } catch {
            lifecycle.withLockedValue { $0 = .stopped }
            throw error
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(System.coreCount, 4)))
        let registry = ConnectionRegistry(maximum: configuration.limits.maximumConnections)
        let quiescing = ServerQuiescingHelper(group: group)
        let context = self.context
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(quiescing.makeServerChannelHandler(channel: channel))
                }
            }
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard !context.isDraining, registry.admit(channel) else {
                    return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                }
                channel.closeFuture.whenComplete { _ in registry.remove(channel) }
                return PipelineBuilder.installFuture(on: channel, context: context, tls: tls)
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.bind(host: configuration.host, port: Int(configuration.port)).get()
        } catch {
            await Self.shutDown(group)
            lifecycle.withLockedValue { $0 = .stopped }
            throw HTTPServerError.bindFailed
        }
        lifecycle.withLockedValue { $0 = .running(Running(group: group, channel: channel, registry: registry, quiescing: quiescing)) }
        let local = channel.localAddress
        return BoundAddress(host: local?.ipAddress ?? configuration.host, port: local?.port ?? Int(configuration.port))
    }

    /// Stops serving, gracefully.
    ///
    /// The listening socket closes first, so no new connection is accepted. A connection with no request
    /// in progress closes at once; one in the middle of a request finishes it, answers with
    /// `Connection: close` and closes. After ``Limits/shutdownGrace``, anything still open is closed.
    /// Returns when every connection has ended and the server's threads are gone. Safe to call more than
    /// once, and from several tasks: all of them return when shutdown is complete.
    public func shutdown() async {
        let pending: Task<Void, Never>? = lifecycle.withLockedValue { state in
            switch state {
            case .running(let running):
                let task = Task { await self.performShutdown(running) }
                state = .stopping(task)
                return task
            case .stopping(let task):
                return task
            case .new, .starting, .stopped:
                return nil
            }
        }
        await pending?.value
    }

    private func performShutdown(_ running: Running) async {
        context.beginDraining()
        running.registry.stopAdmitting()
        // Closes the listening socket, tells every open connection to quiesce, and completes when the last
        // of them has closed. The grace period is ours: when it ends, whatever is left is closed.
        let finished = running.group.next().makePromise(of: Void.self)
        running.quiescing.initiateShutdown(promise: finished)
        let grace = context.configuration.limits.shutdownGrace.timeAmount
        let deadline = running.group.next().scheduleTask(in: grace) { running.registry.closeAll() }
        await withCheckedContinuation { continuation in
            finished.futureResult.whenComplete { _ in continuation.resume() }
        }
        deadline.cancel()
        await Self.shutDown(running.group)
        lifecycle.withLockedValue { $0 = .stopped }
    }

    private static func shutDown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }
}
