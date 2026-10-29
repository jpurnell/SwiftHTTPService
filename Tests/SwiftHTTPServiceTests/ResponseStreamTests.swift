import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

@Suite("Streaming responses")
struct ResponseStreamTests {

    /// Collects what a producer writes, in order.
    private actor Sink {
        var chunks: [Data] = []
        func add(_ data: Data) { chunks.append(data) }
    }

    @Test("A streaming response has a status and headers, no body of its own, and a stream")
    func shape() throws {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain"
        let response = Response.streaming(status: .ok, headers: headers) { _ in }
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/plain")
        #expect(response.body.isEmpty)
        _ = try #require(response.stream)                         // present: a streaming response carries its producer
    }

    @Test("An ordinary response has no stream")
    func ordinaryHasNone() {
        #expect(Response(status: .ok, body: Data("x".utf8)).stream == nil)
        #expect(Response.empty(.noContent).stream == nil)
    }

    @Test("A producer's writes reach the writer's destination in order, and an empty write is dropped, since an empty chunk would end a chunked body")
    func writesInOrder() async throws {
        let sink = Sink()
        let response = Response.streaming(status: .ok) { writer in
            try await writer.write(Data("a".utf8))
            try await writer.write(Data())
            try await writer.write(Data("bc".utf8))
        }
        let stream = try #require(response.stream)
        try await stream.produce(ResponseWriter { data in await sink.add(data) })
        #expect(await sink.chunks == [Data("a".utf8), Data("bc".utf8)])
    }

    @Test("An error from the destination reaches the producer, and an error from the producer reaches the caller")
    func errorsPass() async throws {
        struct Gone: Error, Equatable {}
        let response = Response.streaming(status: .ok) { writer in
            try await writer.write(Data("a".utf8))
            Issue.record("the producer went on after a failed write")
        }
        let stream = try #require(response.stream)
        await #expect(throws: Gone.self) {
            try await stream.produce(ResponseWriter { _ in throw Gone() })
        }
        let failing = try #require(Response.streaming(status: .ok) { _ in throw Gone() }.stream)
        await #expect(throws: Gone.self) { try await failing.produce(ResponseWriter { _ in }) }
    }

    @Test("Two streams are equal only if they are the same stream, so a response compares by identity")
    func identity() throws {
        let one = Response.streaming(status: .ok) { _ in }
        let two = Response.streaming(status: .ok) { _ in }
        #expect(one == one)
        #expect(one != two)
        #expect(try #require(one.stream) == (try #require(one.stream)))
        #expect(try #require(one.stream) != (try #require(two.stream)))
        var changed = one
        changed.headers[.contentType] = "x"
        #expect(changed != one)                                  // the headers still count
    }

    @Test("Wrapping a stream counts the bytes written and reports the end once, success or failure")
    func counting() async throws {
        struct Boom: Error {}
        actor Report {
            var reports: [(Int, Bool)] = []
            func add(_ bytes: Int, _ failed: Bool) { reports.append((bytes, failed)) }
        }
        let report = Report()
        let ok = try #require(Response.streaming(status: .ok) { writer in
            try await writer.write(Data(repeating: 1, count: 5))
            try await writer.write(Data(repeating: 2, count: 7))
        }.stream)
        let counted = ok.observing { bytes, error in Task { await report.add(bytes, error != nil) } }
        let sink = Sink()
        try await counted.produce(ResponseWriter { data in await sink.add(data) })
        let bad = try #require(Response.streaming(status: .ok) { writer in
            try await writer.write(Data(repeating: 1, count: 3))
            throw Boom()
        }.stream)
        await #expect(throws: Boom.self) { try await bad.observing { bytes, error in Task { await report.add(bytes, error != nil) } }.produce(ResponseWriter { _ in }) }
        try await Task.sleep(for: .milliseconds(30))
        let reports = await report.reports.sorted { $0.0 < $1.0 }
        #expect(reports.map(\.0) == [3, 12])
        #expect(reports.map(\.1) == [true, false])
        #expect(await sink.chunks.count == 2)                    // the destination still got every write
        #expect(counted != ok)                                   // a wrapped stream is a different stream
    }

    @Test("The reasons a stream can end early are distinct and printable")
    func streamErrors() {
        let all: [StreamError] = [.closed, .byteLimit, .writeTimeout, .durationLimit]
        #expect(Set(all.map(\.description)).count == 4)
        #expect(StreamError.closed.description == "the connection is closed")
    }

    @Test("Observing twice tells both observers when a stream is discarded, once each")
    func discardReachesEveryObserver() async throws {
        actor Count {
            var inner = 0, outer = 0
            func innerHeard() { inner += 1 }
            func outerHeard() { outer += 1 }
        }
        let count = Count()
        let base = try #require(Response.streaming(status: .ok) { _ in }.stream)
        let wrapped = base
            .observing { bytes, _ in Task { await count.innerHeard(); #expect(bytes == 0) } }
            .observing { bytes, _ in Task { await count.outerHeard(); #expect(bytes == 0) } }
        wrapped.discard()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await count.inner == 1)
        #expect(await count.outer == 1)
    }
}
