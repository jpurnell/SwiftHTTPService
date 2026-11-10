import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Mutated HTTP/1.1 requests sent over a real socket to a server with small, short limits, with a seeded generator.
/// Each case is judged against what the README documents: a refusal is a `4xx` and a close, never a hang and never a
/// `5xx`, the handler is never run for a request the documentation says is refused, and after every batch a
/// well-behaved client is still served.
@Suite("Fuzzing the HTTP/1.1 head over a socket", .serialized)
struct HeadFuzzTests {

    static let seed = TransportFuzzTests.headSeed
    static let maximumHeaderBytes = 2048
    static let maximumHeaderCount = 20
    /// The client gives up on a case after this long; every limit in the server is 300 ms, so this is a hang.
    static let hangBound = Duration.seconds(5)

    struct Outcome: Sendable {
        var status: Int?
        var closed: Bool
        var hung: Bool
        /// What the client got of the request out before the connection ended, of how many bytes, and what it received.
        var sent = 0
        var of = 0
        var received = 0
    }

    private static func limits() -> Limits {
        var limits = Limits()
        limits.maximumHeaderBytes = maximumHeaderBytes
        limits.maximumHeaderCount = maximumHeaderCount
        limits.maximumBodyBytes = 1024
        limits.headerReadTimeout = .milliseconds(300)
        limits.bodyReadTimeout = .milliseconds(300)
        limits.idleTimeout = .milliseconds(300)
        return limits
    }

    /// Sends `bytes` (in the pieces `cuts` makes of them), then waits for a whole response, or for the connection to close.
    private static func exchange(
        _ bytes: [UInt8], cuts: [Int], to address: BoundAddress, group: MultiThreadedEventLoopGroup
    ) async throws -> Outcome {
        let client = try await RawClient.connect(to: address, group: group)
        var start = 0
        for cut in cuts + [bytes.count] where cut > start && cut <= bytes.count {
            // A reset by the server after a refusal makes a later write fail; that is the server's right.
            if (try? await client.channel.writeAndFlush(ByteBuffer(bytes: bytes[start..<cut])).get()) == nil { break }
            start = cut
        }
        let deadline = ContinuousClock.now + hangBound
        var outcome = Outcome(status: nil, closed: false, hung: false, of: bytes.count)
        while ContinuousClock.now < deadline {
            // Closed is read before the bytes: everything that arrived before the close is in `received` by then. Read
            // the other way round, the last of a response and the FIN can land between the two reads, and a complete
            // answer is recorded as "closed with nothing".
            let ended = client.isClosed
            var data = client.received
            if let response = PipelineHarness.parse(&data) { outcome.status = response.status; break }
            if ended { outcome.closed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if outcome.status == nil, !outcome.closed { outcome.hung = !client.isClosed }
        outcome.sent = start
        outcome.received = client.received.count
        await client.close()
        return outcome
    }

    /// Runs `cases` with at most 24 in flight and returns the outcomes in order.
    private static func run(
        _ cases: [(bytes: [UInt8], cuts: [Int])], to address: BoundAddress, group: MultiThreadedEventLoopGroup
    ) async throws -> [Outcome] {
        var results = [Outcome?](repeating: nil, count: cases.count)
        var next = 0
        try await withThrowingTaskGroup(of: (Int, Outcome).self) { tasks in
            func launch() {
                guard next < cases.count else { return }
                let index = next
                next += 1
                let request = cases[index]
                tasks.addTask { (index, try await exchange(request.bytes, cuts: request.cuts, to: address, group: group)) }
            }
            for _ in 0..<24 { launch() }
            while let (index, outcome) = try await tasks.next() {
                results[index] = outcome
                launch()
            }
        }
        return results.map { $0 ?? Outcome(status: nil, closed: false, hung: true) }
    }

    private static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// A valid request: its head lines (without line ends) and its body.
    struct Base {
        let name: String
        let lines: [String]
        let body: String
        var hasBody: Bool { !body.isEmpty }
        var text: String { lines.joined(separator: "\r\n") + "\r\n\r\n" + body }
    }

    /// Valid requests, each carrying `Host` once and `Content-Length` once if it has a body.
    private static func baseRequests() -> [Base] {
        [
            Base(name: "get", lines: ["GET /a/b?x=1&y=2 HTTP/1.1", "Host: example.test", "User-Agent: fuzz", "Accept: */*"], body: ""),
            Base(name: "get-close", lines: ["GET / HTTP/1.1", "Host: example.test", "Connection: close"], body: ""),
            Base(name: "post", lines: ["POST /p HTTP/1.1", "Host: example.test", "Content-Type: text/plain", "Content-Length: 5"], body: "hello"),
            Base(name: "head-many", lines: ["GET /m HTTP/1.1", "Host: example.test", "X-A: 1", "X-B: 2", "X-C: 3", "Cookie: a=1; b=2"], body: ""),
        ]
    }

    /// Some split points inside a request of `count` bytes, so that it arrives in pieces.
    private static func cuts(_ count: Int, _ rng: inout SplitMix64) -> [Int] {
        guard count > 2, rng.chance(40) else { return [] }
        return Array(Set((0..<rng.int(1...3)).map { _ in rng.int(1...count - 1) })).sorted()
    }

    private func withServer<T>(
        handled: NIOLockedValueBox<Int>, _ body: (Running, MultiThreadedEventLoopGroup) async throws -> T
    ) async throws -> T {
        let running = try await startServer(limits: Self.limits(), handler: { _ in
            handled.withLockedValue { $0 += 1 }
            return Response(status: .ok, body: Data("ok".utf8))
        })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let result: T
        do { result = try await body(running, group) } catch {
            try? await group.shutdownGracefully()
            await running.server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return result
    }

    /// A well-behaved request, to show the server is still serving.
    private static func healthy(_ running: Running, _ group: MultiThreadedEventLoopGroup) async throws -> Int? {
        try await exchange(ascii(baseRequests()[0].text), cuts: [], to: running.address, group: group).status
    }

    @Test("Valid requests, however they are split across writes, are answered 200 (200 seeded cases)", .timeLimit(.minutes(3)))
    func validRequests() async throws {
        var rng = SplitMix64(seed: Self.seed)
        let handled = NIOLockedValueBox(0)
        try await withServer(handled: handled) { running, group in
            var cases: [(bytes: [UInt8], cuts: [Int])] = []
            for _ in 0..<200 {
                let bytes = Self.ascii(rng.pick(Self.baseRequests()).text)
                cases.append((bytes, Self.cuts(bytes.count, &rng)))
            }
            let outcomes = try await Self.run(cases, to: running.address, group: group)
            for (index, outcome) in outcomes.enumerated() { #expect(outcome.status == 200, "case \(index) seed \(Self.seed): \(outcome)") }
            #expect(handled.withLockedValue { $0 } == 200, "the handler runs once per request")
            recordMeasurement("HTTP head fuzz, valid", "200 cases, seed \(Self.seed)")
        }
    }

    @Test("A duplicated Host, or a duplicated Content-Length, is refused 400 and never reaches the handler (120 seeded cases)", .timeLimit(.minutes(3)))
    func duplicates() async throws {
        var rng = SplitMix64(seed: Self.seed &+ 1)
        let handled = NIOLockedValueBox(0)
        try await withServer(handled: handled) { running, group in
            var cases: [(bytes: [UInt8], cuts: [Int])] = []
            for _ in 0..<120 {
                let base = rng.pick(Self.baseRequests())
                var lines = base.lines
                let wanted = base.hasBody && rng.chance(50) ? "Content-Length:" : "Host:"
                guard let at = lines.firstIndex(where: { $0.hasPrefix(wanted) }) else { continue }
                // The copy is identical, or differs in value: both are ambiguous and both are refused.
                lines.insert(rng.chance(50) ? lines[at] : wanted + " " + String(rng.int(1...9)), at: rng.int(at...at + 1))
                let bytes = Self.ascii(lines.joined(separator: "\r\n") + "\r\n\r\n" + base.body)
                cases.append((bytes, Self.cuts(bytes.count, &rng)))
            }
            let outcomes = try await Self.run(cases, to: running.address, group: group)
            for (index, outcome) in outcomes.enumerated() { #expect(outcome.status == 400, "case \(index) seed \(Self.seed &+ 1): \(outcome)") }
            #expect(handled.withLockedValue { $0 } == 0, "a refused request must not reach the handler")
            #expect(try await Self.healthy(running, group) == 200)
            recordMeasurement("HTTP head fuzz, duplicates", "\(cases.count) cases, seed \(Self.seed &+ 1)")
        }
    }

    @Test("A head over the byte bound, or with more fields than allowed, is refused 431 and never reaches the handler, however much more the client sends (120 seeded cases)", .timeLimit(.minutes(3)))
    func oversize() async throws {
        var rng = SplitMix64(seed: Self.seed &+ 2)
        let handled = NIOLockedValueBox(0)
        try await withServer(handled: handled) { running, group in
            var cases: [(bytes: [UInt8], cuts: [Int])] = []
            for _ in 0..<120 {
                var target = "/"
                var tail = " HTTP/1.1\r\nHost: example.test\r\n"
                switch rng.int(0...2) {
                case 0: target += String(repeating: "a", count: Self.maximumHeaderBytes + rng.int(1...4_000))
                case 1: tail += "X-Big: " + String(repeating: "b", count: Self.maximumHeaderBytes + rng.int(1...4_000)) + "\r\n"
                default: for index in 0..<(Self.maximumHeaderCount + rng.int(1...30)) { tail += "X-\(index): v\r\n" }
                }
                let bytes = Self.ascii("GET " + target + tail + "\r\n")
                cases.append((bytes, Self.cuts(bytes.count, &rng)))
            }
            let outcomes = try await Self.run(cases, to: running.address, group: group)
            for (index, outcome) in outcomes.enumerated() { #expect(outcome.status == 431, "case \(index) seed \(Self.seed &+ 2): \(outcome)") }
            #expect(handled.withLockedValue { $0 } == 0, "a refused request must not reach the handler")
            #expect(try await Self.healthy(running, group) == 200)
            recordMeasurement("HTTP head fuzz, oversize", "\(cases.count) cases, seed \(Self.seed &+ 2)")
        }
    }

    @Test("A request cut off anywhere is never answered 200 and never hangs: 408 or a close (200 seeded truncations)", .timeLimit(.minutes(3)))
    func truncated() async throws {
        var rng = SplitMix64(seed: Self.seed &+ 3)
        let handled = NIOLockedValueBox(0)
        try await withServer(handled: handled) { running, group in
            var cases: [(bytes: [UInt8], cuts: [Int])] = []
            for _ in 0..<200 {
                let full = Self.ascii(rng.pick(Self.baseRequests()).text)
                cases.append((Array(full[0..<rng.int(0...full.count - 1)]), []))
            }
            let outcomes = try await Self.run(cases, to: running.address, group: group)
            for (index, outcome) in outcomes.enumerated() {
                #expect(!outcome.hung, "case \(index) seed \(Self.seed &+ 3): the connection hung")
                #expect(outcome.status == nil || outcome.status == 408, "case \(index) seed \(Self.seed &+ 3): a truncated request got \(outcome)")
            }
            #expect(handled.withLockedValue { $0 } == 0, "an incomplete request must not reach the handler")
            #expect(try await Self.healthy(running, group) == 200)
            recordMeasurement("HTTP head fuzz, truncated", "\(cases.count) cases, seed \(Self.seed &+ 3)")
        }
    }

    @Test("Requests with bits flipped: always an answer from a short list of statuses or a close, never a hang, and the server keeps serving (400 seeded cases)", .timeLimit(.minutes(3)))
    func bitFlips() async throws {
        var rng = SplitMix64(seed: Self.seed &+ 4)
        let handled = NIOLockedValueBox(0)
        let allowed: Set<Int> = [200, 400, 404, 405, 408, 411, 413, 414, 421, 431, 501, 505]
        try await withServer(handled: handled) { running, group in
            var cases: [(bytes: [UInt8], cuts: [Int])] = []
            for _ in 0..<400 {
                var bytes = Self.ascii(rng.pick(Self.baseRequests()).text)
                for _ in 0..<rng.int(1...3) { bytes[rng.int(0...bytes.count - 1)] ^= UInt8(1) << UInt8(rng.int(0...7)) }
                cases.append((bytes, Self.cuts(bytes.count, &rng)))
            }
            let outcomes = try await Self.run(cases, to: running.address, group: group)
            var statuses: [Int: Int] = [:]
            for (index, outcome) in outcomes.enumerated() {
                #expect(!outcome.hung, "case \(index) seed \(Self.seed &+ 4): the connection hung: \(cases[index].bytes)")
                if let status = outcome.status {
                    statuses[status, default: 0] += 1
                    #expect(allowed.contains(status), "case \(index) seed \(Self.seed &+ 4): status \(status) for \(cases[index].bytes)")
                }
            }
            #expect(try await Self.healthy(running, group) == 200)
            recordMeasurement("HTTP head fuzz, bit flips", "\(cases.count) cases, seed \(Self.seed &+ 4); statuses \(statuses.sorted { $0.key < $1.key })")
        }
    }
}
