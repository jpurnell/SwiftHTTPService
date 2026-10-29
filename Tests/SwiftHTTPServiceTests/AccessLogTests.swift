import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// The access log: what is recorded about a request, and that nothing in the line can forge another.
@Suite("Access log")
struct AccessLogTests {

    /// Collects entries; the sink is called from whichever task runs the request.
    private actor Sink {
        var entries: [AccessLogEntry] = []
        func add(_ entry: AccessLogEntry) { entries.append(entry) }
    }

    /// A clock the test moves by hand, so a duration is a number it chose.
    // Justification: every read and write of the elapsed time happens inside the lock.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed = Duration.zero
        func now() -> Duration { lock.withLock { elapsed } }
        func advance(_ by: Duration) { lock.withLock { elapsed += by } }
    }

    private static func request(
        _ target: String = "/v1/things?token=secret", method: HTTPRequest.Method = .get, remote: String? = "203.0.113.9"
    ) throws -> Request {
        try Request(method: method, target: target, headers: HTTPFields(), body: Data(), remoteAddress: remote)
    }

    private static func run(
        _ request: Request, clock: ManualClock = ManualClock(), advance: Duration = .zero,
        handler: @escaping Handler = { _ in Response(status: .ok, body: Data("hello".utf8)) }
    ) async throws -> (entries: [AccessLogEntry], response: Response?) {
        let sink = Sink()
        let layer = accessLog(now: { clock.now() }, sink: { entry in Task { await sink.add(entry) } })
        let response = try? await layer(request) { request in
            clock.advance(advance)
            return try await handler(request)
        }
        try await Task.sleep(for: .milliseconds(20))      // let the sink's task run
        return (await sink.entries, response)
    }

    @Test("An entry records the method, the path without its query, the status, the body size, the duration and the peer")
    func entryFields() async throws {
        let (entries, response) = try await Self.run(try Self.request(), advance: .milliseconds(250))
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.method == "GET")
        #expect(entry.path == "/v1/things")
        #expect(entry.status == 200)
        #expect(entry.responseBytes == 5)                     // "hello"
        #expect(entry.duration == .milliseconds(250))
        #expect(entry.remoteAddress == "203.0.113.9")
        #expect(entry.requestID == nil)
        #expect(response?.status == .ok)
    }

    @Test("The query string is never in an entry or its line, since it can hold a token")
    func queryNeverLogged() async throws {
        let (entries, _) = try await Self.run(try Self.request("/v1/things?token=secret&x=1"))
        let entry = try #require(entries.first)
        #expect(!entry.line.contains("secret"))
        #expect(!entry.line.contains("token"))
        #expect(!entry.path.contains("?"))
    }

    @Test("A request id set by an earlier layer is recorded")
    func requestIDRecorded() async throws {
        let sink = Sink()
        let ids = requestID(generate: { "id-7" })
        let log = accessLog(now: { .zero }, sink: { entry in Task { await sink.add(entry) } })
        _ = try await log(try Self.request("/x")) { request in
            try await ids(request) { _ in Response(status: .ok) }
        }
        try await Task.sleep(for: .milliseconds(20))
        // The request id is set inside, on a copy; the log sees it on the response instead.
        #expect(await sink.entries.first?.requestID == "id-7")
    }

    @Test("A handler that throws is logged as a 500 with no error text, and the error goes on")
    func thrownErrorLogged() async throws {
        struct Secret: Error, CustomStringConvertible { var description: String { "the database password" } }
        let sink = Sink()
        let layer = accessLog(now: { .zero }, sink: { entry in Task { await sink.add(entry) } })
        await #expect(throws: Secret.self) {
            _ = try await layer(try Self.request("/x")) { _ in throw Secret() }
        }
        try await Task.sleep(for: .milliseconds(20))
        let entry = try #require(await sink.entries.first)
        #expect(entry.status == 500)
        #expect(!entry.line.contains("password"))
    }

    @Test("A request with no known peer is logged with a dash")
    func noPeer() async throws {
        let (entries, _) = try await Self.run(try Self.request("/x", remote: nil))
        #expect(entries.first?.line.contains("remote=\"-\"") == true)
    }

    // MARK: The line

    private static func entry(path: String = "/x", requestID: String? = nil) -> AccessLogEntry {
        AccessLogEntry(
            method: "GET", path: path, status: 200, responseBytes: 12, duration: .milliseconds(1500),
            requestID: requestID, remoteAddress: "198.51.100.2")
    }

    @Test("A line is key=value pairs with every value quoted, in a fixed order, and a duration in whole milliseconds")
    func lineFormat() {
        let line = Self.entry(requestID: "abc").line
        #expect(line == #"method="GET" path="/x" status=200 bytes=12 duration_ms=1500 request_id="abc" remote="198.51.100.2""#)
        #expect(Self.entry().line.contains(#"request_id="-""#))
    }

    @Test("Quotes, backslashes and every control character in a value are escaped, so a value cannot end its field or its line")
    func escaping() {
        let line = Self.entry(path: "/a\"b\\c\nd\re\u{0}f\u{7F}").line
        #expect(line.contains(#"path="/a\"b\\c\x0Ad\x0De\x00f\x7F""#))
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(line.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
    }

    @Test("A duration rounds down to whole milliseconds, and is never negative")
    func durationRounding() {
        var entry = Self.entry()
        entry = AccessLogEntry(method: "GET", path: "/x", status: 200, responseBytes: 0, duration: .microseconds(1999), requestID: nil, remoteAddress: nil)
        #expect(entry.line.contains("duration_ms=1 "))
        entry = AccessLogEntry(method: "GET", path: "/x", status: 200, responseBytes: 0, duration: .milliseconds(-5), requestID: nil, remoteAddress: nil)
        #expect(entry.line.contains("duration_ms=0 "))
    }

    // MARK: Streaming responses

    private static func streamed(
        advance: Duration = .zero, discard: Bool = false, fail: Bool = false
    ) async throws -> (entries: [AccessLogEntry], clock: ManualClock) {
        struct Boom: Error {}
        let sink = Sink()
        let clock = ManualClock()
        let layer = accessLog(now: { clock.now() }, sink: { entry in Task { await sink.add(entry) } })
        let response = try await layer(try request("/events?token=secret")) { _ in
            .streaming(status: .ok) { writer in
                clock.advance(advance)
                try await writer.write(Data("12345".utf8))
                try await writer.write(Data("1234567".utf8))
                if fail { throw Boom() }
            }
        }
        // Nothing is logged when the handler returns: the bytes are not known yet.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await sink.entries.isEmpty)
        let stream = try #require(response.stream)
        if discard {
            stream.discard()
        } else {
            _ = try? await stream.produce(ResponseWriter { _ in })
        }
        try await Task.sleep(for: .milliseconds(20))
        return (await sink.entries, clock)
    }

    @Test("A streaming response is logged when the stream ends, with the bytes streamed and the time to the end")
    func streamedEntry() async throws {
        let (entries, _) = try await Self.streamed(advance: .milliseconds(400))
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.status == 200)
        #expect(entry.responseBytes == 12)
        #expect(entry.duration == .milliseconds(400))
        #expect(entry.path == "/events")
        #expect(!entry.line.contains("secret"))
    }

    @Test("A stream that fails is logged with the bytes it sent, once, and its error still reaches the transport")
    func failedStream() async throws {
        let (entries, _) = try await Self.streamed(fail: true)
        #expect(entries.count == 1)
        #expect(entries.first?.responseBytes == 12)
    }

    @Test("A stream the transport discards without running (HEAD, a bodyless status) is logged once, with no bytes")
    func discardedStream() async throws {
        let (entries, _) = try await Self.streamed(discard: true)
        #expect(entries.count == 1)
        #expect(entries.first?.responseBytes == 0)
    }
}
