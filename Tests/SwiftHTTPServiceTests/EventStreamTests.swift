import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// Server-sent events (the WHATWG HTML Standard, section 9.2): the format each field takes and the ways a field can
/// be abused. Expected text is worked out by hand from the specification's parsing rules.
@Suite("Event streams")
struct EventStreamTests {

    /// What a producer wrote, in order.
    private actor Sink {
        var text = ""
        func add(_ data: Data) { text += String(decoding: data, as: UTF8.self) }
    }

    private static func written(_ body: @escaping @Sendable (EventWriter) async throws -> Void) async throws -> String {
        let sink = Sink()
        let stream = try #require(Response.eventStream(produce: body).stream)
        try await stream.produce(ResponseWriter { data in await sink.add(data) })
        return await sink.text
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let send: @Sendable (EventWriter) async throws -> Void
        let expected: String
        var testDescription: String { name }
    }

    static let formats: [Case] = [
        Case(name: "data only", send: { try await $0.send(data: "hi") }, expected: "data: hi\n\n"),
        Case(name: "every field, in the order event, id, retry, data",
             send: { try await $0.send(data: "hi", event: "greeting", id: "7", retry: 3000) },
             expected: "event: greeting\nid: 7\nretry: 3000\ndata: hi\n\n"),
        Case(name: "a data value with a line feed is two data lines", send: { try await $0.send(data: "a\nb") }, expected: "data: a\ndata: b\n\n"),
        Case(name: "a carriage return and a line feed is one break", send: { try await $0.send(data: "a\r\nb") }, expected: "data: a\ndata: b\n\n"),
        Case(name: "a lone carriage return is a break", send: { try await $0.send(data: "a\rb") }, expected: "data: a\ndata: b\n\n"),
        Case(name: "a trailing break is an empty last data line, so the client keeps it", send: { try await $0.send(data: "a\n") }, expected: "data: a\ndata: \n\n"),
        Case(name: "empty data is still an event: one empty data line", send: { try await $0.send(data: "") }, expected: "data: \n\n"),
        Case(name: "a colon in the data is data", send: { try await $0.send(data: "a: b") }, expected: "data: a: b\n\n"),
        Case(name: "a leading space in the data is kept, as the first space after the colon is the only one removed",
             send: { try await $0.send(data: " x") }, expected: "data:  x\n\n"),
        Case(name: "retry 0 is a retry", send: { try await $0.send(data: "x", retry: 0) }, expected: "retry: 0\ndata: x\n\n"),
        Case(name: "non-ASCII data is sent as UTF-8", send: { try await $0.send(data: "é") }, expected: "data: é\n\n"),
        Case(name: "a comment keeps a connection alive", send: { try await $0.sendComment("ping") }, expected: ": ping\n\n"),
        Case(name: "an empty comment", send: { try await $0.sendComment("") }, expected: ":\n\n"),
        Case(name: "two events in order", send: { try await $0.send(data: "1"); try await $0.send(data: "2") }, expected: "data: 1\n\ndata: 2\n\n"),
    ]

    @Test("An event is written as the specification has it, one field to a line and a blank line to end it", arguments: formats)
    func formatting(_ c: Case) async throws {
        #expect(try await Self.written(c.send) == c.expected)
    }

    struct Bad: Sendable, CustomTestStringConvertible {
        let name: String
        let send: @Sendable (EventWriter) async throws -> Void
        var testDescription: String { name }
    }

    static let refused: [Bad] = [
        Bad(name: "an event name with a line feed", send: { try await $0.send(data: "x", event: "a\nb") }),
        Bad(name: "an event name with a carriage return", send: { try await $0.send(data: "x", event: "a\rb") }),
        Bad(name: "an empty event name", send: { try await $0.send(data: "x", event: "") }),
        Bad(name: "an id with a line feed", send: { try await $0.send(data: "x", id: "a\nb") }),
        Bad(name: "an id with a carriage return", send: { try await $0.send(data: "x", id: "a\rb") }),
        Bad(name: "an id with a NUL, which makes the client ignore it", send: { try await $0.send(data: "x", id: "a\u{0}b") }),
        Bad(name: "a negative retry", send: { try await $0.send(data: "x", retry: -1) }),
        Bad(name: "a comment with a line feed", send: { try await $0.sendComment("a\nb") }),
        Bad(name: "a comment with a carriage return", send: { try await $0.sendComment("a\rb") }),
    ]

    @Test("A field that would let its value start another field or another event is refused, and nothing is written", arguments: refused)
    func refuses(_ c: Bad) async throws {
        let sink = Sink()
        let stream = try #require(Response.eventStream(produce: c.send).stream)
        await #expect(throws: EventStreamError.self) {
            try await stream.produce(ResponseWriter { data in await sink.add(data) })
        }
        #expect(await sink.text.isEmpty)
    }

    @Test("An id may be empty, which tells the client to forget the last event id")
    func emptyID() async throws {
        #expect(try await Self.written { try await $0.send(data: "x", id: "") } == "id: \ndata: x\n\n")
    }

    @Test("An event stream response has the event-stream type, is not cached, and is a stream")
    func headers() throws {
        let response = Response.eventStream { _ in }
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/event-stream")
        #expect(response.headers[.cacheControl] == "no-store")
        _ = try #require(response.stream)
    }

    @Test("Extra headers are kept, and cannot replace the type or the caching")
    func extraHeaders() throws {
        var extra = HTTPFields()
        extra[.contentType] = "text/html"
        extra[.cacheControl] = "public"
        if let name = HTTPField.Name("X-Thing") { extra[name] = "1" }
        let response = Response.eventStream(headers: extra) { _ in }
        #expect(response.headers[.contentType] == "text/event-stream")
        #expect(response.headers[.cacheControl] == "no-store")
        #expect(response.headers[try #require(HTTPField.Name("X-Thing"))] == "1")
    }

    @Test("A producer's error and a failed write both pass out of the event writer")
    func errorsPass() async throws {
        struct Gone: Error, Equatable {}
        let stream = try #require(Response.eventStream { writer in try await writer.send(data: "x") }.stream)
        await #expect(throws: Gone.self) { try await stream.produce(ResponseWriter { _ in throw Gone() }) }
    }
}
