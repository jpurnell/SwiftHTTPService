import Foundation
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// A refused request is answered, and the answer reaches a client that is still sending.
///
/// Closing a socket with unread bytes in its receive buffer sends a reset, and a reset can destroy a response the
/// client has not read yet. The head here is refused as soon as it is parsed (two `Host` fields), while a large body
/// behind it is still arriving; every client must still read the `400`.
@Suite("A refusal reaches a client that is still sending")
struct RefusalIsReadTests {

    private static let head = "POST /x HTTP/1.1\r\nHost: a\r\nHost: b\r\nContent-Length: 400000\r\n\r\n"

    @Test("A request refused at its head is answered 400 and then closed, even for a client that reads only after its body has been sent")
    func refusalSurvivesTheBody() async throws {
        let running = try await startServer()
        try await withClientGroup { group in
            for round in 0..<20 {
                // Not reading: the response and anything after it wait in the socket until the client looks.
                let client = try await RawClient.connect(to: running.address, group: group, autoRead: false)
                try await client.send(Self.head)
                let body = String(repeating: "x", count: 50_000)
                for _ in 0..<8 { try? await client.send(body) }   // a write may fail once the server has ended the connection
                try await Task.sleep(for: .milliseconds(100))     // the server has refused, closed or lingered, and any reset has arrived
                let deadline = ContinuousClock.now + .seconds(3)
                while client.received.isEmpty, !client.isClosed, ContinuousClock.now < deadline {
                    client.channel.read()
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(try await client.response()?.status == 400, "round \(round)")
                await client.close()
            }
        }
        await running.server.shutdown()
    }
}
