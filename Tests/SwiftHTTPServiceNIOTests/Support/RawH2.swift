import Foundation
import NIOCore
import NIOPosix
import SwiftTLSKit
@testable import SwiftHTTPServiceNIO

/// HTTP/2 frames as bytes, built by hand from RFC 9113 section 4.1: a 3-octet length, a type, flags, and a
/// 31-bit stream id, then the payload. A conforming client never sends some of what these make, which is
/// the point.
enum H2Wire {
    static let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    enum FrameType: UInt8 { case data = 0, headers = 1, rstStream = 3, settings = 4, ping = 6, goAway = 7, continuation = 9 }

    static let endStream: UInt8 = 0x1
    static let ack: UInt8 = 0x1
    static let endHeaders: UInt8 = 0x4

    static func frame(_ type: FrameType, flags: UInt8 = 0, stream: UInt32 = 0, payload: [UInt8] = []) -> [UInt8] {
        let length = payload.count
        var bytes: [UInt8] = [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), type.rawValue, flags]
        bytes += [UInt8(stream >> 24 & 0x7F), UInt8(stream >> 16 & 0xFF), UInt8(stream >> 8 & 0xFF), UInt8(stream & 0xFF)]
        return bytes + payload
    }

    static func settings(_ pairs: [(UInt16, UInt32)] = []) -> [UInt8] {
        frame(.settings, payload: pairs.flatMap { id, value in
            [UInt8(id >> 8), UInt8(id & 0xFF), UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        })
    }

    static let settingsAck = frame(.settings, flags: ack)

    static func ping(_ byte: UInt8 = 0) -> [UInt8] { frame(.ping, payload: [UInt8](repeating: byte, count: 8)) }

    /// The acknowledgement of a PING: the same eight octets with the ACK flag (RFC 9113 section 6.7).
    static func pingAck(_ payload: [UInt8]) -> [UInt8] { frame(.ping, flags: ack, payload: payload) }

    static func rstStream(_ stream: UInt32, code: UInt32) -> [UInt8] {
        frame(.rstStream, stream: stream, payload: [UInt8(code >> 24), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)])
    }

    /// `GET /` to `localhost`, in HPACK (RFC 7541): `:method GET`, `:scheme https` and `:path /` are entries 2,
    /// 7 and 4 of the static table, each a one-octet indexed field (0x80 + index); `:authority` is a literal
    /// without indexing (0x00 + name index 1) with the value as plain, unencoded octets.
    static let getBlock: [UInt8] = [0x82, 0x87, 0x84, 0x01, 0x09] + Array("localhost".utf8)

    static func headers(stream: UInt32, block: [UInt8] = getBlock, endStream: Bool = false, endHeaders: Bool = true) -> [UInt8] {
        frame(.headers, flags: (endStream ? H2Wire.endStream : 0) | (endHeaders ? H2Wire.endHeaders : 0), stream: stream, payload: block)
    }

    static func continuation(stream: UInt32, block: [UInt8], endHeaders: Bool = false) -> [UInt8] {
        frame(.continuation, flags: endHeaders ? H2Wire.endHeaders : 0, stream: stream, payload: block)
    }

    static func data(stream: UInt32, _ payload: [UInt8] = [], endStream: Bool = false) -> [UInt8] {
        frame(.data, flags: endStream ? H2Wire.endStream : 0, stream: stream, payload: payload)
    }
}

/// A frame the server sent.
struct ReceivedFrame {
    let type: UInt8
    let flags: UInt8
    let stream: UInt32
    let payload: [UInt8]

    var isSettingsAck: Bool { type == H2Wire.FrameType.settings.rawValue && flags & H2Wire.ack != 0 }

    /// The error code of a GOAWAY or RST_STREAM.
    var errorCode: UInt32? {
        let offset: Int
        switch type {
        case H2Wire.FrameType.goAway.rawValue: offset = 4
        case H2Wire.FrameType.rstStream.rawValue: offset = 0
        default: return nil
        }
        guard payload.count >= offset + 4 else { return nil }
        return payload[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A SETTINGS frame's (identifier, value) pairs.
    var settingPairs: [(UInt16, UInt32)] {
        guard type == H2Wire.FrameType.settings.rawValue, flags & H2Wire.ack == 0 else { return [] }
        return stride(from: 0, to: payload.count - 5, by: 6).map { index in
            (UInt16(payload[index]) << 8 | UInt16(payload[index + 1]),
             payload[index + 2..<index + 6].reduce(0) { $0 << 8 | UInt32($1) })
        }
    }
}

func parseFrames(_ data: Data) -> [ReceivedFrame] {
    let bytes = [UInt8](data)
    var frames: [ReceivedFrame] = []
    var index = 0
    while index + 9 <= bytes.count {
        let length = Int(bytes[index]) << 16 | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
        guard index + 9 + length <= bytes.count else { break }
        let stream = bytes[index + 5..<index + 9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF
        frames.append(ReceivedFrame(
            type: bytes[index + 3], flags: bytes[index + 4], stream: stream, payload: Array(bytes[index + 9..<index + 9 + length])))
        index += 9 + length
    }
    return frames
}

/// A TLS client that has negotiated h2 and speaks it by hand.
struct RawH2: Sendable {
    let client: RawClient

    static func connect(
        to address: BoundAddress, group: MultiThreadedEventLoopGroup, tls: ClientTLSContext, settings: [(UInt16, UInt32)] = []
    ) async throws -> RawH2 {
        let raw = try await RawClient.connect(to: address, group: group, tls: tls)
        let connection = RawH2(client: raw)
        try await connection.send(H2Wire.preface + H2Wire.settings(settings))
        return connection
    }

    func send(_ bytes: [UInt8]) async throws {
        try await client.channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    }

    var frames: [ReceivedFrame] { parseFrames(client.received) }
    var isClosed: Bool { client.isClosed }

    /// Waits until `condition` holds of the frames received so far, or the connection has closed, or the timeout.
    func wait(timeout: Duration = .seconds(3), until condition: ([ReceivedFrame]) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(frames) { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition(frames)
    }

    /// Waits for the server to refuse the connection: a GOAWAY, or the connection closed.
    func waitForRefusal(timeout: Duration = .seconds(3)) async throws -> RawRefusal {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let goAway = frames.first(where: { $0.type == H2Wire.FrameType.goAway.rawValue }) {
                return .goAway(code: goAway.errorCode ?? 0xFFFF)
            }
            if isClosed { return .closed }
            try await Task.sleep(for: .milliseconds(5))
        }
        return .none
    }

    /// Answers the server's PINGs, as a conforming client must, until the connection closes or `timeout` passes.
    /// A graceful shutdown waits for this acknowledgement before it sends its final GOAWAY.
    func answerPings(timeout: Duration = .seconds(3)) async throws {
        var answered = 0
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !isClosed {
            let pings = frames.filter { $0.type == H2Wire.FrameType.ping.rawValue && $0.flags & H2Wire.ack == 0 }
            for ping in pings.dropFirst(answered) {
                try? await send(H2Wire.pingAck(ping.payload))
                answered += 1
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() async { await client.close() }
}

enum RawRefusal: Equatable, CustomStringConvertible {
    case goAway(code: UInt32)
    case closed
    case none

    var description: String {
        switch self {
        case .goAway(let code): "GOAWAY \(code)"
        case .closed: "connection closed"
        case .none: "no reaction"
        }
    }
}
