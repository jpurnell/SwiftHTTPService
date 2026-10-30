import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// Floods and caps under load: each abuse is applied, and the test then proves two things the single-shot attack tests
/// do not: the defence is the documented one (GOAWAY with ENHANCE_YOUR_CALM, RFC 9113 section 10.5 and the design's
/// section 3.5; or the stream refused with the flow-control or size error), and the server goes on answering a
/// well-behaved client afterwards, on a fresh connection, while several abusers are still attacking.
@Suite("Floods and the connection cap", .serialized)
struct FloodTests {

    static let protocolError: UInt32 = 1
    static let flowControlError: UInt32 = 3
    static let enhanceYourCalm: UInt32 = 11

    private func withServer<T>(
        limits: Limits = Limits(), handler: @escaping Handler = ok("fine"),
        _ body: (Running, TestTLS, MultiThreadedEventLoopGroup) async throws -> T
    ) async throws -> T {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(limits: limits, tls: material.files, handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let result: T
        do { result = try await body(running, material, group) } catch {
            try? await group.shutdownGracefully()
            await running.server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return result
    }

    private func connect(_ running: Running, _ material: TestTLS, _ group: MultiThreadedEventLoopGroup, settings: [(UInt16, UInt32)] = []) async throws -> RawH2 {
        let connection = try await RawH2.connect(
            to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), settings: settings)
        #expect(try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.settings.rawValue && !$0.isSettingsAck } })
        try await connection.send(H2Wire.settingsAck)
        return connection
    }

    /// A well-behaved client on a fresh connection is answered `200 fine`.
    private func expectServing(_ running: Running, _ material: TestTLS, _ group: MultiThreadedEventLoopGroup, _ note: String) async throws {
        let client = try await H2Client.connect(to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        let response = try await client.request("GET", "/after")
        #expect(response.status == 200 && response.text == "fine", "\(note): a well-behaved client got \(String(describing: response.status))")
        await client.close()
    }

    private func goAwayCode(_ refusal: RawRefusal) -> UInt32? {
        if case .goAway(let code) = refusal { return code }
        return nil
    }

    // MARK: Each flood, with recovery

    struct Flood: Sendable, CustomTestStringConvertible {
        let name: String
        let frames: @Sendable () -> [UInt8]
        /// The codes the documentation allows: `ENHANCE_YOUR_CALM` for volume; a header block that never ends may also
        /// be a `PROTOCOL_ERROR`.
        let codes: [UInt32]
        var testDescription: String { name }
    }

    static let floods: [Flood] = [
        Flood(name: "rapid reset (CVE-2023-44487): 2,000 streams opened and cancelled", frames: {
            var burst: [UInt8] = []
            for index in 0..<2000 {
                let stream = UInt32(index * 2 + 1)
                burst += H2Wire.headers(stream: stream, endStream: false) + H2Wire.rstStream(stream, code: 8)
            }
            return burst
        }, codes: [enhanceYourCalm]),
        Flood(name: "CONTINUATION flood: 5,000 small frames", frames: {
            var burst = H2Wire.headers(stream: 1, block: [0x82], endStream: true, endHeaders: false)
            for _ in 0..<5000 { burst += H2Wire.continuation(stream: 1, block: [0x82]) }
            return burst
        }, codes: [enhanceYourCalm, protocolError]),
        Flood(name: "CONTINUATION flood: 64 frames of 16 KiB", frames: {
            var burst = H2Wire.headers(stream: 1, block: [0x82], endStream: true, endHeaders: false)
            for _ in 0..<64 { burst += H2Wire.continuation(stream: 1, block: [UInt8](repeating: 0, count: 16_384)) }
            return burst
        }, codes: [enhanceYourCalm, protocolError]),
        Flood(name: "PING flood: 5,000 pings", frames: {
            var burst: [UInt8] = []
            for index in 0..<5000 { burst += H2Wire.ping(UInt8(index & 0xFF)) }
            return burst
        }, codes: [enhanceYourCalm]),
        Flood(name: "SETTINGS flood: 5,000 empty SETTINGS frames", frames: {
            var burst: [UInt8] = []
            for _ in 0..<5000 { burst += H2Wire.settings() }
            return burst
        }, codes: [enhanceYourCalm]),
        Flood(name: "empty-DATA flood: 2,000 empty DATA frames on an open stream", frames: {
            var burst = H2Wire.headers(stream: 1, block: [0x83, 0x87, 0x84], endStream: false)
            for _ in 0..<2000 { burst += H2Wire.data(stream: 1) }
            return burst
        }, codes: [enhanceYourCalm]),
    ]

    @Test("Each flood is answered with GOAWAY and the documented code, no handler runs for it, and a well-behaved client is served afterwards", arguments: floods)
    func floodThenServe(_ flood: Flood) async throws {
        let ran = NIOLockedValueBox(0)
        try await withServer(handler: { request in
            if request.path == "/after" { return Response(status: .ok, body: Data("fine".utf8)) }
            ran.withLockedValue { $0 += 1 }
            return Response(status: .ok)
        }) { running, material, group in
            let abuser = try await connect(running, material, group)
            try? await abuser.send(flood.frames())
            let refusal = try await abuser.waitForRefusal(timeout: .seconds(5))
            let code = goAwayCode(refusal)
            recordMeasurement("flood \(flood.name)", "\(refusal)")
            #expect(code.map(flood.codes.contains) == true, "\(flood.name): expected GOAWAY with one of \(flood.codes), saw \(refusal)")
            #expect(ran.withLockedValue { $0 } == 0, "the handler ran for a flood")
            try await expectServing(running, material, group, flood.name)
            await abuser.close()
        }
    }

    @Test("Eight abusers flooding at once (rapid reset, PING and SETTINGS) are all refused, and a well-behaved client is served while they are still connected and after")
    func concurrentAbusers() async throws {
        try await withServer { running, material, group in
            var abusers: [RawH2] = []
            for index in 0..<8 {
                let abuser = try await connect(running, material, group)
                try? await abuser.send(Self.floods[[0, 3, 4][index % 3]].frames())
                abusers.append(abuser)
            }
            // While the abusers are connected (and being refused), a good client is served.
            try await expectServing(running, material, group, "during")
            for abuser in abusers {
                let refusal = try await abuser.waitForRefusal(timeout: .seconds(5))
                #expect(goAwayCode(refusal) == Self.enhanceYourCalm, "an abuser saw \(refusal)")
            }
            try await expectServing(running, material, group, "after")
            for abuser in abusers { await abuser.close() }
        }
    }

    // MARK: Flow control

    @Test("Stream-window exhaustion: DATA beyond the 65,535-octet window, with no credit given, is refused with FLOW_CONTROL_ERROR and the server keeps serving")
    func requestWindowOverrun() async throws {
        let ran = NIOLockedValueBox(0)
        try await withServer(handler: { request in
            if request.path == "/after" { return Response(status: .ok, body: Data("fine".utf8)) }
            ran.withLockedValue { $0 += 1 }
            return Response(status: .ok)
        }) { running, material, group in
            let connection = try await connect(running, material, group)
            // RFC 9113 section 6.9.2: the initial window is 65,535 octets; 6 frames of 16,384 is 98,304 in one burst,
            // before the server can have granted any more.
            let post: [UInt8] = [0x83, 0x87, 0x84, 0x01, 0x09] + Array("localhost".utf8)          // POST / (static entry 3 is :method POST)
            var burst = H2Wire.headers(stream: 1, block: post, endStream: false)
            for _ in 0..<6 { burst += H2Wire.data(stream: 1, [UInt8](repeating: 0x61, count: 16_384)) }
            try? await connection.send(burst)
            let reaction = try await connection.wait(timeout: .seconds(5)) { frames in
                frames.contains { ($0.type == H2Wire.FrameType.goAway.rawValue || $0.type == H2Wire.FrameType.rstStream.rawValue) && $0.errorCode == Self.flowControlError }
            }
            recordMeasurement("window overrun", "\(connection.frames.map { "\($0.type):\($0.errorCode.map(String.init) ?? "-")" })")
            #expect(reaction, "no FLOW_CONTROL_ERROR; frames: \(connection.frames.map { "\($0.type):\($0.errorCode.map(String.init) ?? "-")" })")
            try await expectServing(running, material, group, "window overrun")
            await connection.close()
        }
    }

    @Test("A body over the byte limit, sent within the window, is refused (413 or a reset) before the handler runs, and the connection's other streams are served")
    func bodyOverLimit() async throws {
        var limits = Limits()
        limits.maximumBodyBytes = 1024
        let ran = NIOLockedValueBox(0)
        try await withServer(limits: limits, handler: { request in
            if request.path == "/after" { return Response(status: .ok, body: Data("fine".utf8)) }
            ran.withLockedValue { $0 += 1 }
            return Response(status: .ok)
        }) { running, material, group in
            let client = try await H2Client.connect(to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let over = try await client.request("POST", "/big", body: Data(repeating: 0x62, count: 40_000))
            if let code = over.resetCode {
                #expect(code > 0, "the stream was reset with NO_ERROR")
            } else {
                #expect(over.status == 413, "status \(String(describing: over.status))")
            }
            #expect(ran.withLockedValue { $0 } == 0, "the handler ran for an over-limit body")
            let good = try await client.request("GET", "/after")
            #expect(good.status == 200)
            await client.close()
        }
    }

    @Test("A hundred streaming responses to a client that grants no window are all ended by the write timeout, and the server serves a well-behaved client throughout")
    func exhaustedResponseWindows() async throws {
        var limits = Limits()
        limits.streamWriteTimeout = .milliseconds(400)
        let timedOut = NIOLockedValueBox(0)
        let chunk = Data(repeating: 0x63, count: 4_096)
        try await withServer(limits: limits, handler: { request in
            if request.path == "/after" { return Response(status: .ok, body: Data("fine".utf8)) }
            return .streaming(status: .ok) { writer in
                do { for _ in 0..<64 { try await writer.write(chunk) } }
                catch { timedOut.withLockedValue { $0 += 1 } }
            }
        }) { running, material, group in
            // A window of zero for every stream: nothing the server writes can be sent.
            let connection = try await connect(running, material, group, settings: [(0x4, 0)])
            var requests: [UInt8] = []
            for index in 0..<100 { requests += H2Wire.headers(stream: UInt32(index * 2 + 1), endStream: true) }
            try await connection.send(requests)
            try await expectServing(running, material, group, "during exhaustion")
            let deadline = ContinuousClock.now + .seconds(10)
            while timedOut.withLockedValue({ $0 }) < 100, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(timedOut.withLockedValue { $0 } == 100, "streams ended by the write timeout: \(timedOut.withLockedValue { $0 }) of 100")
            try await expectServing(running, material, group, "after exhaustion")
            await connection.close()
        }
    }

    // MARK: The connection cap

    @Test("With a cap of 20, 35 connections opened one after another leave exactly 20 open; when the abusers leave, a well-behaved client connects and is served")
    func capHoldsSequentially() async throws {
        var limits = Limits()
        limits.maximumConnections = 20
        limits.idleTimeout = .seconds(30)
        let running = try await startServer(limits: limits)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var clients: [RawClient] = []
        for _ in 0..<35 { clients.append(try await RawClient.connect(to: running.address, group: group)) }
        try await Task.sleep(for: .milliseconds(400))
        let closed = clients.filter(\.isClosed).count
        recordMeasurement("cap 20, 35 connections", "\(closed) closed by the server")
        #expect(closed == 15, "the cap is 20 and 35 connected: \(closed) were closed")
        #expect(clients.prefix(20).allSatisfy { !$0.isClosed }, "the first twenty are the ones admitted")
        // The admitted ones are live: they are answered.
        for client in clients.prefix(20) { try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n") }
        for client in clients.prefix(20) { #expect(try await client.response(timeout: .seconds(5))?.status == 200) }
        // The abusers leave; the cap frees; a well-behaved client is admitted and served.
        for client in clients { await client.close() }
        let good = try await RawClient.connect(to: running.address, group: group)
        var served = false
        for _ in 0..<100 {                                                       // the registry forgets a connection when its close is noticed
            try await good.send("GET /x HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
            if try await good.response(timeout: .milliseconds(100))?.status == 200 { served = true; break }
            if good.isClosed { break }
        }
        if !served {
            let again = try await RawClient.connect(to: running.address, group: group)
            try await again.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await again.response(timeout: .seconds(5))?.status == 200, "a well-behaved client after the abusers left")
            await again.close()
        }
        await good.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
    }

    @Test("With a cap of 20, 300 connections opened at once never have more than 20 inside the handler at a time, 20 are reached, and the server serves a well-behaved client afterwards")
    func capHoldsConcurrently() async throws {
        var limits = Limits()
        limits.maximumConnections = 20
        limits.idleTimeout = .seconds(30)
        let current = NIOLockedValueBox(0)
        let highest = NIOLockedValueBox(0)
        let running = try await startServer(limits: limits, handler: { _ in
            let now = current.withLockedValue { value -> Int in value += 1; return value }
            highest.withLockedValue { $0 = max($0, now) }
            try? await Task.sleep(for: .milliseconds(800))                      // hold the slot while the others try
            current.withLockedValue { $0 -= 1 }
            return Response(status: .ok, body: Data("ok".utf8))
        })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        let answered = try await withThrowingTaskGroup(of: Bool.self) { tasks -> Int in
            for _ in 0..<300 {
                tasks.addTask {
                    guard let client = try? await RawClient.connect(to: running.address, group: group) else { return false }
                    try? await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
                    let served = (try? await client.response(timeout: .seconds(3)))??.status == 200
                    await client.close()
                    return served
                }
            }
            var count = 0
            for try await served in tasks where served { count += 1 }
            return count
        }
        let peak = highest.withLockedValue { $0 }
        recordMeasurement("cap 20, 300 concurrent connections", "\(answered) answered, highest concurrency in the handler \(peak)")
        #expect(peak <= 20, "the cap is 20 and \(peak) were inside the handler at once")
        #expect(peak == 20, "the cap should have been reached by 300 contenders (\(peak))")
        #expect(answered >= 20)
        try await Task.sleep(for: .milliseconds(300))
        let good = try await RawClient.connect(to: running.address, group: group)
        try await good.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await good.response(timeout: .seconds(5))?.status == 200, "a well-behaved client after the crowd left")
        await good.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
    }
}
