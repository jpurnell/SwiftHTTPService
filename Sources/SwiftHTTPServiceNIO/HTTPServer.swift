// HTTPServer.swift
// SwiftHTTPServiceNIO
//
// The server: start it, let it serve, shut it down gracefully.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit

/// Why a server did not start. None carries a file's contents or a peer's bytes.
public enum HTTPServerError: Error, Equatable, Sendable {
    /// ``HTTPServer/start()`` was called on a server that has been started before.
    case alreadyStarted
    /// The TLS identity is unfit to serve: a file is missing, unreadable or too open, the chain holds no
    /// certificate, the key does not belong to the certificate, or the leaf has expired. SwiftTLSKit's typed
    /// error says which, and names the path (never the contents). The server can be started again once the
    /// files are fixed.
    case tlsIdentity(ServerIdentityError)
    /// The host is not loopback and no TLS identity is configured, so the server would serve plaintext to
    /// the network. The server can be started again with a loopback host or with TLS.
    case exposedPlaintext(host: String)
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
/// import SwiftHTTPService
/// import SwiftHTTPServiceNIO
///
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
        /// Taken out of the box by the shutdown, which must let go of it before the loops stop.
        let quiescing: NIOLockedValueBox<ServerQuiescingHelper?>
        let tls: ReloadableServerTLS?
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
    ///   - refusals: What to do about the transport's own refusals: give them the server's body, and count them.
    ///     By default nothing, and the fixed bodies stand.
    public init(configuration: ServiceConfiguration, handler: @escaping Handler, refusals: RefusalHooks = RefusalHooks()) {
        self.context = ServerContext(configuration: configuration, handler: handler, refusals: refusals)
    }

    /// Creates a server for a ``Router``, wiring its per-route body bounds to the transport.
    ///
    /// The router is wrapped in `middleware`, the first outermost, and each route's own bound
    /// (``Router/add(_:_:maximumBodyBytes:middleware:_:)``) replaces the server's global one for that route,
    /// checked after the head and before any body is read. Prefer this to passing `router.handler`, which would
    /// serve the routes but leave their bounds unknown to the transport.
    ///
    /// - Parameters:
    ///   - configuration: The validated configuration.
    ///   - router: The routes.
    ///   - middleware: Layers around the whole router, the first outermost.
    ///   - refusals: What to do about the transport's own refusals. By default nothing.
    public init(configuration: ServiceConfiguration, router: Router, middleware: [Middleware] = [], refusals: RefusalHooks = RefusalHooks()) {
        self.context = ServerContext(
            configuration: configuration, handler: wrap(router.handler, with: middleware), refusals: refusals,
            routeBodyLimit: { method, target in router.maximumBodyBytes(for: method, target: target) })
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
        let tls: ReloadableServerTLS?
        if let files = configuration.tls {
            do throws(ServerIdentityError) {
                tls = try ReloadableServerTLS(
                    identity: ServerIdentity(certificateChainPath: files.certificateChainPath, privateKeyPath: files.privateKeyPath),
                    options: ServerTLSOptions(minimumVersion: .tls12, applicationProtocols: ProtocolNegotiation.offer(for: configuration.protocols)),
                    now: { Date() })
            } catch {
                lifecycle.withLockedValue { $0 = .new }
                throw HTTPServerError.tlsIdentity(error)
            }
        } else {
            tls = nil
        }
        // Plaintext is for loopback. SwiftTLSKit decides what counts as exposed, so every server of the
        // owner's means the same by it.
        if BindExposure.classify(host: configuration.host, tlsConfigured: tls != nil).isExposedPlaintext {
            lifecycle.withLockedValue { $0 = .new }
            throw HTTPServerError.exposedPlaintext(host: configuration.host)
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(System.coreCount, 4)))
        let registry = ConnectionRegistry(maximum: configuration.limits.maximumConnections)
        // In a box so that whoever stops the server can let go of it before the loops stop (see performShutdown).
        let quiescing = NIOLockedValueBox<ServerQuiescingHelper?>(ServerQuiescingHelper(group: group))
        let context = self.context
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let helper = quiescing.withLockedValue({ $0 }) else { throw ChannelError.ioOnClosedChannel }
                    try channel.pipeline.syncOperations.addHandler(helper.makeServerChannelHandler(channel: channel))
                }
            }
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Over TLS an answer costs a handshake, which is the one thing a server at its cap should not be made
                // to do for strangers (and HTTP/2 could not be answered before it at all): there the connection is
                // closed unanswered. In plaintext it is told, cheaply, that the server is busy (BusyRefusalHandler).
                switch registry.admit(channel, mayRefuse: tls == nil) {
                case .admitted:
                    channel.closeFuture.whenComplete { _ in registry.remove(channel) }
                    return PipelineBuilder.installFuture(on: channel, context: context, tls: tls)
                case .refuse:
                    channel.closeFuture.whenComplete { _ in registry.endRefusal() }
                    return channel.eventLoop.submit {
                        try channel.pipeline.syncOperations.addHandler(BusyRefusalHandler(server: context))
                    }
                case .drop:
                    return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.bind(host: configuration.host, port: Int(configuration.port)).get()
        } catch {
            quiescing.withLockedValue { $0 = nil }      // before the loops stop, as in performShutdown
            await Self.shutDown(group)
            lifecycle.withLockedValue { $0 = .stopped }
            throw HTTPServerError.bindFailed
        }
        lifecycle.withLockedValue { $0 = .running(Running(group: group, channel: channel, registry: registry, quiescing: quiescing, tls: tls)) }
        let local = channel.localAddress
        return BoundAddress(host: local?.ipAddress ?? configuration.host, port: local?.port ?? Int(configuration.port))
    }

    /// Takes a renewed certificate and key from the configured files, without a restart.
    ///
    /// New connections are served with the new identity; connections already open are not touched. The new
    /// files are validated completely first, and if they are unfit the old identity keeps being served and
    /// the outcome says so. Wire this to whatever signals a renewal (a hangup, a timer, an admin call); see
    /// SwiftTLSKit's `ReloadableServerTLS.reloadOnEach`.
    ///
    /// - Returns: What happened, or nil if the server is not running or serves no TLS.
    @discardableResult
    public func reloadTLS(_ mode: ReloadMode = .always) -> ReloadOutcome? {
        let tls: ReloadableServerTLS? = lifecycle.withLockedValue { state in
            guard case .running(let running) = state else { return nil }
            return running.tls
        }
        return tls?.reload(mode)
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
        // Closes the listening socket, tells every open connection to quiesce, and completes when the last
        // of them has closed. The grace period is ours: when it ends, whatever is left is closed.
        let finished = running.group.next().makePromise(of: Void.self)
        var helper = running.quiescing.withLockedValue { box -> ServerQuiescingHelper? in
            defer { box = nil }
            return box
        }
        helper?.initiateShutdown(promise: finished)
        let grace = context.configuration.limits.shutdownGrace.timeAmount
        let deadline = running.group.next().scheduleTask(in: grace) { running.registry.closeAll() }
        await withCheckedContinuation { continuation in
            finished.futureResult.whenComplete { _ in continuation.resume() }
        }
        deadline.cancel()
        // The helper's `deinit` completes a promise on one of the group's loops, so it has to be gone before
        // the loops are. It would otherwise be released when this task ends, after they had stopped, and NIO
        // reports that (and says it will one day crash).
        helper = nil
        await Self.shutDown(running.group)
        lifecycle.withLockedValue { $0 = .stopped }
    }

    private static func shutDown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }
}
