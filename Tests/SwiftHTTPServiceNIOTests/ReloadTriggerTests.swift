import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import Testing
@testable import SwiftHTTPServiceNIO

/// The sources of reload triggers, and the server loop that acts on them.
@Suite("TLS reload triggers", .serialized)
struct ReloadTriggerTests {

    /// The first element of `stream`, or nil if none arrives in time.
    private func firstElement(of stream: AsyncStream<Void>, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: The timer

    @Test("A timer trigger yields once per interval, and ends with a CancellationError when the task that waits on it is cancelled")
    func timerYields() async throws {
        let stream = try TLSReloadTrigger.every(.milliseconds(30))
        let count = NIOLockedValueBox(0)
        let consumer = Task { () -> (any Error)? in
            var ended: (any Error)?
            do { for try await _ in stream { count.withLockedValue { $0 += 1 } } } catch { ended = error }
            return ended
        }
        try await Task.sleep(for: .milliseconds(400))
        consumer.cancel()
        let ending = await consumer.value                         // returns only because cancelling ended the stream
        let seen = count.withLockedValue { $0 }
        // 400 ms of 30 ms intervals is about 13; the bounds leave room for a busy machine and still tell
        // "once per interval" from "never" and from "in a tight loop".
        #expect((3...20).contains(seen), "saw \(seen)")
        #expect(ending is CancellationError, "ended with \(String(describing: ending))")
    }

    struct Bad: Sendable, CustomTestStringConvertible {
        let interval: Duration
        var testDescription: String { "\(interval)" }
    }

    @Test("An interval of zero, below zero or over a day is refused, naming the field and no value", arguments: [
        Bad(interval: .zero), Bad(interval: .seconds(-1)), Bad(interval: .seconds(86_401)),
    ])
    func timerValidation(_ bad: Bad) {
        #expect(throws: ConfigurationError(field: "interval", reason: .outOfRange)) { try TLSReloadTrigger.every(bad.interval) }
    }

    @Test("The edges of the interval, the shortest and a day, are accepted")
    func timerEdges() throws {
        #expect(throws: Never.self) { _ = try TLSReloadTrigger.every(.nanoseconds(1)) }
        #expect(throws: Never.self) { _ = try TLSReloadTrigger.every(.seconds(86_400)) }
    }

    // MARK: SIGHUP

    @Test("A SIGHUP to the process is one element of the hangup stream, and does not end the process")
    func hangupYields() async throws {
        let stream = TLSReloadTrigger.hangup()
        try await Task.sleep(for: .milliseconds(100))            // the signal source is installed
        kill(getpid(), SIGHUP)
        #expect(await firstElement(of: stream, within: .seconds(3)))
    }

    /// What `SIGHUP` is set to now, as a number, read without changing it.
    private func hangupDisposition() -> Int {
        var current = sigaction()
        sigaction(SIGHUP, nil, &current)
        #if canImport(Darwin)
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        #else
        return unsafeBitCast(current.__sigaction_handler.sa_handler, to: Int.self)
        #endif
    }

    @Test("While the stream lives SIGHUP is ignored; when it ends SIGHUP goes back to what it was")
    func hangupRestores() async throws {
        let ignored = unsafeBitCast(SIG_IGN, to: Int.self)
        let standard = unsafeBitCast(SIG_DFL, to: Int.self)
        signal(SIGHUP, SIG_DFL)                                  // the starting disposition: the default
        #expect(hangupDisposition() == standard)
        let stream = TLSReloadTrigger.hangup()
        let consumer = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(100))
        #expect(hangupDisposition() == ignored)                  // the signal source owns it now
        consumer.cancel()
        await consumer.value
        var after = -1
        for _ in 0..<100 {                                       // the termination handler runs a moment after the cancel
            after = hangupDisposition()
            if after == standard { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(after == standard, "left installed: \(after)")
    }

    // MARK: The server loop

    private final class Outcomes: Sendable {
        private let all = NIOLockedValueBox<[ReloadOutcome]>([])
        func add(_ outcome: ReloadOutcome) { all.withLockedValue { $0.append(outcome) } }
        var value: [ReloadOutcome] { all.withLockedValue { $0 } }
        func wait(for count: Int, timeout: Duration = .seconds(3)) async throws -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if value.count >= count { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return value.count >= count
        }
    }

    private func kind(_ outcome: ReloadOutcome) -> String {
        switch outcome {
        case .reloaded: "reloaded"
        case .unchanged: "unchanged"
        case .failed: "failed"
        }
    }

    @Test("Each trigger reloads once in the mode it was started with, so new connections get the renewal")
    func serverReloadsOnEachTrigger() async throws {
        let material = try TestTLS(seed: 1, commonName: "First Authority")
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: ok("served"))
        let (triggers, source) = AsyncStream<Void>.makeStream()
        let outcomes = Outcomes()
        let loop = Task { await running.server.reloadTLS(onEach: triggers, mode: .ifChanged, report: { outcomes.add($0) }) }

        // Nothing has changed: the check finds that out and replaces nothing.
        source.yield()
        #expect(try await outcomes.wait(for: 1))
        // A renewal: the next check picks it up.
        try material.renew(seed: 2)
        source.yield()
        #expect(try await outcomes.wait(for: 2))
        // And nothing has changed again.
        source.yield()
        #expect(try await outcomes.wait(for: 3))
        #expect(outcomes.value.map(kind) == ["unchanged", "reloaded", "unchanged"])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let fresh = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
        try await fresh.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(try await fresh.response()?.text == "served")
        await fresh.close()
        try await group.shutdownGracefully()

        source.finish()
        await loop.value                                          // the loop ends when the triggers do
        await running.server.shutdown()
    }

    @Test("In always mode a trigger reloads even when nothing changed")
    func alwaysMode() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files)
        let (triggers, source) = AsyncStream<Void>.makeStream()
        let outcomes = Outcomes()
        let loop = Task { await running.server.reloadTLS(onEach: triggers, mode: .always, report: { outcomes.add($0) }) }
        source.yield()
        #expect(try await outcomes.wait(for: 1))
        #expect(outcomes.value.map(kind) == ["reloaded"])
        source.finish()
        await loop.value
        await running.server.shutdown()
    }

    @Test("Files that are refused are reported and the old identity keeps being served")
    func failedReloadIsReported() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: ok("still"))
        let (triggers, source) = AsyncStream<Void>.makeStream()
        let outcomes = Outcomes()
        let loop = Task { await running.server.reloadTLS(onEach: triggers, mode: .always, report: { outcomes.add($0) }) }
        try Data("not a certificate".utf8).write(to: URL(fileURLWithPath: material.chainPath))
        source.yield()
        #expect(try await outcomes.wait(for: 1))
        #expect(outcomes.value.map(kind) == ["failed"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
        try await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(try await client.response()?.text == "still")
        await client.close()
        try await group.shutdownGracefully()
        source.finish()
        await loop.value
        await running.server.shutdown()
    }

    @Test("A timer drives the server loop: each tick is a check, and cancelling the task ends it")
    func timerDrivesTheServer() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files)
        let outcomes = Outcomes()
        let loop = Task { () -> (any Error)? in
            var ended: (any Error)?
            do { try await running.server.reloadTLS(onEach: try TLSReloadTrigger.every(.milliseconds(30)), mode: .ifChanged, report: { outcomes.add($0) }) }
            catch { ended = error }
            return ended
        }
        #expect(try await outcomes.wait(for: 3))
        #expect(outcomes.value.allSatisfy { kind($0) == "unchanged" })
        loop.cancel()
        #expect(await loop.value is CancellationError)
        await running.server.shutdown()
    }

    @Test("A trigger when the server is not running, or serves no TLS, reports nothing and ends nothing")
    func nothingToReload() async throws {
        let idle = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: ok())
        let (triggers, source) = AsyncStream<Void>.makeStream()
        let outcomes = Outcomes()
        let loop = Task { await idle.reloadTLS(onEach: triggers, mode: .always, report: { outcomes.add($0) }) }
        source.yield()
        source.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcomes.value.isEmpty)
        // Plain HTTP, started: still nothing to reload.
        _ = try await idle.start()
        source.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcomes.value.isEmpty)
        source.finish()
        await loop.value
        await idle.shutdown()
    }

    @Test("Cancelling the task that runs the loop ends it")
    func cancellationEnds() async throws {
        let idle = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: ok())
        let (triggers, _) = AsyncStream<Void>.makeStream()
        let loop = Task { () -> Bool in
            await idle.reloadTLS(onEach: triggers, mode: .always, report: { _ in })
            return true                                           // reached only if the loop returned
        }
        try await Task.sleep(for: .milliseconds(50))
        loop.cancel()
        #expect(await loop.value)
    }
}
