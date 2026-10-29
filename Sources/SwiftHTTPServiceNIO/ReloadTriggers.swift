// ReloadTriggers.swift
// SwiftHTTPServiceNIO
//
// When to reload the TLS identity: sources of triggers, and the server loop that acts on them.

import Dispatch
import Foundation
import SwiftHTTPService
import SwiftTLSKit

/// Sources of "reload now" triggers for ``HTTPServer/reloadTLS(onEach:mode:report:)``.
///
/// SwiftTLSKit supplies the loop and deliberately no sources; these are the two every executable wants.
/// A signal means somebody has just renewed the files, so pair it with ``ReloadMode/always``; a timer means
/// nobody has said anything, so pair it with ``ReloadMode/ifChanged``.
public enum TLSReloadTrigger {

    /// One element for each `SIGHUP` the process receives.
    ///
    /// For as long as the stream lives the signal's default action, ending the process, is replaced by this
    /// stream. When the stream ends the signal source is cancelled and the disposition found at the start is
    /// put back, so a process that had `SIGHUP` ignored (run under `nohup`) is left that way.
    public static func hangup() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let previous = signal(SIGHUP, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: DispatchQueue.global())
            source.setEventHandler { continuation.yield() }
            continuation.onTermination = { _ in
                source.cancel()
                signal(SIGHUP, previous)
            }
            source.resume()
        }
    }

    /// One element for each `interval`, for a periodic check.
    ///
    /// The stream ends when the task iterating it is cancelled: either by finishing, or by throwing a
    /// `CancellationError`, depending on whether the cancel arrives before the next wait begins or during it. It is pull-based: each element is produced when the consumer asks for
    /// the next, so no task runs in the background to clean up, and a consumer slower than the interval gets the
    /// next element when it asks, not a queue of the ones it missed.
    ///
    /// - Parameter interval: Above zero and at most a day.
    /// - Throws: ``ConfigurationError`` naming `interval` if it is outside that range. Nothing is clamped.
    public static func every(_ interval: Duration) throws(ConfigurationError) -> AsyncThrowingStream<Void, any Error> {
        guard interval > .zero, interval <= .seconds(86_400) else {
            throw ConfigurationError(field: "interval", reason: .outOfRange)
        }
        return AsyncThrowingStream(unfolding: {
            try await Task.sleep(for: interval)
            return ()
        })
    }
}

extension HTTPServer {

    /// Reloads the TLS identity once for each element of `triggers`, until the sequence ends or the task is
    /// cancelled.
    ///
    /// Each trigger goes through the server's state as it is then, so the loop may be started before
    /// ``start()`` and carries on across a restart. A trigger that arrives while the server is not running,
    /// or serves no TLS, reports nothing and is dropped. The files are validated completely first: if they
    /// are unfit, the outcome says so and the old identity keeps being served.
    ///
    /// ```swift
    /// import SwiftHTTPService
    /// import SwiftHTTPServiceNIO
    ///
    /// let server = HTTPServer(configuration: try ServiceConfiguration(port: 8443)) { _ in .empty(.ok) }
    /// Task { await server.reloadTLS(onEach: TLSReloadTrigger.hangup(), mode: .always, report: { print($0) }) }
    /// ```
    ///
    /// - Parameters:
    ///   - triggers: When to reload: ``TLSReloadTrigger/hangup()``, ``TLSReloadTrigger/every(_:)``, or a stream
    ///     of your own (wrap any other sequence in an `AsyncStream`). The elements themselves are ignored.
    ///   - mode: What each trigger asks for. No default on purpose: a signal is ``ReloadMode/always`` and a
    ///     timer ``ReloadMode/ifChanged``, and the call site knows which it holds.
    ///   - report: Called with each outcome, in order: the place to log it. See
    ///     ``ReloadOutcome/suggestedLogLevel`` for how serious each is.
    public func reloadTLS(
        onEach triggers: AsyncStream<Void>, mode: ReloadMode, report: @Sendable (ReloadOutcome) -> Void
    ) async {
        for await _ in triggers {
            if let outcome = reloadTLS(mode) { report(outcome) }
        }
    }

    /// The same for a trigger stream that can throw, which is what ``TLSReloadTrigger/every(_:)`` is: when the task
    /// running this is cancelled it returns, or throws `CancellationError`, depending on when the cancel arrives.
    ///
    /// - Throws: What the stream throws.
    public func reloadTLS(
        onEach triggers: AsyncThrowingStream<Void, any Error>, mode: ReloadMode, report: @Sendable (ReloadOutcome) -> Void
    ) async throws {
        for try await _ in triggers {
            if let outcome = reloadTLS(mode) { report(outcome) }
        }
    }
}
