import Foundation
import HTTPTypes
import NIOCore
import NIOEmbedded
import NIOPosix
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// One response as the wire carried it, parsed by hand so the tests assert on bytes and not on a decoder.
struct WireResponse: Sendable {
    let statusLine: String
    let headers: [(name: String, value: String)]
    let body: Data

    var status: Int {
        let parts = statusLine.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? -1 : -1
    }

    func values(_ name: String) -> [String] {
        headers.filter { $0.name.lowercased() == name.lowercased() }.map(\.value)
    }

    func header(_ name: String) -> String? { values(name).first }
    var text: String { String(decoding: body, as: UTF8.self) }
}

/// A server pipeline on a testing channel, driven by exact request bytes.
///
/// Handlers run as Swift tasks, so the channel is a `NIOAsyncTestingChannel`, whose loop is safe to call
/// from any thread, and time is advanced by hand.
final class PipelineHarness: Sendable {
    let channel: NIOAsyncTestingChannel
    let context: ServerContext

    /// Builds the production pipeline on a fresh testing channel and connects it to a fake peer.
    init(limits: Limits = Limits(), handler: @escaping Handler) async throws {
        let configuration = try ServiceConfiguration(port: 0, limits: limits)
        context = ServerContext(configuration: configuration, handler: handler)
        channel = NIOAsyncTestingChannel()
        try await PipelineBuilder.install(on: channel, context: context, tls: nil)
        try await channel.connect(to: SocketAddress(ipAddress: "192.0.2.7", port: 4242))
    }

    /// Sends text as the peer, with the lines ending as the caller wrote them.
    func send(_ text: String) async throws {
        try await channel.writeInbound(ByteBuffer(string: text))
    }

    func send(bytes: [UInt8]) async throws {
        try await channel.writeInbound(ByteBuffer(bytes: bytes))
    }

    /// Everything the server has written so far, as bytes.
    func drainOutbound() async throws -> Data {
        var data = Data()
        while let buffer = try await channel.readOutbound(as: ByteBuffer.self) {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    /// Waits for one complete response (head and a `Content-Length` body), or nil if the connection
    /// closes first with nothing written. Gives up after `timeout`.
    func readResponse(timeout: Duration = .seconds(5)) async throws -> WireResponse? {
        var pending = Data()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            pending.append(try await drainOutbound())
            if let response = Self.parse(&pending) { return response }
            if !channel.isActive, pending.isEmpty { return nil }
            try await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    /// Parses and removes one response from the front of `data`, if it is complete.
    static func parse(_ data: inout Data) -> WireResponse? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: terminator) else { return nil }
        let headText = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let headers: [(name: String, value: String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (String(line[..<colon]), value)
        }
        let length = headers.first { $0.name.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
        data = Data(data[data.index(bodyStart, offsetBy: length)...])
        return WireResponse(statusLine: statusLine, headers: headers, body: body)
    }

    /// Moves the testing loop's clock forward, firing any timer that falls due.
    func advance(_ amount: TimeAmount) async {
        await channel.testingEventLoop.advanceTime(by: amount)
    }

    /// Whether the server has closed the connection, after letting pending work run.
    func isClosed(timeout: Duration = .seconds(2)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !channel.isActive { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return !channel.isActive
    }

    func finish() async {
        _ = try? await channel.finish(acceptAlreadyClosed: true)
    }
}

/// A handler that records what it was given and answers with a fixed response.
actor Recorder {
    private(set) var requests: [Request] = []
    func record(_ request: Request) { requests.append(request) }
}

/// A gate a handler can wait on, so a request stays in flight until the test says otherwise.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

func ok(_ body: String = "ok") -> Handler {
    { _ in Response(status: .ok, body: Data(body.utf8)) }
}
