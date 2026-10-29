import Foundation
import HTTPTypes
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Streaming through the layers a server stacks around its handlers: the request id, the access log, the router.
@Suite("Streaming with middleware", .serialized)
struct StreamingLayersTests {

    private func waitForEntries(_ entries: NIOLockedValueBox<[AccessLogEntry]>, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while entries.withLockedValue({ $0.count }) < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func layered(_ entries: NIOLockedValueBox<[AccessLogEntry]>) -> Handler {
        var router = Router()
        do {
            try router.get("/events") { _ in
                .eventStream { events in
                    try await events.send(data: "one", event: "tick", id: "1")
                    try await events.send(data: "two", id: "2")
                }
            }
            try router.get("/informational") { _ in .streaming(status: HTTPResponse.Status(code: 100)) { _ in } }
            try router.get("/nocontent") { _ in .streaming(status: .noContent) { _ in } }
            try router.get("/blob") { _ in
                .streaming(status: .ok) { writer in
                    try await writer.write(Data("12345".utf8))
                    try await writer.write(Data("abcdefg".utf8))
                }
            }
        } catch {
            Issue.record("could not register a route: \(error)")
        }
        return wrap(router.handler, with: [
            accessLog(sink: { entry in entries.withLockedValue { $0.append(entry) } }),
            requestID(),
        ])
    }

    @Test("Over HTTP/1.1 an event stream arrives as events, each in its own chunk, with the request id on the head, and the log has the bytes")
    func http1() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: layered(entries))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /events?token=secret HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        #expect(try await client.waitUntilClosed())
        let split = try #require(client.splitResponse)
        let body = ChunkedBody(split.body)
        #expect(body.complete)
        #expect(body.chunks.map { String(decoding: $0, as: UTF8.self) } == ["event: tick\nid: 1\ndata: one\n\n", "id: 2\ndata: two\n\n"])
        let head = split.head.lowercased()
        #expect(head.contains("content-type: text/event-stream"))
        #expect(head.contains("cache-control: no-store"))
        #expect(head.contains("x-request-id: "))
        try await waitForEntries(entries, count: 1)
        let logged = entries.withLockedValue { $0 }
        #expect(logged.count == 1)
        #expect(logged.first?.responseBytes == "event: tick\nid: 1\ndata: one\n\n".utf8.count + "id: 2\ndata: two\n\n".utf8.count)
        #expect(logged.first?.path == "/events")
        #expect(logged.first?.line.contains("secret") == false)
        #expect(logged.first?.requestID?.isEmpty == false)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A HEAD of a streamed route is logged once, with no bytes")
    func http1Head() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: layered(entries))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("HEAD /blob HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.waitUntilClosed())
        try await waitForEntries(entries, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        let logged = entries.withLockedValue { $0 }
        #expect(logged.count == 1)
        #expect(logged.first?.responseBytes == 0)
        #expect(logged.first?.status == 200)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A streaming response with a status that cannot be sent is the transport's 500, and its stream is still accounted for once")
    func unsendableStatusIsLogged() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: layered(entries))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /informational HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.response()?.status == 500)
        try await waitForEntries(entries, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(entries.withLockedValue { $0.count } == 1)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A bodyless status on a streaming route is an ordinary 204, logged once with no bytes")
    func bodylessStatusIsLogged() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: layered(entries))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /nocontent HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.wait { $0.splitResponse?.head.hasPrefix("HTTP/1.1 204") == true })
        try await waitForEntries(entries, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        let logged = entries.withLockedValue { $0 }
        #expect(logged.count == 1)
        #expect(logged.first?.status == 204)
        #expect(logged.first?.responseBytes == 0)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A client that goes before the response is sent leaves a log entry too, and the producer never runs")
    func goneBeforeTheResponse() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let gate = HoldGate()
        let ran = NIOLockedValueBox(false)
        let handler: Handler = wrap({ _ in
            await gate.wait()
            return .streaming(status: .ok) { _ in ran.withLockedValue { $0 = true } }
        }, with: [accessLog(sink: { entry in entries.withLockedValue { $0.append(entry) } })])
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: handler)
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        try await Task.sleep(for: .milliseconds(100))
        await client.close()                                  // the client leaves while the handler is still deciding
        try await Task.sleep(for: .milliseconds(200))
        await gate.release()
        try await waitForEntries(entries, count: 1)
        #expect(entries.withLockedValue { $0.count } == 1)
        #expect(ran.withLockedValue { $0 } == false)
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("Over HTTP/2 a client that resets before the response is sent leaves a log entry, and the producer never runs")
    func http2GoneBeforeTheResponse() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let gate = HoldGate()
        let ran = NIOLockedValueBox(false)
        let handler: Handler = wrap({ _ in
            await gate.wait()
            return .streaming(status: .ok) { _ in ran.withLockedValue { $0 = true } }
        }, with: [accessLog(sink: { entry in entries.withLockedValue { $0.append(entry) } })])
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files), handler: handler)
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        let stream = try await client.open("GET", "/x")
        try await Task.sleep(for: .milliseconds(150))                 // the request is in the handler
        await stream.reset()
        try await Task.sleep(for: .milliseconds(150))
        await gate.release()
        try await waitForEntries(entries, count: 1)
        #expect(entries.withLockedValue { $0.count } == 1)
        #expect(ran.withLockedValue { $0 } == false)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("Over HTTP/2 the same stream is logged with its bytes, and a HEAD once with none")
    func http2() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files), handler: layered(entries))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        let get = try await client.request("GET", "/blob")
        #expect(get.text == "12345abcdefg")
        #expect(get.header("x-request-id")?.isEmpty == false)
        let head = try await client.request("HEAD", "/blob")
        #expect(head.body.isEmpty)
        let informational = try await client.request("GET", "/informational")
        #expect(informational.status == 500)                         // a status that cannot be sent is the transport's 500
        try await waitForEntries(entries, count: 3)
        try await Task.sleep(for: .milliseconds(100))
        let logged = entries.withLockedValue { $0 }
        #expect(logged.count == 3)
        #expect(logged.map(\.responseBytes).sorted() == [0, 0, 12])
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }
}
