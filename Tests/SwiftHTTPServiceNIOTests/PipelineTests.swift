import Foundation
import HTTPTypes
import NIOCore
import NIOEmbedded
import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// The server's pipeline, driven by the exact bytes a peer would send. Every expectation about a status,
/// a header or a body is worked out by hand from RFC 9110 and RFC 9112.
@Suite("Pipeline: serving")
struct ServingTests {

    /// The fixed body of a transport-originated refusal, built by the core's own encoder.
    static func problemBody(_ status: HTTPResponse.Status, _ code: String) throws -> String {
        String(decoding: try Response.problem(Problem(status: status, code: code)).body, as: UTF8.self)
    }

    @Test("A GET reaches the handler as a parsed request and gets its response, with the transport's headers")
    func basicGet() async throws {
        let recorder = Recorder()
        let harness = try await PipelineHarness { request in
            await recorder.record(request)
            return Response(status: .ok, headers: [.contentType: "text/plain"], body: Data("hello".utf8))
        }
        try await harness.send("GET /v1/me?x=1 HTTP/1.1\r\nHost: example.org\r\nAuthorization: Bearer abc\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.statusLine == "HTTP/1.1 200 OK")
        #expect(response.text == "hello")
        #expect(response.header("Content-Length") == "5")
        #expect(response.header("Content-Type") == "text/plain")
        #expect(response.header("Connection") == "keep-alive")
        let date = try #require(response.header("Date"))
        #expect(date.hasSuffix(" GMT"))
        #expect(date.count == 29)   // "Tue, 27 Oct 2026 12:00:00 GMT" is 29 characters
        let request = try #require(await recorder.requests.first)
        #expect(request.method == .get)
        #expect(request.pathSegments == ["v1", "me"])
        #expect(request.query == [QueryItem(name: "x", value: "1")])
        #expect(request.headers[.authorization] == "Bearer abc")
        #expect(request.remoteAddress == "192.0.2.7")
        #expect(request.body.isEmpty)
        #expect(harness.channel.isActive)
        await harness.finish()
    }

    @Test("Two requests on one connection are answered in order")
    func keepAlive() async throws {
        let harness = try await PipelineHarness { request in
            Response(status: .ok, body: Data(request.pathSegments.joined(separator: "/").utf8))
        }
        try await harness.send("GET /one HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await harness.readResponse()?.text == "one")
        try await harness.send("GET /two HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await harness.readResponse()?.text == "two")
        #expect(harness.channel.isActive)
        await harness.finish()
    }

    @Test("A HEAD response has the headers a GET would, including Content-Length, and no body")
    func head() async throws {
        let harness = try await PipelineHarness(handler: ok("twelve bytes"))
        try await harness.send("HEAD /x HTTP/1.1\r\nHost: h\r\n\r\n")
        try await Task.sleep(for: .milliseconds(100))
        let raw = String(decoding: try await harness.drainOutbound(), as: UTF8.self)
        #expect(raw.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(raw.contains("Content-Length: 12\r\n") || raw.contains("content-length: 12\r\n"))
        #expect(raw.hasSuffix("\r\n\r\n"))   // the head ends the message: no body bytes follow
        #expect(!raw.contains("twelve"))
        await harness.finish()
    }

    @Test("A 204 and a 304 carry no Content-Length and no body", arguments: [HTTPResponse.Status.noContent, .notModified])
    func bodiless(_ status: HTTPResponse.Status) async throws {
        let harness = try await PipelineHarness { _ in Response(status: status) }
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        try await Task.sleep(for: .milliseconds(100))
        let raw = String(decoding: try await harness.drainOutbound(), as: UTF8.self).lowercased()
        #expect(raw.hasPrefix("http/1.1 \(status.code)"))
        #expect(!raw.contains("content-length"))
        #expect(raw.hasSuffix("\r\n\r\n"))
        await harness.finish()
    }

    @Test("The transport owns Content-Length, Connection, Date and Transfer-Encoding: a handler cannot set them")
    func transportOwnsFraming() async throws {
        let harness = try await PipelineHarness { _ in
            var fields = HTTPFields()
            fields[.contentLength] = "999"
            fields[.connection] = "upgrade"
            fields[.date] = "yesterday"
            fields[.transferEncoding] = "chunked"
            fields[try #require(HTTPField.Name("X-Mine"))] = "kept"
            return Response(status: .ok, headers: fields, body: Data("abc".utf8))
        }
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.values("Content-Length") == ["3"])
        #expect(response.values("Connection") == ["keep-alive"])
        #expect(response.values("Date").count == 1)
        #expect(response.header("Date") != "yesterday")
        #expect(response.header("Transfer-Encoding") == nil)
        #expect(response.header("X-Mine") == "kept")
        #expect(response.text == "abc")
        await harness.finish()
    }

    @Test("Connection: close from the peer is honoured: the response says close, then the connection closes")
    func connectionClose() async throws {
        let harness = try await PipelineHarness(handler: ok())
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.header("Connection") == "close")
        #expect(try await harness.isClosed())
    }

    @Test("HTTP/1.0 closes after the response unless the peer asked for keep-alive")
    func http10() async throws {
        let harness = try await PipelineHarness(handler: ok())
        try await harness.send("GET /x HTTP/1.0\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.header("Connection") == "close")
        #expect(try await harness.isClosed())
    }

    @Test("An error thrown by the handler becomes a fixed 500 that never contains the error's text")
    func handlerError() async throws {
        struct Secret: Error, CustomStringConvertible { var description: String { "/Users/someone/very-secret-path" } }
        let harness = try await PipelineHarness { _ in throw Secret() }
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.status == 500)
        #expect(response.header("Content-Type") == "application/problem+json")
        #expect(response.text == (try Self.problemBody(.internalServerError, "internal_error")))
        #expect(!response.text.contains("secret"))
        #expect(try await harness.isClosed())
    }

    @Test("Pipelined requests: the first is answered with Connection: close, the second is never run")
    func pipelining() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let harness = try await PipelineHarness { request in
            await recorder.record(request)
            await gate.wait()
            return Response(status: .ok, body: Data("first".utf8))
        }
        try await harness.send("GET /one HTTP/1.1\r\nHost: h\r\n\r\nGET /two HTTP/1.1\r\nHost: h\r\n\r\n")
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        let response = try #require(try await harness.readResponse())
        #expect(response.text == "first")
        #expect(response.header("Connection") == "close")
        #expect(try await harness.isClosed())
        #expect(await recorder.requests.count == 1)
    }

    @Test("Bodies are delivered: Content-Length, and chunked")
    func bodies() async throws {
        let recorder = Recorder()
        let harness = try await PipelineHarness { request in
            await recorder.record(request)
            return Response(status: .ok)
        }
        try await harness.send("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")
        _ = try await harness.readResponse()
        try await harness.send("POST /b HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n")
        _ = try await harness.readResponse()
        let requests = await recorder.requests
        #expect(requests.map { String(decoding: $0.body, as: UTF8.self) } == ["hello", "abcdefg"])
        await harness.finish()
    }

    @Test("A body split across many reads arrives whole")
    func splitBody() async throws {
        let recorder = Recorder()
        let harness = try await PipelineHarness { request in
            await recorder.record(request)
            return Response(status: .ok)
        }
        for piece in ["POST /a HTTP/1.1\r\nHo", "st: h\r\nContent-Le", "ngth: 6\r\n\r\nab", "cd", "ef"] {
            try await harness.send(piece)
        }
        _ = try await harness.readResponse()
        #expect(await recorder.requests.map { String(decoding: $0.body, as: UTF8.self) } == ["abcdef"])
        await harness.finish()
    }

    @Test("Expect: 100-continue within the limit is answered with 100, then the response")
    func expectContinue() async throws {
        let harness = try await PipelineHarness(limits: Limits(maximumBodyBytes: 10), handler: ok())
        try await harness.send("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n")
        try await Task.sleep(for: .milliseconds(100))
        let interim = String(decoding: try await harness.drainOutbound(), as: UTF8.self)
        #expect(interim.hasPrefix("HTTP/1.1 100 Continue\r\n"))
        try await harness.send("data")
        #expect(try await harness.readResponse()?.status == 200)
        await harness.finish()
    }

    @Test("Expect: 100-continue over the limit is refused with 413 and never invited")
    func expectContinueRefused() async throws {
        let harness = try await PipelineHarness(limits: Limits(maximumBodyBytes: 10), handler: ok())
        try await harness.send("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\nExpect: 100-continue\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.status == 413)
        #expect(!(response.statusLine.contains("100")))
        #expect(try await harness.isClosed())
    }

    @Test("An expectation other than 100-continue is refused with 417")
    func expectOther() async throws {
        let harness = try await PipelineHarness(handler: ok())
        try await harness.send("GET /a HTTP/1.1\r\nHost: h\r\nExpect: something-else\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.status == 417)
        #expect(try await harness.isClosed())
    }
}

@Suite("Pipeline: refusals")
struct RefusalTests {

    static func expectedBody(_ status: HTTPResponse.Status, _ code: String) throws -> String {
        try ServingTests.problemBody(status, code)
    }

    private func refused(_ raw: String, limits: Limits = Limits()) async throws -> (WireResponse?, closed: Bool, handlerRan: Bool) {
        let recorder = Recorder()
        let harness = try await PipelineHarness(limits: limits) { request in
            await recorder.record(request)
            return Response(status: .ok)
        }
        try await harness.send(raw)
        let response = try await harness.readResponse(timeout: .seconds(2))
        let closed = try await harness.isClosed()
        let ran = await !recorder.requests.isEmpty
        return (response, closed, ran)
    }

    // MARK: Targets

    @Test("A malformed target is a 400 with a fixed body that never repeats the target")
    func malformedTarget() async throws {
        let result = try await refused("GET /a/../secret-name HTTP/1.1\r\nHost: h\r\n\r\n")
        let response = try #require(result.0)
        #expect(response.status == 400)
        #expect(response.header("Content-Type") == "application/problem+json")
        #expect(response.text == (try Self.expectedBody(.badRequest, "malformed_target")))
        #expect(!response.text.contains("secret-name"))
        #expect(result.closed)
        #expect(!result.handlerRan)
    }

    @Test("A target that is not origin-form is refused the same way", arguments: ["*", "example.org:443", "/a%zz", "/a#b"])
    func nonOriginForm(_ target: String) async throws {
        let result = try await refused("GET \(target) HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(result.0?.status == 400)
        #expect(result.0?.text == (try Self.expectedBody(.badRequest, "malformed_target")))
        #expect(!result.handlerRan)
    }

    // MARK: Size limits

    @Test("A request line longer than the header limit is a 431 before it ends, and the handler never runs")
    func longRequestLine() async throws {
        let limits = Limits(maximumHeaderBytes: 1024)
        let result = try await refused("GET /" + String(repeating: "a", count: 2000) + " HTTP/1.1\r\nHost: h\r\n\r\n", limits: limits)
        #expect(result.0?.status == 431)
        #expect(result.0?.text == (try Self.expectedBody(.requestHeaderFieldsTooLarge, "headers_too_large")))
        #expect(result.0?.header("Connection") == "close")
        #expect(result.closed)
        #expect(!result.handlerRan)
    }

    @Test("A request line that never ends is refused once it passes the limit, without waiting for its end")
    func endlessRequestLine() async throws {
        let harness = try await PipelineHarness(limits: Limits(maximumHeaderBytes: 1024), handler: ok())
        try await harness.send("GET /" + String(repeating: "a", count: 1500))
        #expect(try await harness.readResponse()?.status == 431)
        #expect(try await harness.isClosed())
    }

    @Test("Request line and headers together count toward the limit")
    func headersCountToo() async throws {
        let limits = Limits(maximumHeaderBytes: 1024)
        var raw = "GET /x HTTP/1.1\r\nHost: h\r\n"
        for index in 0..<40 { raw += "X-Pad-\(index): \(String(repeating: "v", count: 30))\r\n" }
        raw += "\r\n"
        #expect(raw.utf8.count > 1024)
        let result = try await refused(raw, limits: limits)
        #expect(result.0?.status == 431)
        #expect(!result.handlerRan)
    }

    @Test("A head of exactly the limit is accepted, and one byte more is not")
    func headBoundary() async throws {
        let limit = 1024
        func head(padding: Int) -> String {
            let base = "GET /x HTTP/1.1\r\nHost: h\r\nX-Pad: "
            let tail = "\r\n\r\n"
            return base + String(repeating: "p", count: padding) + tail
        }
        let base = head(padding: 0).utf8.count
        let exact = head(padding: limit - base)
        #expect(exact.utf8.count == limit)
        let accepted = try await refused(exact, limits: Limits(maximumHeaderBytes: limit))
        #expect(accepted.0?.status == 200)
        let over = head(padding: limit - base + 1)
        #expect(over.utf8.count == limit + 1)
        let rejected = try await refused(over, limits: Limits(maximumHeaderBytes: limit))
        #expect(rejected.0?.status == 431)
    }

    @Test("More header fields than the limit is a 431; exactly the limit is accepted")
    func headerCount() async throws {
        // `fields` counts every header field, Host included.
        func request(fields: Int) -> String {
            var raw = "GET /x HTTP/1.1\r\nHost: h\r\n"
            for index in 0..<(fields - 1) { raw += "X-\(index): v\r\n" }
            return raw + "\r\n"
        }
        let limits = Limits(maximumHeaderCount: 5)
        #expect(try await refused(request(fields: 5), limits: limits).0?.status == 200)
        let over = try await refused(request(fields: 6), limits: limits)
        #expect(over.0?.status == 431)
        #expect(!over.handlerRan)
    }

    @Test("A Content-Length over the body limit is a 413 at once, before any body is read")
    func contentLengthTooLarge() async throws {
        let result = try await refused("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\n", limits: Limits(maximumBodyBytes: 10))
        #expect(result.0?.status == 413)
        #expect(result.0?.text == (try Self.expectedBody(.contentTooLarge, "body_too_large")))
        #expect(result.0?.header("Connection") == "close")
        #expect(result.closed)
        #expect(!result.handlerRan)
    }

    @Test("A body of exactly the limit is accepted")
    func bodyBoundary() async throws {
        let result = try await refused("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\n0123456789", limits: Limits(maximumBodyBytes: 10))
        #expect(result.0?.status == 200)
        #expect(result.handlerRan)
    }

    @Test("A chunked body that passes the limit is a 413 as soon as it does")
    func chunkedTooLarge() async throws {
        let limits = Limits(maximumBodyBytes: 10)
        let result = try await refused("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nabcdef\r\n6\r\nghijkl\r\n0\r\n\r\n", limits: limits)
        #expect(result.0?.status == 413)
        #expect(!result.handlerRan)
        let exact = try await refused("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcde\r\n5\r\nfghij\r\n0\r\n\r\n", limits: limits)
        #expect(exact.0?.status == 200)
    }

    @Test("With no bodies allowed, any Content-Length above zero is a 413 and zero is fine")
    func noBodies() async throws {
        let limits = Limits(maximumBodyBytes: 0)
        #expect(try await refused("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\n\r\nx", limits: limits).0?.status == 413)
        #expect(try await refused("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n", limits: limits).0?.status == 200)
    }

    // MARK: Request smuggling

    static let smuggling: [(name: String, raw: String)] = [
        ("Content-Length and Transfer-Encoding together",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
        ("Transfer-Encoding then Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n0\r\n\r\n"),
        ("duplicate Content-Length, different values",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nabcd"),
        ("duplicate Content-Length, same value",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\nabcd"),
        ("comma-joined Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4, 4\r\n\r\nabcd"),
        ("non-numeric Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: abc\r\n\r\n"),
        ("negative Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n"),
        ("signed Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: +4\r\n\r\nabcd"),
        ("hexadecimal Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 0x4\r\n\r\nabcd"),
        ("empty Content-Length",
         "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: \r\n\r\n"),
        ("Transfer-Encoding that is not exactly chunked",
         "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\n0\r\n\r\n"),
        ("Transfer-Encoding: gzip, chunked",
         "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n"),
        ("Transfer-Encoding: chunked twice",
         "POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n"),
        ("obsolete line folding",
         "GET /a HTTP/1.1\r\nHost: h\r\nX-Folded: one\r\n two\r\n\r\n"),
        ("a bare CR in a header value",
         "GET /a HTTP/1.1\r\nHost: h\r\nX-Bad: a\rb\r\n\r\n"),
        ("a bare LF ending a header line",
         "GET /a HTTP/1.1\r\nHost: h\r\nX-Bad: ab\n\r\n"),
        ("a NUL in a header value",
         "GET /a HTTP/1.1\r\nHost: h\r\nX-Bad: a\u{0}b\r\n\r\n"),
        ("whitespace before the colon in a header name",
         "GET /a HTTP/1.1\r\nHost: h\r\nX-Bad : v\r\n\r\n"),
        ("a header name with a space inside",
         "GET /a HTTP/1.1\r\nHost: h\r\nX Bad: v\r\n\r\n"),
        ("a request line with a bare LF",
         "GET /a HTTP/1.1\nHost: h\r\n\r\n"),
        ("a missing Host on HTTP/1.1",
         "GET /a HTTP/1.1\r\n\r\n"),
        ("a duplicate Host",
         "GET /a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
        ("an unknown protocol version",
         "GET /a HTTP/9.9\r\nHost: h\r\n\r\n"),
        ("a missing protocol version",
         "GET /a\r\nHost: h\r\n\r\n"),
        ("a lowercase method",
         "get /a HTTP/1.1\r\nHost: h\r\n\r\n"),
    ]

    @Test("Anything that could be read two ways is a 400 with Connection: close, and the handler never runs",
          arguments: smuggling.map(\.name))
    func smugglingRefused(_ name: String) async throws {
        let raw = try #require(Self.smuggling.first { $0.name == name }?.raw)
        let result = try await refused(raw)
        let response = try #require(result.0, "no response for: \(name)")
        #expect(response.status == 400, "\(name)")
        #expect(response.header("Connection") == "close")
        #expect(response.header("Content-Type") == "application/problem+json")
        #expect(result.closed)
        #expect(!result.handlerRan, "\(name)")
    }

    @Test("A refusal body never repeats anything the peer sent", arguments: smuggling.map(\.name))
    func refusalBodyIsFixed(_ name: String) async throws {
        let raw = try #require(Self.smuggling.first { $0.name == name }?.raw)
        let result = try await refused(raw)
        let body = try #require(result.0?.text)
        let known = [try Self.expectedBody(.badRequest, "bad_request"), try Self.expectedBody(.badRequest, "malformed_target")]
        #expect(known.contains(body), "\(name)")
    }

    @Test("A handler that returns a status that is not a final one is a 500, not a malformed response")
    func nonFinalStatus() async throws {
        let harness = try await PipelineHarness { _ in Response(status: .continue) }
        try await harness.send("GET /a HTTP/1.1\r\nHost: h\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.status == 500)
        #expect(try await harness.isClosed())
    }

    @Test("HTTP/1.0 needs no Host")
    func http10NoHost() async throws {
        #expect(try await refused("GET /a HTTP/1.0\r\n\r\n").0?.status == 200)
    }

    @Test("A single, clean Content-Length and a clean Transfer-Encoding: chunked are accepted")
    func cleanFramingAccepted() async throws {
        #expect(try await refused("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\nabcd").0?.status == 200)
        #expect(try await refused("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: Chunked\r\n\r\n0\r\n\r\n").0?.status == 200)
        #expect(try await refused("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length:   4  \r\n\r\nabcd").0?.status == 200)
    }
}

@Suite("Pipeline: time")
struct TimeoutTests {

    @Test("A header that does not finish in time is a 408 and a close; the clock starts at the first byte")
    func headerTimeout() async throws {
        let harness = try await PipelineHarness(limits: Limits(headerReadTimeout: .seconds(10), idleTimeout: .seconds(60)), handler: ok())
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\n")
        await harness.advance(.seconds(9))
        #expect(harness.channel.isActive)
        await harness.advance(.seconds(2))
        let response = try #require(try await harness.readResponse())
        #expect(response.status == 408)
        #expect(response.header("Connection") == "close")
        #expect(try await harness.isClosed())
    }

    @Test("A slow drip of bytes does not extend the header deadline")
    func slowloris() async throws {
        let harness = try await PipelineHarness(limits: Limits(headerReadTimeout: .seconds(10)), handler: ok())
        try await harness.send("GET /x HTTP/1.1\r\n")
        for _ in 0..<12 {
            await harness.advance(.seconds(1))
            if !harness.channel.isActive { break }
            try await harness.send("X: y\r\n".prefix(1).description)
        }
        #expect(try await harness.isClosed())
    }

    @Test("A body that does not arrive in time is a 408 and a close")
    func bodyTimeout() async throws {
        let harness = try await PipelineHarness(limits: Limits(bodyReadTimeout: .seconds(30)), handler: ok())
        try await harness.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\nab")
        await harness.advance(.seconds(29))
        #expect(harness.channel.isActive)
        await harness.advance(.seconds(2))
        #expect(try await harness.readResponse()?.status == 408)
        #expect(try await harness.isClosed())
    }

    @Test("A connection that sends nothing is closed at the idle timeout, silently")
    func idleBeforeFirstRequest() async throws {
        let harness = try await PipelineHarness(limits: Limits(idleTimeout: .seconds(60)), handler: ok())
        await harness.advance(.seconds(59))
        #expect(harness.channel.isActive)
        await harness.advance(.seconds(2))
        #expect(try await harness.isClosed())
        #expect(try await harness.drainOutbound().isEmpty)
    }

    @Test("A keep-alive connection is closed at the idle timeout after its last response")
    func idleBetweenRequests() async throws {
        let harness = try await PipelineHarness(limits: Limits(idleTimeout: .seconds(60)), handler: ok())
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        _ = try await harness.readResponse()
        await harness.advance(.seconds(59))
        #expect(harness.channel.isActive)
        await harness.advance(.seconds(2))
        #expect(try await harness.isClosed())
    }

    @Test("The idle timer does not fire while a request is in flight")
    func idleDoesNotFireDuringARequest() async throws {
        let gate = Gate()
        let harness = try await PipelineHarness(limits: Limits(idleTimeout: .seconds(5)), handler: { _ in
            await gate.wait()
            return Response(status: .ok)
        })
        try await harness.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        try await Task.sleep(for: .milliseconds(50))
        await harness.advance(.seconds(30))
        #expect(harness.channel.isActive)
        await gate.open()
        #expect(try await harness.readResponse()?.status == 200)
        await harness.finish()
    }

    @Test("Bytes arriving cancel the idle timer for the request that follows")
    func idleResetsOnTraffic() async throws {
        let harness = try await PipelineHarness(limits: Limits(headerReadTimeout: .seconds(30), idleTimeout: .seconds(5)), handler: ok())
        await harness.advance(.seconds(4))
        try await harness.send("GET /x HTTP/1.1\r\n")
        await harness.advance(.seconds(4))
        #expect(harness.channel.isActive)
        await harness.finish()
    }
}
